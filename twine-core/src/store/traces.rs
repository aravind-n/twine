use std::path::Path;

use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};

use super::{Store, StoreError, sql_integer, unsigned_column};
use crate::trace::validate_limit;
use crate::{
    TerminalId, TraceAnchor, TraceError, TraceEvent, TraceEventId, TraceEventKind, TraceEventsPage,
    TraceLane, TraceLaneId, TraceSpan, TraceSpanId, TraceSpanStatus, TraceSummary, WorkflowId,
    WorkflowTracePage,
};

pub(crate) struct NewTraceSpan<'a> {
    pub workflow_id: WorkflowId,
    /// Stable within a workflow; agents use their durable agent ID.
    pub lane_key: &'a str,
    pub lane_name: &'a str,
    pub is_agent: bool,
    pub role: Option<&'a str>,
    pub harness: Option<&'a str>,
    pub title: &'a str,
    pub started_at: u64,
    pub anchor: Option<TraceAnchor>,
}

pub(crate) struct TraceEnding<'a> {
    pub observed_at: u64,
    pub status: TraceSpanStatus,
    pub kind: TraceEventKind,
    pub message: &'a str,
    pub anchor: Option<TraceAnchor>,
}

impl Store {
    /// Once Twine's first integration mark arrives, retain the process event while replacing its
    /// lifetime interval with command intervals. Historical spans are never rewritten.
    pub(crate) fn activate_command_trace(
        &mut self,
        placeholder: TraceSpanId,
    ) -> Result<(), StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "UPDATE trace_events SET span_id = NULL WHERE span_id = ?1",
            [sql_integer(placeholder.0)?],
        )?;
        transaction.execute(
            "DELETE FROM trace_spans WHERE id = ?1 AND status = 'running'",
            [sql_integer(placeholder.0)?],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub(crate) fn start_command_trace(
        &mut self,
        new: &NewTraceSpan<'_>,
    ) -> Result<TraceSpanId, StoreError> {
        let transaction = self.connection.transaction()?;
        let span = insert_span_record(&transaction, new)?;
        transaction.execute(
            "UPDATE trace_spans SET work_span = 1 WHERE id = ?1",
            [sql_integer(span.0)?],
        )?;
        insert_event(
            &transaction,
            new.workflow_id,
            span,
            new.started_at,
            TraceEventKind::WorkflowEvent,
            "Command started.",
            new.anchor.as_ref(),
        )?;
        transaction.commit()?;
        Ok(span)
    }

    /// The span and its start event commit together; no terminal text is inspected.
    pub(crate) fn start_trace_span(
        &mut self,
        new: &NewTraceSpan<'_>,
    ) -> Result<TraceSpanId, StoreError> {
        let transaction = self.connection.transaction()?;
        let span_id = insert_span(&transaction, new)?;
        transaction.commit()?;
        Ok(span_id)
    }

    /// Every agent start commits together, so a failed recording leaves no partial live trace.
    pub(crate) fn start_trace_spans(
        &mut self,
        spans: &[NewTraceSpan<'_>],
    ) -> Result<Vec<TraceSpanId>, StoreError> {
        let transaction = self.connection.transaction()?;
        let ids = spans
            .iter()
            .map(|span| insert_span(&transaction, span))
            .collect::<Result<_, _>>()?;
        transaction.commit()?;
        Ok(ids)
    }

    /// Configuring an agent, ending its placeholder, and recording its start commit together.
    pub(crate) fn start_agent_trace(
        &mut self,
        new: &NewTraceSpan<'_>,
        harness: crate::HarnessId,
        placeholder: Option<(TraceSpanId, &TraceEnding<'_>)>,
    ) -> Result<TraceSpanId, StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "UPDATE workflows SET name = ?2, kind = 'single_agent', harness = ?3,
             lifecycle_status = 'running' WHERE id = ?1",
            params![
                sql_integer(new.workflow_id.0)?,
                new.title,
                super::workflows::harness_name(harness)
            ],
        )?;
        if let Some((span_id, ending)) = placeholder {
            finish_span(&transaction, span_id, ending)?;
        }
        let span_id = insert_span(&transaction, new)?;
        transaction.commit()?;
        Ok(span_id)
    }

    /// A completed span is immutable. Exit/close races produce exactly one ending.
    pub(crate) fn finish_trace_span(
        &mut self,
        span_id: TraceSpanId,
        ending: &TraceEnding<'_>,
    ) -> Result<Option<WorkflowId>, StoreError> {
        let transaction = self.connection.transaction()?;
        let workflow_id = finish_span(&transaction, span_id, ending)?;
        transaction.commit()?;
        Ok(workflow_id)
    }

    pub(crate) fn close_workflow_and_trace(
        &mut self,
        workflow_id: WorkflowId,
        closed_at: u64,
        endings: &[(TraceSpanId, TraceEnding<'_>)],
        idle_endings: &[(TerminalId, TraceEnding<'_>)],
    ) -> Result<bool, StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "UPDATE workflows SET closed_at = ?2 WHERE id = ?1",
            params![sql_integer(workflow_id.0)?, sql_integer(closed_at)?],
        )?;
        let mut changed = false;
        for (terminal_id, ending) in idle_endings {
            super::harness_steps::insert_process_ending(
                &transaction,
                workflow_id,
                *terminal_id,
                ending,
            )?;
            changed = true;
        }
        for (id, ending) in endings {
            changed |= finish_span(&transaction, *id, ending)?.is_some();
        }
        // A process may already have exited while its assignment still awaits completion.
        let unfinished = {
            let mut statement = transaction.prepare(
                "SELECT s.id FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id
                 WHERE l.workflow_id = ?1 AND s.work_span = 1 AND s.status = 'running'",
            )?;
            statement
                .query_map([sql_integer(workflow_id.0)?], |row| unsigned_column(row, 0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        for id in unfinished {
            changed |= finish_span(
                &transaction,
                TraceSpanId(id),
                &TraceEnding {
                    observed_at: closed_at,
                    status: TraceSpanStatus::Stopped,
                    kind: TraceEventKind::WorkflowEvent,
                    message: "Assignment stopped when its workflow was closed.",
                    anchor: None,
                },
            )?
            .is_some();
        }
        transaction.commit()?;
        Ok(changed)
    }

    pub(crate) fn trace_summary(&self, id: WorkflowId) -> Result<TraceSummary, StoreError> {
        summary(&self.connection, id)
    }

    pub(crate) fn trace_summaries(&self, folder: &Path) -> Result<Vec<TraceSummary>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT w.id FROM workflows w JOIN sessions s ON s.id = w.session_id
             WHERE s.folder = ?1 AND w.closed_at IS NULL ORDER BY w.id",
        )?;
        let ids = statement
            .query_map([folder.to_string_lossy().as_ref()], |row| {
                unsigned_column(row, 0)
            })?
            .collect::<Result<Vec<_>, _>>()?;
        ids.into_iter()
            .map(|id| self.trace_summary(WorkflowId(id)))
            .collect()
    }

    pub(crate) fn workflow_trace(
        &self,
        id: WorkflowId,
        before: Option<TraceSpanId>,
        limit: usize,
    ) -> Result<WorkflowTracePage, TraceError> {
        validate_limit(limit)?;
        // Read the revision and page from one SQLite snapshot, including across connections.
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(StoreError::from)?;
        let exists: bool = transaction
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM workflows WHERE id = ?1)",
                [sql_integer(id.0)?],
                |row| row.get(0),
            )
            .map_err(StoreError::from)?;
        if !exists {
            return Err(TraceError::WorkflowNotFound);
        }
        let summary = summary(&transaction, id)?;
        let mut statement = transaction.prepare(
            "SELECT id, name, is_agent, role, harness, lane_key FROM trace_lanes WHERE workflow_id = ?1 ORDER BY id",
        ).map_err(StoreError::from)?;
        let lanes = statement
            .query_map([sql_integer(id.0)?], |row| {
                Ok(TraceLane {
                    lane_id: TraceLaneId(unsigned_column(row, 0)?),
                    workflow_id: id,
                    agent_id: row
                        .get::<_, String>(5)?
                        .strip_prefix("agent:")
                        .and_then(|id| id.parse().ok())
                        .map(crate::AgentId),
                    name: row.get(1)?,
                    is_agent: row.get(2)?,
                    role: row.get(3)?,
                    harness: row.get(4)?,
                })
            })
            .map_err(StoreError::from)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)?;
        let mut statement = transaction
            .prepare(
                "SELECT s.id, s.lane_id, s.title, s.started_at, s.ended_at, s.status, s.terminal_id, s.work_span
             FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id
             WHERE l.workflow_id = ?1 AND (?2 IS NULL OR s.id < ?2) ORDER BY s.id DESC LIMIT ?3",
            )
            .map_err(StoreError::from)?;
        let mut spans = statement
            .query_map(
                params![
                    sql_integer(id.0)?,
                    before.map(|id| sql_integer(id.0)).transpose()?,
                    i64::try_from(limit + 1).map_err(|_| StoreError::InvalidIdentifier)?
                ],
                read_span,
            )
            .map_err(StoreError::from)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)?;
        let has_more = spans.len() > limit;
        spans.truncate(limit);
        let next_before = has_more
            .then(|| spans.last().map(|span| span.span_id))
            .flatten();
        Ok(WorkflowTracePage {
            summary,
            lanes,
            spans,
            next_before,
        })
    }

    pub(crate) fn trace_events(
        &self,
        span_id: TraceSpanId,
        after: Option<TraceEventId>,
        limit: usize,
    ) -> Result<TraceEventsPage, TraceError> {
        validate_limit(limit)?;
        let transaction = self
            .connection
            .unchecked_transaction()
            .map_err(StoreError::from)?;
        let workflow_id = transaction.query_row(
            "SELECT l.workflow_id FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id WHERE s.id = ?1",
            [sql_integer(span_id.0)?], |row| unsigned_column(row, 0),
        ).optional().map_err(StoreError::from)?.map(WorkflowId).ok_or(TraceError::SpanNotFound)?;
        let revision = summary(&transaction, workflow_id)?.revision;
        let mut statement = transaction
            .prepare(
                "SELECT id, timestamp, kind, message, terminal_id, byte_offset, boundary_sizes FROM trace_events
             WHERE span_id = ?1 AND (?2 IS NULL OR id > ?2) ORDER BY id LIMIT ?3",
            )
            .map_err(StoreError::from)?;
        let mut events = statement
            .query_map(
                params![
                    sql_integer(span_id.0)?,
                    after.map(|id| sql_integer(id.0)).transpose()?,
                    i64::try_from(limit + 1).map_err(|_| StoreError::InvalidIdentifier)?
                ],
                |row| {
                    Ok(TraceEvent {
                        event_id: TraceEventId(unsigned_column(row, 0)?),
                        workflow_id,
                        span_id: Some(span_id),
                        timestamp: unsigned_column(row, 1)?,
                        kind: read_kind(row, 2)?,
                        message: row.get(3)?,
                        anchor: row
                            .get::<_, Option<i64>>(4)?
                            .map(|_| {
                                Ok::<_, rusqlite::Error>(TraceAnchor {
                                    terminal_id: TerminalId::from_value(unsigned_column(row, 4)?),
                                    byte_offset: unsigned_column(row, 5)?,
                                    boundary_sizes: read_boundary_sizes(row, 6)?,
                                })
                            })
                            .transpose()?,
                    })
                },
            )
            .map_err(StoreError::from)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)?;
        let has_more = events.len() > limit;
        events.truncate(limit);
        let next_after = has_more
            .then(|| events.last().map(|event| event.event_id))
            .flatten();
        Ok(TraceEventsPage {
            workflow_id,
            span_id,
            revision,
            events,
            next_after,
        })
    }
}

