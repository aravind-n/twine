//! Bounded native activity snapshots. Terminal output remains in the transcript store.

use rusqlite::{OptionalExtension, Transaction, params};

use super::{Store, StoreError, sql_integer, unsigned_column};
use crate::harness::steps::{ActivityKind, ActivityPhase, HarnessStep, MAX_DETAIL_BYTES, truncate};
use crate::trace::validate_limit;
use crate::{
    TerminalId, TraceActivitiesPage, TraceActivity, TraceActivityId, TraceActivityKind,
    TraceActivityStatus, TraceAnchor, TraceError, TraceSpanId, WorkflowId,
};

const MAX_SPAN_ACTIVITIES: i64 = 10_000;

/// Child turns have their own native turn IDs. Once observed, their identity pins all later
/// activity to the original assignment, including hooks arriving after the next prompt.
pub(super) fn activity_span(
    transaction: &Transaction<'_>,
    terminal: TerminalId,
    step: &HarnessStep,
) -> Result<Option<TraceSpanId>, StoreError> {
    let Some(activity) = &step.activity else {
        return Ok(None);
    };
    // An explicit root tool turn remains authoritative. Child hooks can carry a
    // different prompt ID after resumption; their native lifetime stays pinned.
    if step.turn_id.is_some() && step.kind != crate::harness::steps::StepKind::Activity {
        return Ok(None);
    }
    Ok(transaction
        .query_row(
            "SELECT a.span_id FROM trace_activities a JOIN trace_spans s ON s.id = a.span_id
         WHERE s.terminal_id = ?1 AND (a.source_id = ?2 OR a.source_id = ?3 OR a.parent_source_id = ?2)
         ORDER BY (a.source_id = ?2) DESC, a.id DESC LIMIT 1",
            params![
                sql_integer(terminal.value())?,
                activity.id,
                activity.parent_id
            ],
            |row| Ok(TraceSpanId(unsigned_column(row, 0)?)),
        )
        .optional()?)
}

