//! A run's state and trace events commit together, so a retried completion cannot duplicate history.

use rusqlite::{OptionalExtension, Transaction, params};

use super::{
    NewTraceSpan, Store, StoreError, sql_integer,
    traces::{insert_event, insert_span_record},
};
use crate::{
    TerminalId, TraceAnchor, TraceEventKind, TraceSpanId, Workflow, WorkflowId, WorkflowRun,
    WorkflowTrace,
};

impl Store {
    pub(crate) fn save_workflow_run(
        &mut self,
        workflow: &Workflow,
    ) -> Result<Vec<(TerminalId, TraceSpanId)>, StoreError> {
        let run = workflow.run.as_ref().expect("workflow has a run");
        let transaction = self.connection.transaction()?;
        let spans = record_starts(&transaction, workflow, run)?;
        save_run_state(&transaction, workflow.workflow_id, run)?;
        transaction.commit()?;
        Ok(spans)
    }
}

pub(super) fn save_run_state(
    transaction: &Transaction<'_>,
    workflow_id: WorkflowId,
    run: &WorkflowRun,
) -> Result<(), StoreError> {
    let previous: u64 = transaction.query_row(
        "SELECT trace_sequence FROM workflow_runs WHERE workflow_id = ?1",
        [sql_integer(workflow_id.0)?],
        |row| super::unsigned_column(row, 0),
    )?;
    for event in run.traces.iter().filter(|event| event.sequence > previous) {
        record_event(transaction, workflow_id, run, event)?;
    }
    let sequence = run.traces.last().map_or(previous, |event| event.sequence);
    transaction.execute(
        "UPDATE workflow_runs SET state = ?2, trace_sequence = ?3 WHERE workflow_id = ?1",
        params![
            sql_integer(workflow_id.0)?,
            serde_json::to_string(run)?,
            sql_integer(sequence)?
        ],
    )?;
    Ok(())
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
        // Waiting tabs retain their prior terminal while the next stage is prepared.
        let Some(launch) = run.traces.iter().find(|event| {
            event.generation == run.generation
                && event.kind == "agentStarted"
                && event.agent_id == Some(role.agent_id)
        }) else {
            continue;
        };
        let started_at = run
            .traces
            .iter()
            .rev()
            .find(|event| event.generation == run.generation && event.kind == "stageStarted")
            .map_or(workflow.started_at, |event| event.timestamp);
        let span = work_span(
            transaction,
            workflow.workflow_id,
            run,
            role.agent_id,
            run.generation,
            &run.workflow_type.definition.stages[run.stage_index].name,
            started_at,
        )?;
        transaction.execute(
            "UPDATE trace_spans SET terminal_id = ?2 WHERE id = ?1",
            params![
                sql_integer(span.0)?,
                sql_integer(agent.terminal_id.value())?
            ],
        )?;
        insert_event(
            transaction,
            workflow.workflow_id,
            span,
            launch.timestamp,
            TraceEventKind::ProcessStarted,
            "Process started.",
            Some(&TraceAnchor {
                terminal_id: agent.terminal_id,
                byte_offset: 0,
                boundary_sizes: Some(Vec::new()),
            }),
        )?;
        spans.push((agent.terminal_id, span));
    }
    Ok(spans)
}

fn work_span(
    transaction: &Transaction<'_>,
    workflow_id: WorkflowId,
    run: &WorkflowRun,
    agent_id: u64,
    generation: u64,
    stage: &str,
    started_at: u64,
) -> Result<TraceSpanId, StoreError> {
    let key = format!("agent:{agent_id}");
    let existing = transaction.query_row(
        "SELECT s.id FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id
         WHERE l.workflow_id = ?1 AND l.lane_key = ?2 AND s.run_generation = ?3 AND s.work_span = 1",
        params![sql_integer(workflow_id.0)?, key, sql_integer(generation)?],
        |row| super::unsigned_column(row, 0),
    ).optional()?;
    if let Some(id) = existing {
        return Ok(TraceSpanId(id));
    }
    let agent = run
        .agents
        .iter()
        .find(|agent| agent.agent_id == agent_id)
        .expect("run owns the trace participant");
    let title = if let Some(assignment) = run.assignments.get(&agent_id) {
        assignment.task.clone()
    } else if run.reference() == crate::WorkflowTypeRef::Builtin(crate::BuiltinType::Adversarial) {
        format!("{stage} · Round {}", generation.div_ceil(2))
    } else {
        stage.to_owned()
    };
    let span = insert_span_record(
        transaction,
        &NewTraceSpan {
            workflow_id,
            lane_key: &key,
            lane_name: &agent.label,
            is_agent: true,
            role: Some(&agent.role),
            harness: Some(agent.harness.definition().name),
            title: &title,
            started_at,
            anchor: None,
        },
    )?;
    transaction.execute(
        "UPDATE trace_spans SET run_generation = ?2, work_span = 1 WHERE id = ?1",
        params![sql_integer(span.0)?, sql_integer(generation)?],
    )?;
    Ok(span)
}