pub(super) fn insert_span(
    transaction: &Transaction<'_>,
    new: &NewTraceSpan<'_>,
) -> Result<TraceSpanId, StoreError> {
    let span_id = insert_span_record(transaction, new)?;
    insert_event(
        transaction,
        new.workflow_id,
        span_id,
        new.started_at,
        TraceEventKind::ProcessStarted,
        "Process started.",
        new.anchor.as_ref(),
    )?;
    Ok(span_id)
}

/// Inserts the interval separately from process events, so a handoff can precede launch.
pub(super) fn insert_span_record(
    transaction: &Transaction<'_>,
    new: &NewTraceSpan<'_>,
) -> Result<TraceSpanId, StoreError> {
    transaction.execute(
        "INSERT INTO trace_lanes (workflow_id, lane_key, name, is_agent, role, harness)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(workflow_id, lane_key) DO NOTHING",
        params![
            sql_integer(new.workflow_id.0)?,
            new.lane_key,
            new.lane_name,
            new.is_agent,
            new.role,
            new.harness
        ],
    )?;
    let lane_id: i64 = transaction.query_row(
        "SELECT id FROM trace_lanes WHERE workflow_id = ?1 AND lane_key = ?2",
        params![sql_integer(new.workflow_id.0)?, new.lane_key],
        |row| row.get(0),
    )?;
    let terminal_id = new
        .anchor
        .as_ref()
        .map(|anchor| sql_integer(anchor.terminal_id.value()))
        .transpose()?;
    transaction.execute(
        "INSERT INTO trace_spans (lane_id, title, started_at, status, terminal_id)
             VALUES (?1, ?2, ?3, 'running', ?4)",
        params![
            lane_id,
            new.title,
            sql_integer(new.started_at)?,
            terminal_id
        ],
    )?;
    let span_id = transaction.last_insert_rowid();
    Ok(TraceSpanId(
        u64::try_from(span_id).map_err(|_| StoreError::InvalidIdentifier)?,
    ))
}

