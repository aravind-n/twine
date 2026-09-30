//! A run's state and trace events commit together, so a retried completion cannot duplicate history.

use rusqlite::{OptionalExtension, Transaction, params};

use super::{NewTraceSpan, Store, StoreError, sql_integer, traces::insert_span};
use crate::{TerminalId, TraceAnchor, TraceSpanId, Workflow, WorkflowRun, WorkflowTrace};

impl Store {
    pub(crate) fn save_workflow_run(
        &mut self,
        workflow: &Workflow,
    ) -> Result<Vec<(TerminalId, TraceSpanId)>, StoreError> {
        let run = workflow.run.as_ref().expect("workflow has a run");
        let transaction = self.connection.transaction()?;
        let previous: u64 = transaction.query_row(
            "SELECT trace_sequence FROM workflow_runs WHERE workflow_id = ?1",
            [sql_integer(workflow.workflow_id.0)?],
            |row| super::unsigned_column(row, 0),
        )?;
        let spans = record_starts(&transaction, workflow, run)?;
        for event in run.traces.iter().filter(|event| event.sequence > previous) {
            record_event(&transaction, workflow, run, event)?;
        }
        let sequence = run.traces.last().map_or(previous, |event| event.sequence);
        transaction.execute(
            "UPDATE workflow_runs SET state = ?2, trace_sequence = ?3 WHERE workflow_id = ?1",
            params![
                sql_integer(workflow.workflow_id.0)?,
                serde_json::to_string(run)?,
                sql_integer(sequence)?
            ],
        )?;
        transaction.commit()?;
        Ok(spans)
    }
}

fn record_starts(
    transaction: &Transaction<'_>,
    workflow: &Workflow,
    run: &WorkflowRun,
) -> Result<Vec<(TerminalId, TraceSpanId)>, StoreError> {
    let mut spans = Vec::new();
    for agent in &workflow.agents {
        if agent.terminal_id.value() == 0 {
            continue;
        }
        let exists: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM trace_spans WHERE terminal_id = ?1)",
            [sql_integer(agent.terminal_id.value())?],
            |row| row.get(0),
        )?;
        if exists {
            continue;
        }
        let role = run
            .agents
            .iter()
            .find(|role| role.agent_id == agent.agent_id.0)
            .expect("run owns its agent tabs");
        let started_at = run
            .traces
            .iter()
            .rev()
            .find(|event| event.generation == run.generation && event.kind == "stageStarted")
            .map_or(workflow.started_at, |event| event.timestamp);
        let span = insert_span(
            transaction,
            &NewTraceSpan {
                workflow_id: workflow.workflow_id,
                lane_key: &format!("agent:{}", agent.agent_id.0),
                lane_name: &agent.role,
                is_agent: true,
                role: Some(&agent.role),
                harness: Some(role.harness.definition().name),
                title: &run.workflow_type.definition.stages[run.stage_index].name,
                started_at,
                anchor: Some(TraceAnchor {
                    terminal_id: agent.terminal_id,
                    byte_offset: 0,
                    boundary_sizes: Some(Vec::new()),
                }),
            },
        )?;
        transaction.execute(
            "UPDATE trace_spans SET run_generation = ?2 WHERE id = ?1",
            params![sql_integer(span.0)?, sql_integer(run.generation)?],
        )?;
        spans.push((agent.terminal_id, span));
    }
    Ok(spans)
}

fn record_event(
    transaction: &Transaction<'_>,
    workflow: &Workflow,
    run: &WorkflowRun,
    event: &WorkflowTrace,
) -> Result<(), StoreError> {
    // Generation keeps a review loop's events on the invocation that produced them. A stage-wide
    // event belongs to that invocation's first span; role events belong to their source's span.
    let lane = event.agent_id.map(|id| format!("agent:{id}"));
    let span: Option<i64> = transaction
        .query_row(
            "SELECT s.id FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id
         WHERE l.workflow_id = ?1 AND s.run_generation = ?2 AND (?3 IS NULL OR l.lane_key = ?3)
         ORDER BY s.id LIMIT 1",
            params![
                sql_integer(workflow.workflow_id.0)?,
                sql_integer(event.generation)?,
                lane
            ],
            |row| row.get(0),
        )
        .optional()?;
    let span = match span {
        Some(span) => span,
        None => failure_span(transaction, workflow, run, event)?,
    };
    let label = |id| {
        run.agents
            .iter()
            .find(|agent| agent.agent_id == id)
            .map(|agent| agent.label.as_str())
    };
    let source = event.agent_id.and_then(label);
    let target = event.target_agent_id.and_then(label);
    let participants = match (source, target) {
        (Some(source), Some(target)) => format!(" · {source} → {target}"),
        (Some(source), None) => format!(" · {source}"),
        _ => String::new(),
    };
    let message = format!("{}{participants}: {}", event.stage, event.message);
    transaction.execute(
        "INSERT INTO trace_events (workflow_id, span_id, timestamp, kind, message)
         VALUES (?1, ?2, ?3, 'workflowEvent', ?4)",
        params![
            sql_integer(workflow.workflow_id.0)?,
            span,
            sql_integer(event.timestamp)?,
            message
        ],
    )?;
    Ok(())
}

