//! Startup recovery runs only after Application has acquired transcript directory ownership.

use rusqlite::TransactionBehavior;

use super::{Store, StoreError, TraceEnding, run_traces::save_run_state, traces::finish_span};
use crate::{RunStatus, TraceEventKind, TraceSpanId, TraceSpanStatus, WorkflowId, WorkflowRun};

impl Store {
    /// Recover all folders atomically. Reopening tabs later only reads this durable outcome.
    pub(crate) fn recover_interrupted_work(&mut self) -> Result<(), StoreError> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let runs = {
            let mut statement =
                transaction.prepare("SELECT workflow_id, state FROM workflow_runs")?;
            statement
                .query_map([], |row| {
                    Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        for (id, state) in runs {
            let mut run = WorkflowRun::from_stored_json(&state)?;
            if run.status == RunStatus::Running {
                run.finish(
                    RunStatus::Interrupted,
                    "Twine stopped while the workflow was running.",
                );
                save_run_state(
                    &transaction,
                    WorkflowId(u64::try_from(id).map_err(|_| StoreError::InvalidIdentifier)?),
                    &run,
                )?;
            }
        }
        transaction.execute(
            "UPDATE workflows SET lifecycle_status = 'interrupted'
             WHERE kind = 'single_agent' AND (lifecycle_status = 'running' OR lifecycle_status IS NULL)",
            [],
        )?;
        let spans = {
            let mut statement =
                transaction.prepare("SELECT id FROM trace_spans WHERE status = 'running'")?;
            statement
                .query_map([], |row| super::unsigned_column(row, 0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        let ending = TraceEnding {
            observed_at: crate::workflow::timestamp(),
            status: TraceSpanStatus::Stopped,
            kind: TraceEventKind::ProcessStopped,
            message: "Process interrupted when Twine stopped.",
            // The last accepted output boundary was in memory; preserve existing anchors instead
            // of inventing a byte offset for this recovery event.
            anchor: None,
        };
        for id in spans {
            finish_span(&transaction, TraceSpanId(id), &ending)?;
        }
        transaction.execute(
            "UPDATE trace_activities SET status = 'interrupted' WHERE status = 'running'",
            [],
        )?;
        transaction.commit()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;
    use crate::{
        BuiltinType, HarnessId, RoleLaunch, WorkflowKind, WorkflowStatus, WorkflowType,
        WorkflowTypeRef,
    };

    #[test]
    fn a_failed_recovery_rolls_back_lifecycle_and_history_together() {
        let mut store = Store::open_in_memory().unwrap();
        let session = store
            .create_session(Path::new("/folder"), "Session", 1)
            .unwrap();
        let id = store
            .create_workflow(session, "Draft", WorkflowKind::Draft, &[])
            .unwrap()
            .0;
        let mut run = WorkflowRun::new(
            WorkflowType {
                reference: WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
                definition: BuiltinType::Adversarial.definition(),
            },
            "Task".into(),
            &[
                RoleLaunch {
                    model: None,
                    effort: None,
                    yolo: false,
                    role: "implementer".into(),
                    harness: HarnessId::Pi,
                },
                RoleLaunch {
                    model: None,
                    effort: None,
                    yolo: false,
                    role: "reviewer".into(),
                    harness: HarnessId::Pi,
                },
            ],
        )
        .unwrap();
        store.start_workflow_run(id, &mut run).unwrap();
        let single = store
            .create_workflow(session, "Agent", WorkflowKind::SingleAgent, &[])
            .unwrap()
            .0;
        store
            .update_agent_status(single, WorkflowStatus::Running)
            .unwrap();
        let span = store
            .start_trace_span(&super::super::NewTraceSpan {
                workflow_id: single,
                lane_key: "agent",
                lane_name: "Agent",
                is_agent: true,
                role: None,
                harness: Some("pi"),
                title: "Agent",
                started_at: 1,
                anchor: None,
            })
            .unwrap();
        store.execute_test_sql("CREATE TRIGGER reject_recovery BEFORE INSERT ON trace_events
            WHEN NEW.kind = 'processStopped' BEGIN SELECT RAISE(FAIL, 'test recovery failure'); END");
        assert!(store.recover_interrupted_work().is_err());
        let stored = store.workflows(Path::new("/folder")).unwrap();
        assert_eq!(stored[0].run.as_deref(), Some(&run));
        assert_eq!(stored[1].agent_status, Some(WorkflowStatus::Running));
        assert_eq!(
            store.workflow_trace(single, None, 10).unwrap().spans[0].status,
            TraceSpanStatus::Running
        );
        assert_eq!(store.trace_events(span, None, 10).unwrap().events.len(), 1);
        store.execute_test_sql("DROP TRIGGER reject_recovery");
        store.recover_interrupted_work().unwrap();
        let stored = store.workflows(Path::new("/folder")).unwrap();
        assert_eq!(
            stored[0].run.as_ref().unwrap().status,
            RunStatus::Interrupted
        );
        assert_eq!(
            stored[0].run.as_ref().unwrap().agents[0].status,
            crate::RunAgentStatus::Interrupted
        );
        assert_eq!(stored[1].agent_status, Some(WorkflowStatus::Interrupted));
        assert_eq!(
            store.workflow_trace(single, None, 10).unwrap().spans[0].status,
            TraceSpanStatus::Stopped
        );
        assert_eq!(store.trace_events(span, None, 10).unwrap().events.len(), 2);
    }
}