pub(super) fn finish_span(
    transaction: &Transaction<'_>,
    span_id: TraceSpanId,
    ending: &TraceEnding<'_>,
) -> Result<Option<WorkflowId>, StoreError> {
    let active: Option<(i64, i64, bool, String)> = transaction
        .query_row(
            "SELECT l.workflow_id, s.started_at, s.work_span, s.status FROM trace_spans s
             JOIN trace_lanes l ON l.id = s.lane_id WHERE s.id = ?1",
            [sql_integer(span_id.0)?],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?;
    let Some((workflow_id, started_at, work_span, status)) = active else {
        return Ok(None);
    };
    if !work_span && status != "running" {
        return Ok(None);
    }
    let ended_at = sql_integer(ending.observed_at)?.max(started_at);
    // An exit or process failure leaves assigned work awaiting an explicit completion. A stop
    // may end unfinished work, but cannot overwrite an accepted completion.
    if status == "running"
        && (!work_span
            || !matches!(
                ending.kind,
                TraceEventKind::ProcessExited | TraceEventKind::ProcessFailed
            ))
    {
        transaction.execute(
            "UPDATE trace_spans SET ended_at = ?2, status = ?3 WHERE id = ?1",
            params![
                sql_integer(span_id.0)?,
                ended_at,
                status_name(ending.status)
            ],
        )?;
    }
    let workflow_id =
        WorkflowId(u64::try_from(workflow_id).map_err(|_| StoreError::InvalidIdentifier)?);
    insert_event(
        transaction,
        workflow_id,
        span_id,
        u64::try_from(ended_at).map_err(|_| StoreError::InvalidIdentifier)?,
        ending.kind,
        ending.message,
        ending.anchor.as_ref(),
    )?;
    Ok(Some(workflow_id))
}

pub(super) fn insert_event(
    transaction: &Transaction<'_>,
    workflow_id: WorkflowId,
    span_id: TraceSpanId,
    timestamp: u64,
    kind: TraceEventKind,
    message: &str,
    anchor: Option<&TraceAnchor>,
) -> Result<(), StoreError> {
    transaction.execute(
            "INSERT INTO trace_events (workflow_id, span_id, timestamp, kind, message, terminal_id, byte_offset, boundary_sizes)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![sql_integer(workflow_id.0)?, sql_integer(span_id.0)?, sql_integer(timestamp)?, kind_name(kind), message,
                anchor.map(|anchor| sql_integer(anchor.terminal_id.value())).transpose()?,
                anchor.map(|anchor| sql_integer(anchor.byte_offset)).transpose()?,
                encode_boundary_sizes(anchor)],
        )?;
    Ok(())
}