pub(super) fn record_activity(
    transaction: &Transaction<'_>,
    span: TraceSpanId,
    step: &HarnessStep,
    observed_at: u64,
    anchor: &TraceAnchor,
) -> Result<(), StoreError> {
    let Some(activity) = &step.activity else {
        return Ok(());
    };
    // Reject oversized identity rather than truncating two different IDs to the same key.
    if activity.id.is_empty()
        || activity.id.len() > 512
        || activity
            .parent_id
            .as_ref()
            .is_some_and(|id| id.len() > 512 || id == &activity.id)
    {
        return Ok(());
    }
    // A native agent identity can be resumed. Keep its lifetime in the originally observed
    // prompt when the harness provides no new parent-turn correlation. Calls remain immutable.
    if activity.phase == ActivityPhase::Started {
        transaction.execute(
            "UPDATE trace_activities SET ended_at = NULL, status = 'running'
             WHERE span_id = ?1 AND kind = 'subagent' AND started_at IS NOT NULL AND ended_at < ?4
             AND (source_id = ?2 OR (source_id = ?3 AND NOT EXISTS
                 (SELECT 1 FROM trace_activities call WHERE call.span_id = ?1 AND call.source_id = ?2)))",
            params![
                sql_integer(span.0)?,
                activity.id,
                activity.parent_id,
                sql_integer(observed_at)?
            ],
        )?;
    } else if activity.kind == ActivityKind::Subagent {
        // Multiple child turns may produce Stop without another Start. Each explicit Stop
        // extends the agent lifetime, without inventing separate invocation boundaries.
        transaction.execute(
            "UPDATE trace_activities SET ended_at = NULL
             WHERE span_id = ?1 AND source_id = ?2 AND ended_at < ?3",
            params![sql_integer(span.0)?, activity.id, sql_integer(observed_at)?],
        )?;
    }
    let started = activity.phase == ActivityPhase::Started;
    let kind = match activity.kind {
        ActivityKind::Tool => "tool",
        ActivityKind::Subagent => "subagent",
    };
    let status = if activity.failed {
        "failed"
    } else if started {
        "running"
    } else {
        "completed"
    };
    let detail = truncate(&step.detail, MAX_DETAIL_BYTES);
    let title = truncate(&step.title, 256);
    // Start and finish may be delivered in either order. The first endpoint wins on retries;
    // a late start fills the missing input without reopening a completed activity.
    transaction.execute(
        "INSERT INTO trace_activities
         (span_id, source_id, parent_source_id, kind, title, started_at, ended_at, status, input, output, anchor)
         SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11
         WHERE (SELECT COUNT(*) FROM trace_activities WHERE span_id = ?1) < ?12
            OR EXISTS(SELECT 1 FROM trace_activities WHERE span_id = ?1 AND source_id = ?2)
         ON CONFLICT(span_id, source_id) DO UPDATE SET
            parent_source_id = COALESCE(trace_activities.parent_source_id, excluded.parent_source_id),
            title = CASE WHEN trace_activities.started_at IS NULL AND excluded.started_at IS NOT NULL
                THEN excluded.title ELSE trace_activities.title END,
            started_at = COALESCE(trace_activities.started_at, excluded.started_at),
            ended_at = COALESCE(trace_activities.ended_at, excluded.ended_at),
            status = CASE WHEN trace_activities.status = 'failed' OR excluded.status = 'failed' THEN 'failed'
                WHEN trace_activities.ended_at IS NOT NULL THEN trace_activities.status
                WHEN excluded.ended_at IS NOT NULL THEN excluded.status ELSE trace_activities.status END,
            input = CASE WHEN trace_activities.started_at IS NULL AND excluded.started_at IS NOT NULL
                THEN excluded.input ELSE trace_activities.input END,
            output = CASE WHEN trace_activities.ended_at IS NULL AND excluded.ended_at IS NOT NULL
                THEN excluded.output ELSE trace_activities.output END,
            anchor = CASE WHEN trace_activities.ended_at IS NULL AND excluded.ended_at IS NOT NULL
                THEN excluded.anchor ELSE trace_activities.anchor END",
        params![sql_integer(span.0)?, activity.id, activity.parent_id, kind, title,
            started.then(|| sql_integer(observed_at)).transpose()?,
            (!started).then(|| sql_integer(observed_at)).transpose()?, status,
            if started { &detail } else { "" }, if started { "" } else { &detail },
            serde_json::to_string(anchor).map_err(|_| StoreError::InvalidIdentifier)?, MAX_SPAN_ACTIVITIES],
    )?;
    transaction.execute(
        "UPDATE trace_activities SET status = 'interrupted' WHERE span_id = ?1 AND status = 'running'
         AND EXISTS(SELECT 1 FROM trace_events e JOIN trace_spans s ON s.terminal_id = e.terminal_id
             WHERE s.id = ?1 AND e.kind IN ('processStopped', 'processExited', 'processFailed'))",
        [sql_integer(span.0)?],
    )?;
    Ok(())
}

fn optional_unsigned(row: &rusqlite::Row<'_>, column: usize) -> rusqlite::Result<Option<u64>> {
    row.get::<_, Option<i64>>(column)?
        .map(|_| unsigned_column(row, column))
        .transpose()
}