fn record_event(
    transaction: &Transaction<'_>,
    workflow_id: WorkflowId,
    run: &WorkflowRun,
    event: &WorkflowTrace,
) -> Result<(), StoreError> {
    // A handoff starts the receiver's next assignment, before its process is launched.
    if event.kind == "handoff"
        && let Some(target) = event.target_agent_id
    {
        let span = work_span(
            transaction,
            workflow_id,
            run,
            target,
            event.generation + 1,
            &run.workflow_type.definition.stages[run.stage_index].name,
            event.timestamp,
        )?;
        return write_event(transaction, workflow_id, run, event, span);
    }
    let lane = event.agent_id.map(|id| format!("agent:{id}"));
    let mut statement = transaction.prepare(
        "SELECT s.id FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id
         WHERE l.workflow_id = ?1 AND s.run_generation = ?2 AND (?3 IS NULL OR l.lane_key = ?3)
         ORDER BY s.id",
    )?;
    let mut spans = statement
        .query_map(
            params![
                sql_integer(workflow_id.0)?,
                sql_integer(event.generation)?,
                lane
            ],
            |row| super::unsigned_column(row, 0).map(TraceSpanId),
        )?
        .collect::<Result<Vec<_>, _>>()?;
    if spans.is_empty() {
        spans.push(TraceSpanId(
            u64::try_from(failure_span(transaction, workflow_id, run, event)?)
                .map_err(|_| StoreError::InvalidIdentifier)?,
        ));
    }
    for span in spans {
        write_event(transaction, workflow_id, run, event, span)?;
        if matches!(event.kind.as_str(), "roleCompleted" | "stageCompleted") {
            transaction.execute(
                "UPDATE trace_spans SET status = ?3, ended_at = MAX(started_at, ?2)
                WHERE id = ?1 AND work_span = 1 AND status = 'running'",
                params![
                    sql_integer(span.0)?,
                    sql_integer(event.timestamp)?,
                    if event.kind == "roleCompleted" {
                        "exited"
                    } else {
                        "stopped"
                    }
                ],
            )?;
        }
    }
    if event.kind == "workflowEnded" {
        transaction.execute(
            "UPDATE trace_spans SET status = ?2, ended_at = MAX(started_at, ?3)
            WHERE work_span = 1 AND status = 'running' AND lane_id IN
            (SELECT id FROM trace_lanes WHERE workflow_id = ?1)",
            params![
                sql_integer(workflow_id.0)?,
                if run.status == crate::RunStatus::Failed {
                    "failed"
                } else {
                    "stopped"
                },
                sql_integer(event.timestamp)?
            ],
        )?;
    }
    Ok(())
}

fn write_event(
    transaction: &Transaction<'_>,
    workflow_id: WorkflowId,
    run: &WorkflowRun,
    event: &WorkflowTrace,
    span: TraceSpanId,
) -> Result<(), StoreError> {
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
    insert_event(
        transaction,
        workflow_id,
        span,
        event.timestamp,
        TraceEventKind::WorkflowEvent,
        &message,
        event.anchor.as_ref(),
    )
}