fn summary(connection: &Connection, id: WorkflowId) -> Result<TraceSummary, StoreError> {
    Ok(connection.query_row(
        "SELECT
          (SELECT COALESCE(MAX(id), 0) FROM trace_events WHERE workflow_id = ?1),
          (SELECT COUNT(*) FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id WHERE l.workflow_id = ?1),
          (SELECT COUNT(*) FROM trace_lanes WHERE workflow_id = ?1 AND is_agent = 1)",
        [sql_integer(id.0)?], |row| Ok(TraceSummary {
            workflow_id: id, revision: unsigned_column(row, 0)?,
            span_count: unsigned_column(row, 1)?, agent_count: unsigned_column(row, 2)?,
        }),
    )?)
}

pub(super) fn encode_boundary_sizes(anchor: Option<&TraceAnchor>) -> Option<Vec<u8>> {
    anchor?.boundary_sizes.as_ref().map(|sizes| {
        sizes
            .iter()
            .flat_map(|size| {
                [size.rows, size.columns, size.pixel_width, size.pixel_height]
                    .into_iter()
                    .flat_map(u16::to_le_bytes)
            })
            .collect()
    })
}

fn read_boundary_sizes(
    row: &Row<'_>,
    index: usize,
) -> rusqlite::Result<Option<Vec<crate::TerminalSize>>> {
    row.get::<_, Option<Vec<u8>>>(index)?
        .map(|bytes| {
            if bytes.len() > 2048 || bytes.len() % 8 != 0 {
                return Err(rusqlite::Error::InvalidQuery);
            }
            bytes
                .as_chunks::<8>()
                .0
                .iter()
                .map(|bytes| {
                    let size = crate::TerminalSize {
                        rows: u16::from_le_bytes([bytes[0], bytes[1]]),
                        columns: u16::from_le_bytes([bytes[2], bytes[3]]),
                        pixel_width: u16::from_le_bytes([bytes[4], bytes[5]]),
                        pixel_height: u16::from_le_bytes([bytes[6], bytes[7]]),
                    };
                    size.validate().map_err(|_| rusqlite::Error::InvalidQuery)
                })
                .collect()
        })
        .transpose()
}