impl Store {
    pub(crate) fn trace_activities(
        &self,
        span: TraceSpanId,
        after: Option<TraceActivityId>,
        limit: usize,
    ) -> Result<TraceActivitiesPage, TraceError> {
        validate_limit(limit)?;
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(StoreError::from)?;
        let workflow_id = transaction.query_row(
            "SELECT l.workflow_id FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id WHERE s.id = ?1",
            [sql_integer(span.0)?], |row| unsigned_column(row, 0),
        ).optional().map_err(StoreError::from)?.map(WorkflowId).ok_or(TraceError::SpanNotFound)?;
        let revision = super::traces::summary(&transaction, workflow_id)?.revision;
        let mut statement = transaction.prepare(
            "SELECT a.id, p.id, a.kind, a.title, a.started_at, a.ended_at,
             a.status,
             a.input, a.output, a.anchor
             FROM trace_activities a JOIN trace_spans s ON s.id = a.span_id
             LEFT JOIN trace_activities p ON p.span_id = a.span_id AND p.source_id = a.parent_source_id
             WHERE a.span_id = ?1 AND (?2 IS NULL OR a.id > ?2) ORDER BY a.id LIMIT ?3"
        ).map_err(StoreError::from)?;
        let mut activities = statement
            .query_map(
                params![
                    sql_integer(span.0)?,
                    after.map(|id| sql_integer(id.0)).transpose()?,
                    i64::try_from(limit + 1).map_err(|_| StoreError::InvalidIdentifier)?
                ],
                |row| {
                    let kind: String = row.get(2)?;
                    let status: String = row.get(6)?;
                    let anchor: Option<String> = row.get(9)?;
                    Ok(TraceActivity {
                        activity_id: TraceActivityId(unsigned_column(row, 0)?),
                        span_id: span,
                        parent_activity_id: optional_unsigned(row, 1)?.map(TraceActivityId),
                        kind: if kind == "subagent" {
                            TraceActivityKind::Subagent
                        } else {
                            TraceActivityKind::Tool
                        },
                        title: row.get(3)?,
                        started_at: optional_unsigned(row, 4)?,
                        ended_at: optional_unsigned(row, 5)?,
                        status: match status.as_str() {
                            "running" => TraceActivityStatus::Running,
                            "completed" => TraceActivityStatus::Completed,
                            "failed" => TraceActivityStatus::Failed,
                            _ => TraceActivityStatus::Interrupted,
                        },
                        input: row.get(7)?,
                        output: row.get(8)?,
                        anchor: anchor
                            .map(|json| {
                                serde_json::from_str(&json).map_err(|error| {
                                    rusqlite::Error::FromSqlConversionFailure(
                                        9,
                                        rusqlite::types::Type::Text,
                                        Box::new(error),
                                    )
                                })
                            })
                            .transpose()?,
                    })
                },
            )
            .map_err(StoreError::from)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)?;
        let has_more = activities.len() > limit;
        activities.truncate(limit);
        let next_after = has_more
            .then(|| activities.last().map(|a| a.activity_id))
            .flatten();
        Ok(TraceActivitiesPage {
            workflow_id,
            span_id: span,
            revision,
            activities,
            next_after,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::harness::steps::{HarnessActivity, StepKind};
    use crate::store::HarnessStepContext;
    use crate::{TraceSpanStatus, WorkflowKind};
    use std::path::Path;

    fn setup(store: &mut Store) -> WorkflowId {
        let session = store
            .create_session(Path::new("/fixture"), "Test", 1)
            .unwrap();
        store
            .create_workflow(session, "Agent", WorkflowKind::Terminal, &[])
            .unwrap()
            .0
    }

    fn step(kind: StepKind, turn: Option<&str>) -> HarnessStep {
        HarnessStep {
            activity: None,
            session_id: None,
            kind,
            turn_id: turn.map(str::to_owned),
            tool_call_id: None,
            title: "Inspect changes".into(),
            detail: "preview".into(),
        }
    }

    fn activity(
        id: &str,
        parent: Option<&str>,
        kind: ActivityKind,
        phase: ActivityPhase,
    ) -> HarnessStep {
        let mut event = step(StepKind::Activity, None);
        event.activity = Some(HarnessActivity {
            id: id.into(),
            parent_id: parent.map(str::to_owned),
            kind,
            phase,
            failed: false,
        });
        event
    }

    fn record(
        store: &mut Store,
        workflow_id: WorkflowId,
        step: &HarnessStep,
        time: u64,
    ) -> TraceSpanId {
        store
            .record_harness_step(
                HarnessStepContext {
                    workflow_id,
                    single_agent: true,
                    activate: false,
                    span: None,
                },
                step,
                time,
                &TraceAnchor {
                    terminal_id: TerminalId::from_value(7),
                    byte_offset: time,
                    boundary_sizes: Some(Vec::new()),
                },
            )
            .unwrap()
            .unwrap()
    }

    #[test]
    fn resumed_child_prompt_ids_do_not_split_native_lifetimes() {
        let mut store = Store::open_in_memory().unwrap();
        let workflow = setup(&mut store);
        let first = record(
            &mut store,
            workflow,
            &step(StepKind::Prompt, Some("one")),
            100,
        );
        let mut child = activity(
            "agent:review",
            None,
            ActivityKind::Subagent,
            ActivityPhase::Started,
        );
        child.turn_id = Some("one".into());
        record(&mut store, workflow, &child, 110);
        let mut root = activity(
            "tool:root:reused",
            None,
            ActivityKind::Tool,
            ActivityPhase::Started,
        );
        root.kind = StepKind::ToolStarted;
        root.turn_id = Some("one".into());
        assert_eq!(record(&mut store, workflow, &root, 111), first);
        let second = record(
            &mut store,
            workflow,
            &step(StepKind::Prompt, Some("two")),
            120,
        );
        root.turn_id = Some("two".into());
        assert_eq!(record(&mut store, workflow, &root, 121), second);
        let mut call = activity(
            "tool:review:read",
            Some("agent:review"),
            ActivityKind::Tool,
            ActivityPhase::Started,
        );
        call.turn_id = Some("two".into());
        assert_eq!(record(&mut store, workflow, &call, 130), first);
        call.activity.as_mut().unwrap().phase = ActivityPhase::Finished;
        assert_eq!(record(&mut store, workflow, &call, 140), first);
        child.turn_id = Some("child-turn".into());
        child.activity.as_mut().unwrap().phase = ActivityPhase::Finished;
        assert_eq!(record(&mut store, workflow, &child, 150), first);
        let items = store.trace_activities(first, None, 10).unwrap().activities;
        assert_eq!(items.len(), 3);
        assert_eq!(items[2].parent_activity_id, Some(items[0].activity_id));
        assert_eq!(items[2].status, TraceActivityStatus::Completed);
        let next = store.trace_activities(second, None, 10).unwrap().activities;
        assert_eq!(next.len(), 1);
        assert_ne!(items[1].activity_id, next[0].activity_id);
        assert_eq!(next[0].status, TraceActivityStatus::Running);
    }

    #[test]
    #[allow(clippy::too_many_lines)] // One complete cross-prompt causal-order scenario.
    fn nested_parallel_activity_keeps_identity_pagination_and_original_turn() {
        let mut store = Store::open_in_memory().unwrap();
        let workflow = setup(&mut store);
        let first = record(
            &mut store,
            workflow,
            &step(StepKind::Prompt, Some("one")),
            100,
        );
        record(
            &mut store,
            workflow,
            &activity(
                "agent:review",
                None,
                ActivityKind::Subagent,
                ActivityPhase::Started,
            ),
            110,
        );
        record(
            &mut store,
            workflow,
            &activity(
                "agent:tests",
                None,
                ActivityKind::Subagent,
                ActivityPhase::Started,
            ),
            115,
        );
        record(
            &mut store,
            workflow,
            &activity(
                "tool:review:read",
                Some("agent:review"),
                ActivityKind::Tool,
                ActivityPhase::Started,
            ),
            120,
        );
        let second = record(
            &mut store,
            workflow,
            &step(StepKind::Prompt, Some("two")),
            125,
        );
        let mut finish = activity(
            "tool:review:read",
            Some("agent:review"),
            ActivityKind::Tool,
            ActivityPhase::Finished,
        );
        finish.activity.as_mut().unwrap().failed = true;
        finish.detail = "test failed".into();
        assert_eq!(record(&mut store, workflow, &finish, 130), first);
        assert_eq!(
            record(
                &mut store,
                workflow,
                &activity(
                    "tool:review:late",
                    Some("agent:review"),
                    ActivityKind::Tool,
                    ActivityPhase::Started
                ),
                135
            ),
            first
        );
        record(
            &mut store,
            workflow,
            &activity(
                "agent:review",
                None,
                ActivityKind::Subagent,
                ActivityPhase::Finished,
            ),
            140,
        );
        let page = store.trace_activities(first, None, 2).unwrap();
        assert_eq!(page.activities.len(), 2);
        assert!(page.next_after.is_some());
        assert_eq!(page.activities[0].started_at, Some(110));
        assert_eq!(page.activities[0].ended_at, Some(140));
        let rest = store.trace_activities(first, page.next_after, 2).unwrap();
        assert!(rest.next_after.is_none());
        assert_eq!(
            rest.activities[0].parent_activity_id,
            Some(page.activities[0].activity_id)
        );
        assert_eq!(rest.activities[0].status, TraceActivityStatus::Failed);
        assert_eq!(rest.activities[0].input, "preview");
        assert_eq!(rest.activities[0].output, "test failed");
        assert_eq!(rest.activities[0].anchor.as_ref().unwrap().byte_offset, 130);
        assert_eq!(
            store.trace_activities(second, None, 10).unwrap().activities,
            []
        );
        let traces = store.workflow_trace(workflow, None, 10).unwrap();
        assert_eq!(traces.spans[0].status, TraceSpanStatus::Running);
    }

    #[test]
    fn a_parent_observed_after_its_child_stays_in_the_original_prompt() {
        let mut store = Store::open_in_memory().unwrap();
        let workflow = setup(&mut store);
        let first = record(
            &mut store,
            workflow,
            &step(StepKind::Prompt, Some("one")),
            100,
        );
        record(
            &mut store,
            workflow,
            &activity(
                "tool:late:read",
                Some("agent:late"),
                ActivityKind::Tool,
                ActivityPhase::Started,
            ),
            110,
        );
        record(
            &mut store,
            workflow,
            &step(StepKind::Prompt, Some("two")),
            120,
        );
        assert_eq!(
            record(
                &mut store,
                workflow,
                &activity(
                    "agent:late",
                    None,
                    ActivityKind::Subagent,
                    ActivityPhase::Started
                ),
                130
            ),
            first
        );
        assert_eq!(
            record(
                &mut store,
                workflow,
                &activity(
                    "tool:late:next",
                    Some("agent:late"),
                    ActivityKind::Tool,
                    ActivityPhase::Started
                ),
                140
            ),
            first
        );
        let page = store.trace_activities(first, None, 10).unwrap();
        assert_eq!(page.activities.len(), 3);
        assert_eq!(
            page.activities[0].parent_activity_id,
            Some(page.activities[1].activity_id)
        );
    }

    #[test]
    fn out_of_order_endpoints_are_idempotent_and_missing_times_stay_missing() {
        let mut store = Store::open_in_memory().unwrap();
        let workflow = setup(&mut store);
        let span = record(
            &mut store,
            workflow,
            &step(StepKind::Prompt, Some("one")),
            100,
        );
        let finish = activity(
            "tool:root:one",
            None,
            ActivityKind::Tool,
            ActivityPhase::Finished,
        );
        record(&mut store, workflow, &finish, 130);
        let start = activity(
            "tool:root:one",
            None,
            ActivityKind::Tool,
            ActivityPhase::Started,
        );
        record(&mut store, workflow, &start, 110);
        record(&mut store, workflow, &start, 150);
        record(&mut store, workflow, &finish, 160);
        record(
            &mut store,
            workflow,
            &activity(
                "tool:root:missing",
                None,
                ActivityKind::Tool,
                ActivityPhase::Finished,
            ),
            170,
        );
        let page = store.trace_activities(span, None, 10).unwrap();
        assert_eq!(page.activities.len(), 2);
        assert_eq!(page.activities[0].started_at, Some(110));
        assert_eq!(page.activities[0].ended_at, Some(130));
        assert_eq!(page.activities[0].anchor.as_ref().unwrap().byte_offset, 130);
        assert_eq!(page.activities[0].status, TraceActivityStatus::Completed);
        assert_eq!(page.activities[1].started_at, None);
        assert_eq!(page.activities[1].ended_at, Some(170));
    }

    #[test]
    fn background_agents_outlive_the_response_and_reopen_when_resumed() {
        let mut store = Store::open_in_memory().unwrap();
        let workflow = setup(&mut store);
        let span = record(
            &mut store,
            workflow,
            &step(StepKind::Prompt, Some("one")),
            100,
        );
        let start = activity(
            "agent:review",
            None,
            ActivityKind::Subagent,
            ActivityPhase::Started,
        );
        let finish = activity(
            "agent:review",
            None,
            ActivityKind::Subagent,
            ActivityPhase::Finished,
        );
        record(&mut store, workflow, &start, 110);
        record(
            &mut store,
            workflow,
            &step(StepKind::Responded, Some("one")),
            120,
        );
        assert_eq!(
            store.trace_activities(span, None, 10).unwrap().activities[0].status,
            TraceActivityStatus::Running
        );
        record(&mut store, workflow, &finish, 130);
        record(&mut store, workflow, &start, 140);
        let resumed = store
            .trace_activities(span, None, 10)
            .unwrap()
            .activities
            .remove(0);
        assert_eq!(resumed.started_at, Some(110));
        assert_eq!(resumed.ended_at, None);
        assert_eq!(resumed.status, TraceActivityStatus::Running);
        record(&mut store, workflow, &finish, 150);
        record(
            &mut store,
            workflow,
            &activity(
                "tool:review:next",
                Some("agent:review"),
                ActivityKind::Tool,
                ActivityPhase::Started,
            ),
            160,
        );
        assert_eq!(
            store.trace_activities(span, None, 10).unwrap().activities[0].status,
            TraceActivityStatus::Running
        );
        record(&mut store, workflow, &finish, 170);
        let completed = store
            .trace_activities(span, None, 10)
            .unwrap()
            .activities
            .remove(0);
        assert_eq!(completed.ended_at, Some(170));
        assert_eq!(completed.anchor.as_ref().unwrap().byte_offset, 170);
    }

    #[test]
    fn late_starts_preserve_observed_endings_and_process_interruption() {
        let mut store = Store::open_in_memory().unwrap();
        let workflow = setup(&mut store);
        let span = record(
            &mut store,
            workflow,
            &step(StepKind::Prompt, Some("one")),
            100,
        );
        record(
            &mut store,
            workflow,
            &activity(
                "agent:review",
                None,
                ActivityKind::Subagent,
                ActivityPhase::Finished,
            ),
            120,
        );
        record(
            &mut store,
            workflow,
            &activity(
                "agent:review",
                None,
                ActivityKind::Subagent,
                ActivityPhase::Started,
            ),
            130,
        );
        assert_eq!(
            store.trace_activities(span, None, 10).unwrap().activities[0].ended_at,
            Some(120)
        );
        let call = activity(
            "tool:review:read",
            Some("agent:review"),
            ActivityKind::Tool,
            ActivityPhase::Started,
        );
        record(&mut store, workflow, &call, 140);
        record(
            &mut store,
            workflow,
            &activity(
                "tool:review:read",
                Some("agent:review"),
                ActivityKind::Tool,
                ActivityPhase::Finished,
            ),
            150,
        );
        record(
            &mut store,
            workflow,
            &activity(
                "agent:review",
                None,
                ActivityKind::Subagent,
                ActivityPhase::Finished,
            ),
            160,
        );
        record(&mut store, workflow, &call, 170);
        assert_eq!(
            store.trace_activities(span, None, 10).unwrap().activities[0].ended_at,
            Some(160)
        );
        store
            .record_harness_process_ending(
                workflow,
                TerminalId::from_value(7),
                &crate::store::TraceEnding {
                    observed_at: 180,
                    status: TraceSpanStatus::Stopped,
                    kind: crate::TraceEventKind::ProcessStopped,
                    message: "Stopped",
                    anchor: Some(TraceAnchor {
                        terminal_id: TerminalId::from_value(7),
                        byte_offset: 180,
                        boundary_sizes: None,
                    }),
                },
            )
            .unwrap();
        record(
            &mut store,
            workflow,
            &activity(
                "tool:root:late",
                None,
                ActivityKind::Tool,
                ActivityPhase::Started,
            ),
            190,
        );
        let page = store.trace_activities(span, None, 10).unwrap();
        assert_eq!(page.activities[2].status, TraceActivityStatus::Interrupted);
        assert_eq!(page.activities[2].ended_at, None);
    }

    #[test]
    fn durable_activity_recovers_as_interrupted_and_rejects_invalid_pages() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("trace.sqlite");
        let mut store = Store::open(&path).unwrap();
        let workflow = setup(&mut store);
        let span = record(
            &mut store,
            workflow,
            &step(StepKind::Prompt, Some("one")),
            100,
        );
        let mut start = activity(
            "tool:root:one",
            None,
            ActivityKind::Tool,
            ActivityPhase::Started,
        );
        start.detail = "☃".repeat(3000);
        record(&mut store, workflow, &start, 110);
        drop(store);
        let mut store = Store::open(&path).unwrap();
        store.recover_interrupted_work().unwrap();
        let page = store.trace_activities(span, None, 10).unwrap();
        assert_eq!(page.activities[0].status, TraceActivityStatus::Interrupted);
        assert_eq!(page.activities[0].ended_at, None);
        assert!(page.activities[0].input.len() <= MAX_DETAIL_BYTES);
        assert!(matches!(
            store.trace_activities(span, None, 0),
            Err(TraceError::InvalidLimit)
        ));
        assert!(matches!(
            store.trace_activities(TraceSpanId(9999), None, 1),
            Err(TraceError::SpanNotFound)
        ));
    }
}