fn failure_span(
    transaction: &Transaction<'_>,
    workflow: &Workflow,
    run: &WorkflowRun,
    event: &WorkflowTrace,
) -> Result<i64, StoreError> {
    // A failed reservation/spawn has no invocation span. Keep its actual stage in the message
    // and attach it to the last visible span (usually the draft shell or previous stage).
    let existing = transaction
        .query_row(
            "SELECT s.id FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id
         WHERE l.workflow_id = ?1 ORDER BY s.id DESC LIMIT 1",
            [sql_integer(workflow.workflow_id.0)?],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(span) = existing {
        return Ok(span);
    }
    // An older restored tab can have no trace history at all. Represent the workflow attempt,
    // with no terminal and no processStarted event, so its failure is still inspectable.
    transaction.execute(
        "INSERT INTO trace_lanes (workflow_id, lane_key, name, is_agent)
         VALUES (?1, 'workflow', 'Workflow', 0) ON CONFLICT (workflow_id, lane_key) DO NOTHING",
        [sql_integer(workflow.workflow_id.0)?],
    )?;
    transaction.execute(
        "INSERT INTO trace_spans (lane_id, title, started_at, ended_at, status, run_generation)
         SELECT id, ?2, ?3, ?3, ?4, ?5 FROM trace_lanes WHERE workflow_id = ?1 AND lane_key = 'workflow'",
        params![sql_integer(workflow.workflow_id.0)?, event.stage, sql_integer(event.timestamp)?,
            if run.status == crate::RunStatus::Failed { "failed" } else { "stopped" }, sql_integer(event.generation)?],
    )?;
    Ok(transaction.last_insert_rowid())
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;
    use crate::{
        BuiltinType, HarnessId, RoleLaunch, RunStatus, WorkflowKind, WorkflowStatus,
        WorkflowTypeRef,
    };

    #[test]
    fn a_failure_without_prior_history_has_a_visible_non_process_span() {
        let mut store = Store::open_in_memory().unwrap();
        let session_id = store
            .create_session(Path::new("/folder"), "Work", 1)
            .unwrap();
        let workflow_id = store
            .create_workflow(session_id, "Draft", WorkflowKind::Draft, &[])
            .unwrap()
            .0;
        let mut run = WorkflowRun::new(
            crate::WorkflowType {
                reference: WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
                definition: BuiltinType::Adversarial.definition(),
            },
            "Task".into(),
            &[
                RoleLaunch {
                    role: "implementer".into(),
                    harness: HarnessId::Pi,
                },
                RoleLaunch {
                    role: "reviewer".into(),
                    harness: HarnessId::Pi,
                },
            ],
        )
        .unwrap();
        store.start_workflow_run(workflow_id, &mut run).unwrap();
        run.trace("stageStarted", None, None, "Stage started");
        run.finish(RunStatus::Failed, "Couldn't reserve a terminal");
        let workflow = Workflow {
            workflow_id,
            session_id,
            name: "Adversarial".into(),
            kind: WorkflowKind::Agents,
            harness: None,
            terminal_id: TerminalId::from_value(0),
            agents: vec![],
            status: WorkflowStatus::Failed,
            started_at: 1,
            ended_at: Some(1),
            restored: false,
            run: Some(Box::new(run)),
        };
        assert!(store.save_workflow_run(&workflow).unwrap().is_empty());
        let page = store.workflow_trace(workflow_id, None, 10).unwrap();
        assert_eq!(page.spans.len(), 1);
        assert_eq!(page.summary.agent_count, 0);
        assert_eq!(page.spans[0].terminal_id, None);
        assert_eq!(page.spans[0].status, crate::TraceSpanStatus::Failed);
        let events = store
            .trace_events(page.spans[0].span_id, None, 10)
            .unwrap()
            .events;
        assert_eq!(events.len(), 2);
        assert!(
            events
                .iter()
                .all(|event| event.kind == crate::TraceEventKind::WorkflowEvent)
        );
        assert!(events[1].message.contains("Couldn't reserve a terminal"));
        store.save_workflow_run(&workflow).unwrap();
        assert_eq!(
            store.trace_summary(workflow_id).unwrap().revision,
            page.summary.revision
        );
    }
}