fn read_span(row: &Row<'_>) -> rusqlite::Result<TraceSpan> {
    let name: String = row.get(5)?;
    let status = match name.as_str() {
        "running" => TraceSpanStatus::Running,
        "exited" if row.get::<_, bool>(7)? => TraceSpanStatus::Completed,
        "exited" => TraceSpanStatus::Exited,
        "failed" => TraceSpanStatus::Failed,
        "stopped" => TraceSpanStatus::Stopped,
        _ => return Err(rusqlite::Error::InvalidQuery),
    };
    Ok(TraceSpan {
        span_id: TraceSpanId(unsigned_column(row, 0)?),
        lane_id: TraceLaneId(unsigned_column(row, 1)?),
        title: row.get(2)?,
        started_at: unsigned_column(row, 3)?,
        ended_at: row
            .get::<_, Option<i64>>(4)?
            .map(|_| unsigned_column(row, 4))
            .transpose()?,
        status,
        terminal_id: row
            .get::<_, Option<i64>>(6)?
            .map(|_| unsigned_column(row, 6).map(TerminalId::from_value))
            .transpose()?,
        is_live: false,
    })
}

fn read_kind(row: &Row<'_>, index: usize) -> rusqlite::Result<TraceEventKind> {
    match row.get::<_, String>(index)?.as_str() {
        "processStarted" => Ok(TraceEventKind::ProcessStarted),
        "processExited" => Ok(TraceEventKind::ProcessExited),
        "processFailed" => Ok(TraceEventKind::ProcessFailed),
        "processStopped" => Ok(TraceEventKind::ProcessStopped),
        "workflowEvent" => Ok(TraceEventKind::WorkflowEvent),
        _ => Err(rusqlite::Error::InvalidQuery),
    }
}

const fn status_name(status: TraceSpanStatus) -> &'static str {
    match status {
        TraceSpanStatus::Running => "running",
        // The work_span column distinguishes completion from legacy process exit on disk.
        TraceSpanStatus::Completed | TraceSpanStatus::Exited => "exited",
        TraceSpanStatus::Failed => "failed",
        TraceSpanStatus::Stopped => "stopped",
    }
}

