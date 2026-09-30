//! Durable, harness-independent steps. Adapters normalize activity before it reaches storage.

use rusqlite::{OptionalExtension, params};

use super::traces::{insert_event, insert_span_record};
use super::{NewTraceSpan, Store, StoreError, TraceEnding, sql_integer};
use crate::harness::steps::{HarnessStep, StepKind};
use crate::{TerminalId, TraceAnchor, TraceEventKind, TraceSpanId, TraceSpanStatus, WorkflowId};

impl Store {
    pub(crate) fn has_harness_workflow(&self, workflow_id: WorkflowId) -> Result<bool, StoreError> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM workflows WHERE id = ?1)",
            [sql_integer(workflow_id.0)?],
            |row| row.get(0),
        )?)
    }
    pub(crate) fn harness_span_is_running(&self, span: TraceSpanId) -> Result<bool, StoreError> {
        Ok(self.connection.query_row(
            "SELECT status = 'running' FROM trace_spans WHERE id = ?1",
            [sql_integer(span.0)?],
            |row| row.get(0),
        )?)
    }
    pub(crate) fn has_harness_turn(
        &self,
        terminal_id: TerminalId,
        turn_id: Option<&str>,
    ) -> Result<bool, StoreError> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM trace_spans WHERE terminal_id = ?1 AND (?2 IS NULL OR harness_turn_id = ?2))",
            params![sql_integer(terminal_id.value())?, turn_id], |row| row.get(0))?)
    }

    pub(crate) fn record_harness_step(
        &mut self,
        workflow_id: WorkflowId,
        single_agent: bool,
        activate: bool,
        step: &HarnessStep,
        observed_at: u64,
        anchor: &TraceAnchor,
    ) -> Result<Option<TraceSpanId>, StoreError> {
        let transaction = self.connection.transaction()?;
        if activate {
            activate_harness_trace(&transaction, anchor.terminal_id)?;
        }
        let current: Option<TraceSpanId> = transaction
            .query_row(
                "SELECT s.id FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id
             WHERE l.workflow_id = ?1 AND s.terminal_id = ?2
             AND (?3 IS NULL OR s.harness_turn_id = ?3) ORDER BY s.id DESC LIMIT 1",
                params![
                    sql_integer(workflow_id.0)?,
                    sql_integer(anchor.terminal_id.value())?,
                    if single_agent {
                        step.turn_id.as_deref()
                    } else {
                        None
                    },
                ],
                |row| Ok(TraceSpanId(super::unsigned_column(row, 0)?)),
            )
            .optional()?;
        let message = step.message();
        let span = if single_agent
            && step.kind == StepKind::Prompt
            && current.as_ref().is_none_or(|_| step.turn_id.is_none())
        {
            start_prompt_span(&transaction, workflow_id, step, observed_at, anchor)?
        } else if let Some(current) = current {
            current
        } else {
            // A missing prompt hook must not manufacture a successful response or process span.
            // Recording can recover at the next explicit prompt.
            return Ok(None);
        };
        if single_agent && step.kind == StepKind::Prompt {
            transaction.execute(
                "UPDATE trace_events SET span_id = ?1 WHERE workflow_id = ?2 AND terminal_id = ?3 AND span_id IS NULL",
                params![sql_integer(span.0)?, sql_integer(workflow_id.0)?, sql_integer(anchor.terminal_id.value())?],
            )?;
        }
        if single_agent && step.kind == StepKind::Responded {
            // An async Stop can arrive after process exit. Its explicit completion distinguishes
            // a response from a process ending; cancellation remains stopped.
            transaction.execute(
                "UPDATE trace_spans SET status = 'exited', work_span = 1, ended_at = MAX(started_at, ?2)
                 WHERE id = ?1 AND (status IN ('running', 'exited') OR (status = 'stopped'
                 AND NOT EXISTS(SELECT 1 FROM trace_events WHERE terminal_id = ?3 AND kind = 'processStopped')))",
                params![sql_integer(span.0)?, sql_integer(observed_at)?, sql_integer(anchor.terminal_id.value())?],
            )?;
        }
        if single_agent && step.kind == StepKind::ToolStarted {
            // Another user's Stop hook may have requested continuation. Subsequent tool work
            // resumes that same prompt's response rather than creating a new unit of work.
            transaction.execute(
                "UPDATE trace_spans SET status = 'running', ended_at = NULL, work_span = 0
                 WHERE id = ?1 AND status = 'exited' AND work_span = 1
                 AND id = (SELECT id FROM trace_spans WHERE terminal_id = ?2 ORDER BY id DESC LIMIT 1)
                 AND NOT EXISTS(SELECT 1 FROM trace_events WHERE terminal_id = ?2
                    AND kind IN ('processStopped', 'processExited', 'processFailed'))",
                params![sql_integer(span.0)?, sql_integer(anchor.terminal_id.value())?],
            )?;
        }
        insert_event(
            &transaction,
            workflow_id,
            span,
            observed_at,
            TraceEventKind::WorkflowEvent,
            &message,
            Some(anchor),
        )?;
        transaction.commit()?;
        Ok(Some(span))
    }

    /// Process lifecycle remains observable between turns and after explicit response completion.
    pub(crate) fn record_harness_process_ending(
        &mut self,
        workflow_id: WorkflowId,
        terminal_id: TerminalId,
        ending: &TraceEnding<'_>,
    ) -> Result<(), StoreError> {
        let transaction = self.connection.transaction()?;
        insert_process_ending(&transaction, workflow_id, terminal_id, ending)?;
        transaction.commit()?;
        Ok(())
    }
}