fn failure_span(
    transaction: &Transaction<'_>,
    workflow_id: WorkflowId,
    run: &WorkflowRun,
    event: &WorkflowTrace,
) -> Result<i64, StoreError> {
    // A failed reservation/spawn has no invocation span. Keep its actual stage in the message
    // and attach it to the last visible span (usually the draft shell or previous stage).
    let existing = transaction
        .query_row(
            "SELECT s.id FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id
         WHERE l.workflow_id = ?1 ORDER BY s.id DESC LIMIT 1",
            [sql_integer(workflow_id.0)?],
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
        [sql_integer(workflow_id.0)?],
    )?;
    transaction.execute(
        "INSERT INTO trace_spans (lane_id, title, started_at, ended_at, status, run_generation)
         SELECT id, ?2, ?3, ?3, ?4, ?5 FROM trace_lanes WHERE workflow_id = ?1 AND lane_key = 'workflow'",
        params![sql_integer(workflow_id.0)?, event.stage, sql_integer(event.timestamp)?,
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

    fn workflow(store: &mut Store, definition: crate::WorkflowTypeDefinition) -> Workflow {
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
                definition,
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
        Workflow {
            workflow_id,
            session_id,
            name: "Adversarial".into(),
            kind: WorkflowKind::Agents,
            harness: None,
            terminal_id: TerminalId::from_value(0),
            agents: vec![],
            status: WorkflowStatus::Running,
            started_at: 1,
            ended_at: None,
            restored: false,
            run: Some(Box::new(run)),
        }
    }

    #[test]
    fn a_failure_without_prior_history_has_a_visible_non_process_span() {
        let mut store = Store::open_in_memory().unwrap();
        let mut workflow = workflow(&mut store, BuiltinType::Adversarial.definition());
        let workflow_id = workflow.workflow_id;
        let run = workflow.run.as_mut().unwrap();
        run.trace("stageStarted", None, None, "Stage started");
        run.finish(RunStatus::Failed, "Couldn't reserve a terminal");
        workflow.status = WorkflowStatus::Failed;
        workflow.ended_at = Some(1);
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

    #[test]
    fn a_review_decision_stops_an_uncompleted_helper_even_after_its_process_exits() {
        let mut store = Store::open_in_memory().unwrap();
        let mut definition = BuiltinType::Adversarial.definition();
        definition.stages[1]
            .roles
            .push(crate::RoleId("implementer".into()));
        let mut helper_handoff = definition.handoffs[0].clone();
        helper_handoff.to.role = crate::RoleId("implementer".into());
        definition.handoffs.push(helper_handoff);
        let mut workflow = workflow(&mut store, definition);
        let run = workflow.run.as_mut().unwrap();
        run.stage_index = 1;
        run.generation = 2;
        let helper = run.agents[0].agent_id;
        let reviewer = run.agents[1].agent_id;
        run.agents[0].status = crate::RunAgentStatus::Exited;
        run.agents[1].status = crate::RunAgentStatus::Running;
        let transaction = store.connection.transaction().unwrap();
        let helper_span = work_span(
            &transaction,
            workflow.workflow_id,
            run,
            helper,
            2,
            "Review",
            10,
        )
        .unwrap();
        let reviewer_span = work_span(
            &transaction,
            workflow.workflow_id,
            run,
            reviewer,
            2,
            "Review",
            10,
        )
        .unwrap();
        super::super::traces::finish_span(
            &transaction,
            helper_span,
            &super::super::TraceEnding {
                observed_at: 20,
                status: crate::TraceSpanStatus::Exited,
                kind: TraceEventKind::ProcessExited,
                message: "Process exited with code 0.",
                anchor: None,
            },
        )
        .unwrap();
        transaction.commit().unwrap();
        run.complete(
            reviewer,
            2,
            crate::CompletionSignal {
                task: String::new(),
                decision: crate::Decision::RequestChanges,
                summary: "Revise the result".into(),
                assignments: vec![],
            },
        )
        .unwrap();
        let decision_at = run
            .traces
            .iter()
            .find(|event| event.kind == "stageCompleted")
            .unwrap()
            .timestamp;
        store.save_workflow_run(&workflow).unwrap();
        let page = store
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        let helper = page
            .spans
            .iter()
            .find(|span| span.span_id == helper_span)
            .unwrap();
        assert_eq!(helper.status, crate::TraceSpanStatus::Stopped);
        assert_eq!(helper.ended_at, Some(decision_at));
        assert_eq!(
            page.spans
                .iter()
                .find(|span| span.span_id == reviewer_span)
                .unwrap()
                .status,
            crate::TraceSpanStatus::Completed
        );
        assert_eq!(
            page.spans
                .iter()
                .filter(|span| span.status == crate::TraceSpanStatus::Running)
                .count(),
            1
        );
    }
}