pub(super) const fn kind_name(kind: TraceEventKind) -> &'static str {
    match kind {
        TraceEventKind::ProcessStarted => "processStarted",
        TraceEventKind::ProcessExited => "processExited",
        TraceEventKind::ProcessFailed => "processFailed",
        TraceEventKind::ProcessStopped => "processStopped",
        TraceEventKind::WorkflowEvent => "workflowEvent",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::WorkflowKind;

    fn workflow(store: &mut Store) -> WorkflowId {
        let session = store
            .create_session(Path::new("/folder"), "Work", 100)
            .unwrap();
        store
            .create_workflow(session, "Terminal", WorkflowKind::Terminal, &[])
            .unwrap()
            .0
    }

    fn start(store: &mut Store, workflow_id: WorkflowId, terminal: u64) -> TraceSpanId {
        store
            .start_trace_span(&NewTraceSpan {
                workflow_id,
                lane_key: "terminal",
                lane_name: "Terminal",
                is_agent: false,
                role: None,
                harness: None,
                title: "Shell",
                started_at: 100,
                anchor: Some(TraceAnchor {
                    terminal_id: TerminalId::from_value(terminal),
                    byte_offset: 0,
                    boundary_sizes: Some(Vec::new()),
                }),
            })
            .unwrap()
    }

    #[test]
    fn start_and_ending_are_atomic_idempotent_and_survive_reopen() {
        let data = tempfile::tempdir().unwrap();
        let path = data.path().join("twine.db");
        let mut store = Store::open(&path).unwrap();
        let id = workflow(&mut store);
        let span = start(&mut store, id, 7);
        let ending = TraceEnding {
            observed_at: 90,
            status: TraceSpanStatus::Exited,
            kind: TraceEventKind::ProcessExited,
            message: "Process exited with code 0.",
            anchor: Some(TraceAnchor {
                terminal_id: TerminalId::from_value(7),
                byte_offset: 42,
                boundary_sizes: Some(vec![
                    crate::TerminalSize {
                        rows: 24,
                        columns: 80,
                        pixel_width: 800,
                        pixel_height: 480,
                    },
                    crate::TerminalSize {
                        rows: 10,
                        columns: 40,
                        pixel_width: 400,
                        pixel_height: 200,
                    },
                ]),
            }),
        };
        assert_eq!(store.finish_trace_span(span, &ending).unwrap(), Some(id));
        assert_eq!(store.finish_trace_span(span, &ending).unwrap(), None);
        store.close_workflow(id, 110).unwrap();
        drop(store);
        let store = Store::open(&path).unwrap();
        let page = store.workflow_trace(id, None, 10).unwrap();
        assert_eq!(page.summary.span_count, 1);
        assert_eq!(page.summary.agent_count, 0);
        assert_eq!(page.spans[0].ended_at, Some(100));
        assert_eq!(page.spans[0].status, TraceSpanStatus::Exited);
        let events = store.trace_events(span, None, 10).unwrap().events;
        assert_eq!(events.len(), 2);
        assert_eq!(events[1].anchor, ending.anchor);
        assert_eq!(events[1].timestamp, 100);
        assert!(store.workflows(Path::new("/folder")).unwrap().is_empty());
    }

    #[test]
    fn pages_have_stable_cursors_and_do_not_cross_workflows() {
        let mut store = Store::open_in_memory().unwrap();
        let id = workflow(&mut store);
        let first = start(&mut store, id, 1);
        let second = start(&mut store, id, 2);
        let other = workflow(&mut store);
        start(&mut store, other, 3);
        let page = store.workflow_trace(id, None, 1).unwrap();
        assert_eq!(page.spans[0].span_id, second);
        assert_eq!(page.next_before, Some(second));
        let older = store.workflow_trace(id, page.next_before, 1).unwrap();
        assert_eq!(older.spans[0].span_id, first);
        assert_eq!(older.next_before, None);
        store
            .finish_trace_span(
                first,
                &TraceEnding {
                    observed_at: 120,
                    status: TraceSpanStatus::Stopped,
                    kind: TraceEventKind::ProcessStopped,
                    message: "Stopped by the user.",
                    anchor: None,
                },
            )
            .unwrap();
        let events = store.trace_events(first, None, 1).unwrap();
        assert!(events.next_after.is_some());
        let rest = store.trace_events(first, events.next_after, 1).unwrap();
        assert!(rest.events[0].anchor.is_none());
        assert_eq!(rest.next_after, None);
        assert!(matches!(
            store.workflow_trace(id, None, 0),
            Err(TraceError::InvalidLimit)
        ));
        assert!(matches!(
            store.workflow_trace(WorkflowId(999), None, 1),
            Err(TraceError::WorkflowNotFound)
        ));
        assert!(matches!(
            store.trace_events(TraceSpanId(999), None, 1),
            Err(TraceError::SpanNotFound)
        ));
    }

    #[test]
    fn lanes_support_multiple_agents_and_session_deletion_cascades() {
        let mut store = Store::open_in_memory().unwrap();
        let id = workflow(&mut store);
        for (key, name, role) in [
            ("agent-1", "Implementer", "implementer"),
            ("agent-2", "Reviewer", "reviewer"),
        ] {
            store
                .start_trace_span(&NewTraceSpan {
                    workflow_id: id,
                    lane_key: key,
                    lane_name: name,
                    is_agent: true,
                    role: Some(role),
                    harness: Some("codex"),
                    title: "Work",
                    started_at: 100,
                    anchor: None,
                })
                .unwrap();
        }
        let page = store.workflow_trace(id, None, 10).unwrap();
        assert_eq!(page.summary.agent_count, 2);
        assert_eq!(page.lanes.len(), 2);
        let session = store.sessions(Path::new("/folder")).unwrap()[0].session_id;
        store
            .delete_session(Path::new("/folder"), session, None)
            .unwrap();
        assert!(matches!(
            store.workflow_trace(id, None, 10),
            Err(TraceError::WorkflowNotFound)
        ));
        assert_eq!(
            store
                .connection
                .query_row("SELECT COUNT(*) FROM trace_events", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }
}