fn activate_harness_trace(
    transaction: &rusqlite::Transaction<'_>,
    terminal_id: TerminalId,
) -> Result<(), StoreError> {
    transaction.execute(
        "UPDATE trace_events SET span_id = NULL WHERE span_id IN
        (SELECT id FROM trace_spans WHERE terminal_id = ?1)",
        [sql_integer(terminal_id.value())?],
    )?;
    transaction.execute(
        "DELETE FROM trace_spans WHERE terminal_id = ?1",
        [sql_integer(terminal_id.value())?],
    )?;
    Ok(())
}

fn start_prompt_span(
    transaction: &rusqlite::Transaction<'_>,
    workflow_id: WorkflowId,
    step: &HarnessStep,
    observed_at: u64,
    anchor: &TraceAnchor,
) -> Result<TraceSpanId, StoreError> {
    let prior: Option<TraceSpanId> = transaction.query_row(
        "SELECT id FROM trace_spans WHERE terminal_id = ?1 AND status = 'running' ORDER BY id DESC LIMIT 1",
        [sql_integer(anchor.terminal_id.value())?], |row| Ok(TraceSpanId(super::unsigned_column(row, 0)?))).optional()?;
    if let Some(prior) = prior {
        // A second prompt can interrupt a response. Preserve the unfinished turn.
        super::traces::finish_span(
            transaction,
            prior,
            &TraceEnding {
                observed_at,
                status: TraceSpanStatus::Stopped,
                kind: TraceEventKind::WorkflowEvent,
                message: "Response interrupted by the next prompt.",
                anchor: Some(anchor.clone()),
            },
        )?;
    }
    let span = insert_span_record(
        transaction,
        &NewTraceSpan {
            workflow_id,
            lane_key: "agent",
            lane_name: "Agent",
            is_agent: true,
            role: Some("agent"),
            // The lane was created at launch with the selected harness's metadata.
            harness: None,
            title: &step.title,
            started_at: observed_at,
            anchor: Some(anchor.clone()),
        },
    )?;
    transaction.execute(
        "UPDATE trace_spans SET harness_turn_id = ?2 WHERE id = ?1",
        params![sql_integer(span.0)?, step.turn_id],
    )?;
    // A prompt hook can arrive after cancellation, exit, or workflow close. Replay the
    // authoritative process ending instead of leaving an impossible active response.
    transaction.execute(
        "UPDATE trace_spans SET ended_at = started_at, status = CASE
            WHEN EXISTS(SELECT 1 FROM trace_events WHERE terminal_id = ?2 AND kind = 'processStopped') THEN 'stopped'
            WHEN EXISTS(SELECT 1 FROM trace_events WHERE terminal_id = ?2 AND kind = 'processFailed') THEN 'failed'
            ELSE 'exited' END
         WHERE id = ?1 AND EXISTS(SELECT 1 FROM trace_events WHERE terminal_id = ?2
            AND kind IN ('processStopped', 'processExited', 'processFailed'))",
        params![sql_integer(span.0)?, sql_integer(anchor.terminal_id.value())?],
    )?;
    Ok(span)
}

pub(super) fn insert_process_ending(
    transaction: &rusqlite::Transaction<'_>,
    workflow_id: WorkflowId,
    terminal_id: TerminalId,
    ending: &TraceEnding<'_>,
) -> Result<(), StoreError> {
    transaction.execute(
            "INSERT INTO trace_events (workflow_id, span_id, timestamp, kind, message, terminal_id, byte_offset, boundary_sizes)
             VALUES (?1, (SELECT s.id FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id
             WHERE l.workflow_id = ?1 AND s.terminal_id = ?5 ORDER BY s.id DESC LIMIT 1), ?2, ?3, ?4, ?5, ?6, ?7)",
            params![sql_integer(workflow_id.0)?, sql_integer(ending.observed_at)?,
                super::traces::kind_name(ending.kind), ending.message, sql_integer(terminal_id.value())?,
                ending.anchor.as_ref().map(|a| sql_integer(a.byte_offset)).transpose()?,
                super::traces::encode_boundary_sizes(ending.anchor.as_ref())],
        )?;
    Ok(())
}
