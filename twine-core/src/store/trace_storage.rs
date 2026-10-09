//! Retain compact records independently from full detail files. Only Twine-owned files are
//! cleaned; native harness conversations remain untouched.

use std::collections::HashSet;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::params;

use super::{Store, StoreError, sql_integer, unsigned_column};
use crate::{TraceSpanId, TraceStorageStatus};

impl Store {
    pub(crate) fn configure_trace_storage(
        &self,
        config: &crate::config::TraceConfig,
    ) -> Result<(), StoreError> {
        self.connection.execute(
            "UPDATE trace_storage_preferences SET budget_bytes=?1,retention_days=?2 WHERE id=1",
            params![
                i64::from(config.detail_budget_mb) * 1024 * 1024,
                i64::from(config.retention_days)
            ],
        )?;
        Ok(())
    }

    pub(crate) fn storage_status(
        &self,
        span: Option<TraceSpanId>,
    ) -> Result<TraceStorageStatus, StoreError> {
        self.connection.query_row(
            "SELECT payload_bytes,payload_files,budget_bytes,retention_days,updated_at,
              COALESCE((SELECT pinned_details FROM trace_spans WHERE id=?1),0),clear_generation,completed_clear_generation FROM trace_storage_preferences WHERE id=1",
            [span.map(|s|sql_integer(s.0)).transpose()?],|r|Ok(TraceStorageStatus {
                payload_bytes:unsigned_column(r,0)?,payload_files:unsigned_column(r,1)?,budget_bytes:unsigned_column(r,2)?,
                retention_days:r.get(3)?,updated_at:unsigned_column(r,4)?,pinned:r.get(5)?,clear_generation:unsigned_column(r,6)?,completed_clear_generation:unsigned_column(r,7)?,
            })
        ).map_err(StoreError::from)
    }

    pub(crate) fn pin_trace_details(
        &self,
        span: TraceSpanId,
        pinned: bool,
    ) -> Result<bool, StoreError> {
        Ok(self.connection.execute(
            "UPDATE trace_spans SET pinned_details=?2 WHERE id=?1 AND pinned_details!=?2",
            params![sql_integer(span.0)?, pinned],
        )? > 0)
    }

    pub(crate) fn maintenance_request(
        &self,
        clear: bool,
    ) -> Option<crate::harness::history::HistoryRequest> {
        Some(crate::harness::history::HistoryRequest {
            database: self
                .connection
                .path()
                .filter(|p| !p.is_empty())
                .map(std::path::PathBuf::from)?,
            workflow: crate::WorkflowId(0),
            session: if clear {
                format!(
                    "@clear:{}",
                    self.storage_status(None).ok()?.clear_generation
                )
            } else {
                "@maintenance".into()
            },
            harness: crate::HarnessId::Codex,
        })
    }

    pub(crate) fn request_trace_clear(&self) -> Result<(), StoreError> {
        self.connection.execute(
            "UPDATE trace_storage_preferences SET clear_generation=clear_generation+1 WHERE id=1",
            [],
        )?;
        Ok(())
    }

    pub(crate) fn maintain_trace_storage(&mut self, clear: bool) -> Result<(), StoreError> {
        let status = self.storage_status(None)?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let now = u64::try_from(now).map_err(|_| StoreError::InvalidIdentifier)?;
        if status.retention_days > 0 {
            let cutoff = now.saturating_sub(u64::from(status.retention_days) * 86_400_000);
            let transaction = self.connection.transaction()?;
            transaction.execute("DELETE FROM trace_events WHERE workflow_id IN
                (SELECT w.id FROM workflows w WHERE w.closed_at<?1 AND NOT EXISTS
                 (SELECT 1 FROM trace_spans s JOIN trace_lanes l ON l.id=s.lane_id WHERE l.workflow_id=w.id AND s.pinned_details=1))",
                [sql_integer(cutoff)?])?;
            transaction.execute("DELETE FROM trace_lanes WHERE workflow_id IN
                (SELECT w.id FROM workflows w WHERE w.closed_at<?1 AND NOT EXISTS
                 (SELECT 1 FROM trace_spans s JOIN trace_lanes l ON l.id=s.lane_id WHERE l.workflow_id=w.id AND s.pinned_details=1))",
                [sql_integer(cutoff)?])?;
            transaction.commit()?;
        }
        let transaction = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let mut protected = HashSet::new();
        let mut statement = transaction.prepare(
            "SELECT a.input_key,a.output_key FROM trace_activities a
             JOIN trace_spans s ON s.id=a.span_id WHERE a.status='running' OR s.status='running' OR s.pinned_details=1",
        )?;
        for row in statement.query_map([], |r| {
            Ok((
                r.get::<_, Option<String>>(0)?,
                r.get::<_, Option<String>>(1)?,
            ))
        })? {
            let (input, output) = row?;
            protected.extend(input);
            protected.extend(output);
        }
        drop(statement);
        let (bytes, files) = self
            .payloads
            .prune(status.budget_bytes, &protected, clear)?;
        transaction.execute("UPDATE trace_storage_preferences SET payload_bytes=?1,payload_files=?2,updated_at=?3,completed_clear_generation=MAX(completed_clear_generation,?4) WHERE id=1",
            params![sql_integer(bytes)?,sql_integer(files)?,sql_integer(now)?,if clear {sql_integer(status.clear_generation)?} else {0}])?;
        transaction.commit()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleanup_preserves_running_and_pinned_details_and_never_removes_external_history() {
        let mut store = Store::open_in_memory().unwrap();
        let session = store
            .create_session(std::path::Path::new("/fixture"), "Storage", 1)
            .unwrap();
        store
            .create_workflow(session, "Agent", crate::WorkflowKind::Terminal, &[])
            .unwrap();
        let active = store
            .payloads
            .save(&"active".repeat(1000))
            .unwrap()
            .unwrap();
        let pinned = store
            .payloads
            .save(&"pinned".repeat(1000))
            .unwrap()
            .unwrap();
        let expired = store
            .payloads
            .save(&"expired".repeat(1000))
            .unwrap()
            .unwrap();
        store.execute_test_sql("INSERT INTO trace_lanes(id,workflow_id,lane_key,name,is_agent) VALUES(1,1,'agent','Agent',1);
            INSERT INTO trace_spans(id,lane_id,title,started_at,status,pinned_details) VALUES(1,1,'Active',1,'running',0),(2,1,'Pinned',1,'exited',1);");
        store.connection.execute("INSERT INTO trace_activities(span_id,source_id,kind,title,status,input,output,input_key)
            VALUES(1,'active','tool','Active','running','','',?1),(2,'pinned','tool','Pinned','completed','','',?2)",params![active,pinned]).unwrap();
        store.maintain_trace_storage(true).unwrap();
        assert!(store.payloads.read(&active, 0, 16).is_ok());
        assert!(store.payloads.read(&pinned, 0, 16).is_ok());
        assert!(store.payloads.read(&expired, 0, 16).is_err());
        assert_eq!(store.storage_status(None).unwrap().payload_files, 2);
    }
}
