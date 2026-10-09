//! Historical observations enrich trace records only. They never drive workflow state.

use super::{Store, StoreError, sql_integer, unsigned_column};
use crate::harness::history::{HistoryRequest, NativeActivity};
use crate::harness::steps::ActivityKind;
use crate::{TraceSpanId, WorkflowId};

type ExistingActivity = (u64, u64, Option<u64>, Option<u64>, String, Option<u64>);
use rusqlite::{OptionalExtension, params};

impl Store {
    pub(crate) fn history_request(
        &self,
        span: TraceSpanId,
    ) -> Result<Option<HistoryRequest>, StoreError> {
        let Some(database) = self
            .connection
            .path()
            .filter(|s| !s.is_empty())
            .map(std::path::PathBuf::from)
        else {
            return Ok(None);
        };
        let row:Option<(u64,String,String)> = self.connection.query_row(
            "SELECT l.workflow_id,l.harness,wt.harness_session FROM trace_spans s
             JOIN trace_lanes l ON l.id=s.lane_id JOIN workflow_terminals wt ON wt.terminal_id=s.terminal_id
             WHERE s.id=?1 AND wt.harness_session IS NOT NULL AND l.harness IS NOT NULL",
            [sql_integer(span.0)?], |r|Ok((unsigned_column(r,0)?,r.get(1)?,r.get(2)?))
        ).optional()?;
        Ok(row.and_then(|(workflow, harness, session)| {
            let harness = match harness.as_str() {
                "Codex" | "codex" => crate::HarnessId::Codex,
                "Claude Code" | "claude-code" | "claude_code" => crate::HarnessId::ClaudeCode,
                "Pi" | "pi" => crate::HarnessId::Pi,
                "OMP" | "omp" => crate::HarnessId::Omp,
                _ => return None,
            };
            Some(HistoryRequest {
                database,
                workflow: WorkflowId(workflow),
                session,
                harness,
            })
        }))
    }

    #[expect(
        clippy::too_many_lines,
        reason = "native identity and full detail updates commit together"
    )]
    pub(crate) fn reconcile_native_activity(
        &mut self,
        workflow: WorkflowId,
        session: &str,
        native: &NativeActivity,
    ) -> Result<bool, StoreError> {
        // Persisted native identities and explicit response IDs identify existing observations.
        let existing:Option<ExistingActivity> = self.connection.query_row(
            "SELECT a.id,a.span_id,a.input_bytes,a.output_bytes,a.metadata,a.ended_at FROM trace_activities a
             JOIN trace_spans s ON s.id=a.span_id JOIN trace_lanes l ON l.id=s.lane_id
             JOIN workflow_terminals wt ON wt.terminal_id=s.terminal_id
             WHERE l.workflow_id=?1 AND wt.harness_session=?2 AND
             (a.source_id=?3 OR (?4 IS NOT NULL AND a.kind='model' AND json_extract(a.metadata,'$.responseId')=?4))
             ORDER BY a.id LIMIT 1",
            params![sql_integer(workflow.0)?,session,native.id,native.metadata["responseId"].as_str()],
            |r|Ok((unsigned_column(r,0)?,unsigned_column(r,1)?,r.get::<_,Option<i64>>(2)?.map(|_|unsigned_column(r,2)).transpose()?,
                r.get::<_,Option<i64>>(3)?.map(|_|unsigned_column(r,3)).transpose()?,r.get(4)?,r.get::<_,Option<i64>>(5)?.map(|_|unsigned_column(r,5)).transpose()?))
        ).optional()?;
        let span = if let Some((_, span, _, _, _, _)) = existing.as_ref() {
            Some(*span)
        } else {
            self.connection.query_row(
                "SELECT s.id FROM trace_spans s JOIN trace_lanes l ON l.id=s.lane_id
                 JOIN workflow_terminals wt ON wt.terminal_id=s.terminal_id
                 WHERE l.workflow_id=?1 AND wt.harness_session=?2 AND
                   ((?3 IS NOT NULL AND s.harness_turn_id=?3) OR EXISTS(SELECT 1 FROM trace_activities a
                     WHERE a.span_id=s.id AND a.source_id=?4)) ORDER BY s.id LIMIT 1",
                params![sql_integer(workflow.0)?,session,native.turn,native.parent],|r|unsigned_column(r,0)
            ).optional()?
        };
        // Older Claude/Pi logs do not share Twine's turn UUID. Require a unique exact prompt
        // title AND native timestamp in the already linked harness conversation; ambiguous
        // matches are left unavailable, never attached to whichever step is newest.
        let span = if span.is_some() {
            span
        } else if let (Some(title), Some(time)) = (
            native.metadata["promptTitle"].as_str(),
            native.metadata["promptTime"].as_u64(),
        ) {
            let mut statement=self.connection.prepare(
                "SELECT s.id FROM trace_spans s JOIN trace_lanes l ON l.id=s.lane_id
                 JOIN workflow_terminals wt ON wt.terminal_id=s.terminal_id WHERE l.workflow_id=?1 AND wt.harness_session=?2
                 AND s.title=?3 AND s.started_at BETWEEN ?4 AND ?5")?;
            let ids = statement
                .query_map(
                    params![
                        sql_integer(workflow.0)?,
                        session,
                        title,
                        sql_integer(time.saturating_sub(5000))?,
                        sql_integer(time.saturating_add(5000))?
                    ],
                    |r| unsigned_column(r, 0),
                )?
                .collect::<Result<Vec<_>, _>>()?;
            if ids.len() == 1 {
                ids.first().copied()
            } else {
                None
            }
        } else {
            None
        };
        let Some(span) = span else {
            return Ok(false);
        };
        if let Some((_, _, input, output, metadata, ended)) = existing.as_ref()
            && native
                .input
                .as_ref()
                .is_none_or(|s| input.is_some_and(|n| n >= s.len() as u64))
            && native
                .output
                .as_ref()
                .is_none_or(|s| output.is_some_and(|n| n >= s.len() as u64))
            && serde_json::from_str::<serde_json::Value>(metadata)
                .ok()
                .as_ref()
                == Some(&native.metadata)
            && native
                .ended
                .is_none_or(|time| ended.is_some_and(|end| end >= time))
            && self.connection.query_row(
                "SELECT (?2 IS NULL OR started_at IS NOT NULL) AND (NOT ?3 OR status='failed') AND (?4 IS NULL OR parent_source_id=?4) FROM trace_activities WHERE id=?1",
                params![sql_integer(existing.as_ref().expect("exists").0)?,native.started.map(sql_integer).transpose()?,native.failed,native.parent],|row|row.get::<_,bool>(0))?
        {
            return Ok(false);
        }
        let (terminal,anchor): (u64,Option<String>) = self.connection.query_row(
            "SELECT s.terminal_id,a.anchor FROM trace_spans s LEFT JOIN trace_activities a ON a.id=?2 WHERE s.id=?1",
            params![sql_integer(span)?,existing.as_ref().map(|row|sql_integer(row.0)).transpose()?],|r|Ok((unsigned_column(r,0)?,r.get(1)?))
        )?;
        // Historical model timestamps lack an observed request start. Keep that endpoint absent.
        let transaction = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let mut input_key = None;
        let mut output_key = None;
        if let Some(input) = &native.input {
            input_key = self.payloads.save(input)?;
        }
        if let Some(output) = &native.output {
            output_key = self.payloads.save(output)?;
        }
        let kind = match native.kind {
            ActivityKind::Tool => "tool",
            ActivityKind::Subagent => "subagent",
            ActivityKind::Model => "model",
            ActivityKind::Note => "note",
        };
        let status = if native.failed {
            "failed"
        } else if native.ended.is_some() {
            "completed"
        } else {
            "running"
        };
        let id = if let Some((id, _, _, _, _, _)) = existing.as_ref() {
            Some(*id)
        } else {
            None
        };
        transaction.execute(
            "INSERT INTO trace_activities (id,span_id,source_id,parent_source_id,kind,title,started_at,ended_at,status,input,output,anchor,input_key,output_key,input_bytes,output_bytes,metadata)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)
             ON CONFLICT(id) DO UPDATE SET
               parent_source_id=COALESCE(excluded.parent_source_id,trace_activities.parent_source_id),
               started_at=COALESCE(trace_activities.started_at,excluded.started_at),
               ended_at=CASE WHEN trace_activities.ended_at IS NULL THEN excluded.ended_at WHEN excluded.ended_at IS NULL THEN trace_activities.ended_at ELSE MAX(trace_activities.ended_at,excluded.ended_at) END,
               status=CASE WHEN trace_activities.status='failed' OR excluded.status='failed' THEN 'failed' WHEN excluded.ended_at IS NOT NULL THEN excluded.status ELSE trace_activities.status END,
               input=CASE WHEN excluded.input_bytes>COALESCE(trace_activities.input_bytes,0) THEN excluded.input ELSE trace_activities.input END,
               output=CASE WHEN excluded.output_bytes>COALESCE(trace_activities.output_bytes,0) THEN excluded.output ELSE trace_activities.output END,
               input_key=CASE WHEN excluded.input_bytes>COALESCE(trace_activities.input_bytes,0) THEN excluded.input_key ELSE trace_activities.input_key END,
               output_key=CASE WHEN excluded.output_bytes>COALESCE(trace_activities.output_bytes,0) THEN excluded.output_key ELSE trace_activities.output_key END,
               input_bytes=MAX(COALESCE(trace_activities.input_bytes,0),COALESCE(excluded.input_bytes,0)),
               output_bytes=MAX(COALESCE(trace_activities.output_bytes,0),COALESCE(excluded.output_bytes,0)),metadata=excluded.metadata",
            params![id.map(sql_integer).transpose()?,sql_integer(span)?,native.id,native.parent,kind,native.title,
                native.started.map(sql_integer).transpose()?,native.ended.map(sql_integer).transpose()?,status,
                crate::harness::steps::truncate(native.input.as_deref().unwrap_or_default(),crate::harness::steps::MAX_DETAIL_BYTES),
                crate::harness::steps::truncate(native.output.as_deref().unwrap_or_default(),crate::harness::steps::MAX_DETAIL_BYTES),
                anchor,input_key,output_key,native.input.as_ref().map(|s|i64::try_from(s.len()).map_err(|_|StoreError::InvalidIdentifier)).transpose()?,native.output.as_ref().map(|s|i64::try_from(s.len()).map_err(|_|StoreError::InvalidIdentifier)).transpose()?,native.metadata.to_string()]
        )?;
        transaction.execute(
            "UPDATE trace_activities SET status='interrupted' WHERE span_id=?1 AND status='running'
             AND EXISTS(SELECT 1 FROM trace_events e JOIN trace_spans s ON s.terminal_id=e.terminal_id
                WHERE s.id=?1 AND e.kind IN ('processStopped','processExited','processFailed'))",
            [sql_integer(span)?],
        )?;
        let timestamp = native.ended.or(native.started).unwrap_or(0);
        super::traces::insert_event(
            &transaction,
            workflow,
            TraceSpanId(span),
            timestamp,
            crate::TraceEventKind::WorkflowEvent,
            &format!("{} (harness history)", native.title),
            None,
        )?;
        transaction.commit()?;
        let _ = terminal;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::harness::steps::{HarnessStep, StepKind};
    use crate::store::HarnessStepContext;
    use crate::{TerminalId, TraceAnchor, WorkflowKind};
    use std::path::Path;

    fn fixture(store: &mut Store) -> (WorkflowId, TraceSpanId) {
        let session = store
            .create_session(Path::new("/fixture"), "History", 1)
            .unwrap();
        let workflow = store
            .create_workflow(session, "Agent", WorkflowKind::Terminal, &[])
            .unwrap()
            .0;
        let span = store
            .record_harness_step(
                HarnessStepContext {
                    workflow_id: workflow,
                    single_agent: true,
                    activate: false,
                    span: None,
                },
                &HarnessStep {
                    activity: None,
                    session_id: None,
                    kind: StepKind::Prompt,
                    turn_id: Some("observer-turn".into()),
                    tool_call_id: None,
                    title: "Review file".into(),
                    detail: "Review file".into(),
                },
                1000,
                &TraceAnchor {
                    terminal_id: TerminalId::from_value(7),
                    byte_offset: 0,
                    boundary_sizes: None,
                },
            )
            .unwrap()
            .unwrap();
        store.execute_test_sql("INSERT INTO workflow_terminals(terminal_id,workflow_id,harness_session) VALUES(7,1,'native-session');
            UPDATE trace_lanes SET harness='Claude Code';");
        (workflow, span)
    }

    #[test]
    fn history_enrichment_keeps_live_failures_and_interrupts_missing_endpoints_after_process_exit()
    {
        let mut store = Store::open_in_memory().unwrap();
        let (workflow, span) = fixture(&mut store);
        store.connection.execute("INSERT INTO trace_activities(span_id,source_id,kind,title,status,input,output) VALUES(?1,'tool:root:failed','tool','Failed tool','failed','','error')",[sql_integer(span.0).unwrap()]).unwrap();
        let mut row = NativeActivity {
            id: "tool:root:failed".into(),
            parent: None,
            turn: Some("observer-turn".into()),
            kind: ActivityKind::Tool,
            title: "Tool result".into(),
            input: None,
            output: Some("full error detail".repeat(1000)),
            started: None,
            ended: Some(2000),
            failed: false,
            metadata: serde_json::json!({"source":"Harness history"}),
        };
        store
            .reconcile_native_activity(workflow, "native-session", &row)
            .unwrap();
        assert_eq!(
            store.trace_activities(span, None, 200).unwrap().activities[0].status,
            crate::TraceActivityStatus::Failed
        );
        store.connection.execute("INSERT INTO trace_events(workflow_id,span_id,timestamp,kind,message,terminal_id,byte_offset) VALUES(?1,?2,2500,'processExited','Exited',7,0)",params![sql_integer(workflow.0).unwrap(),sql_integer(span.0).unwrap()]).unwrap();
        row.id = "tool:root:unfinished".into();
        row.started = Some(1500);
        row.ended = None;
        row.output = None;
        store
            .reconcile_native_activity(workflow, "native-session", &row)
            .unwrap();
        assert_eq!(
            store.trace_activities(span, None, 200).unwrap().activities[1].status,
            crate::TraceActivityStatus::Interrupted
        );
    }

    #[test]
    fn genuine_native_response_joins_the_observer_prompt_and_retains_full_unicode_details() {
        let data = tempfile::tempdir().unwrap();
        let mut store = Store::open(&data.path().join("twine.db")).unwrap();
        let (workflow, span) = fixture(&mut store);
        let body = "Result ☃\n".repeat(20_000);
        let row = NativeActivity {
            id: "model:root:response-1".into(),
            parent: None,
            turn: Some("different-native-user-id".into()),
            kind: ActivityKind::Model,
            title: "LLM call".into(),
            input: None,
            output: Some(body.clone()),
            started: None,
            ended: Some(2000),
            failed: false,
            metadata: serde_json::json!({"source":"Harness history","model":"native-model","responseId":"response-1",
                "inputTokens":20,"outputTokens":5,"promptTitle":"Review file","promptTime":999}),
        };
        assert!(
            store
                .reconcile_native_activity(workflow, "native-session", &row)
                .unwrap()
        );
        let revision = store.trace_summary(workflow).unwrap().revision;
        assert!(
            !store
                .reconcile_native_activity(workflow, "native-session", &row)
                .unwrap()
        );
        assert_eq!(store.trace_summary(workflow).unwrap().revision, revision);
        let page = store.trace_activities(span, None, 200).unwrap();
        assert_eq!(page.counts.models, 1);
        assert_eq!(page.activities[0].started_at, None);
        assert_eq!(page.activities[0].output_bytes, Some(body.len() as u64));
        let activity = page.activities[0].activity_id;
        drop(store);
        let store = Store::open(&data.path().join("twine.db")).unwrap();
        let mut read = String::new();
        loop {
            let page = store
                .trace_detail(activity, true, read.len() as u64, 64 * 1024)
                .unwrap();
            read.push_str(&page.text);
            if page.next_offset.is_none() {
                break;
            }
        }
        assert_eq!(read, body);
        assert!(store.trace_detail(activity, true, 0, 1).is_err());
        assert!(store.history_request(span).unwrap().is_some());
    }

    #[test]
    fn unrelated_or_ambiguous_native_prompts_never_attach_to_the_latest_span() {
        let mut store = Store::open_in_memory().unwrap();
        let (workflow, _) = fixture(&mut store);
        let row = NativeActivity {
            id: "model:root:wrong".into(),
            parent: None,
            turn: Some("unknown".into()),
            kind: ActivityKind::Model,
            title: "LLM call".into(),
            input: None,
            output: Some("data".into()),
            started: None,
            ended: Some(2000),
            failed: false,
            metadata: serde_json::json!({"promptTitle":"Different prompt","promptTime":1000}),
        };
        assert!(
            !store
                .reconcile_native_activity(workflow, "native-session", &row)
                .unwrap()
        );
        assert!(
            !store
                .reconcile_native_activity(workflow, "unrelated-session", &row)
                .unwrap()
        );
    }
}
