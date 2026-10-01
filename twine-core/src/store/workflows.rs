use std::collections::HashMap;
use std::path::Path;

use rusqlite::{OptionalExtension, params};

use super::{Store, StoreError, sql_integer, unsigned_column};
use crate::harness::HarnessId;
use crate::workflow::{
    AgentId, Session, SessionId, SessionStatus, WorkflowId, WorkflowKind, WorkflowStatus,
};

pub(crate) struct StoredWorkflow {
    pub workflow_id: WorkflowId,
    pub session_id: SessionId,
    pub name: String,
    pub kind: WorkflowKind,
    pub harness: Option<HarnessId>,
    /// How a single agent last ended, or that it was still running.
    pub agent_status: Option<WorkflowStatus>,
    /// In role order.
    pub agents: Vec<StoredAgent>,
    pub run: Option<Box<crate::WorkflowRun>>,
}

pub(crate) struct StoredAgent {
    pub agent_id: AgentId,
    pub role: String,
}

impl Store {
    pub(crate) fn sessions_initialized(&self, folder: &Path) -> Result<bool, StoreError> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM folder_selection WHERE folder = ?1)",
            [folder.to_string_lossy().as_ref()],
            |row| row.get(0),
        )?)
    }
    pub(crate) fn sessions(&self, folder: &Path) -> Result<Vec<Session>, StoreError> {
        let mut statement = self
            .connection
            .prepare("SELECT id, name, started_at FROM sessions WHERE folder = ?1 ORDER BY id")?;
        Ok(statement
            .query_map([folder.to_string_lossy().as_ref()], |row| {
                Ok(Session {
                    session_id: SessionId(unsigned_column(row, 0)?),
                    name: row.get(1)?,
                    folder: folder.to_owned(),
                    status: SessionStatus::Active,
                    started_at: unsigned_column(row, 2)?,
                    ended_at: None,
                })
            })?
            .collect::<Result<_, _>>()?)
    }

    pub(crate) fn selected_session(&self, folder: &Path) -> Result<Option<SessionId>, StoreError> {
        self.connection
            .query_row(
                "SELECT session_id FROM folder_selection WHERE folder = ?1",
                [folder.to_string_lossy().as_ref()],
                |row| row.get::<_, Option<i64>>(0),
            )
            .optional()?
            .flatten()
            .map(|id| {
                u64::try_from(id)
                    .map(SessionId)
                    .map_err(|_| StoreError::InvalidIdentifier)
            })
            .transpose()
    }

    pub(crate) fn create_session(
        &mut self,
        folder: &Path,
        name: &str,
        started_at: u64,
    ) -> Result<SessionId, StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT INTO sessions (folder, name, started_at) VALUES (?1, ?2, ?3)",
            params![folder.to_string_lossy(), name, sql_integer(started_at)?],
        )?;
        let id = transaction.last_insert_rowid();
        transaction.execute(
            "INSERT INTO folder_selection (folder, session_id) VALUES (?1, ?2)
             ON CONFLICT(folder) DO UPDATE SET session_id = excluded.session_id",
            params![folder.to_string_lossy(), id],
        )?;
        transaction.commit()?;
        Ok(SessionId(
            u64::try_from(id).map_err(|_| StoreError::InvalidIdentifier)?,
        ))
    }

    pub(crate) fn rename_session(&self, id: SessionId, name: &str) -> Result<(), StoreError> {
        self.connection.execute(
            "UPDATE sessions SET name = ?2 WHERE id = ?1",
            params![sql_integer(id.0)?, name],
        )?;
        Ok(())
    }

    pub(crate) fn select_session(
        &self,
        folder: &Path,
        id: Option<SessionId>,
    ) -> Result<(), StoreError> {
        self.connection.execute(
            "INSERT INTO folder_selection (folder, session_id) VALUES (?1, ?2)
             ON CONFLICT(folder) DO UPDATE SET session_id = excluded.session_id",
            params![
                folder.to_string_lossy(),
                id.map(|id| sql_integer(id.0)).transpose()?
            ],
        )?;
        Ok(())
    }

    pub(crate) fn delete_session(
        &mut self,
        folder: &Path,
        id: SessionId,
        next: Option<SessionId>,
    ) -> Result<(), StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute("DELETE FROM sessions WHERE id = ?1", [sql_integer(id.0)?])?;
        transaction.execute(
            "UPDATE folder_selection SET session_id = ?2 WHERE folder = ?1",
            params![
                folder.to_string_lossy(),
                next.map(|id| sql_integer(id.0)).transpose()?
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub(crate) fn workflows(&self, folder: &Path) -> Result<Vec<StoredWorkflow>, StoreError> {
        let folder = folder.to_string_lossy();
        let mut agents = HashMap::<WorkflowId, Vec<StoredAgent>>::new();
        let mut statement = self.connection.prepare(
            "SELECT a.id, a.workflow_id, a.role FROM agents a
             JOIN workflows w ON w.id = a.workflow_id JOIN sessions s ON s.id = w.session_id
             WHERE s.folder = ?1 AND w.closed_at IS NULL ORDER BY a.id",
        )?;
        for agent in statement.query_map([folder.as_ref()], |row| {
            Ok((
                WorkflowId(unsigned_column(row, 1)?),
                StoredAgent {
                    agent_id: AgentId(unsigned_column(row, 0)?),
                    role: row.get(2)?,
                },
            ))
        })? {
            let (workflow_id, agent) = agent?;
            agents.entry(workflow_id).or_default().push(agent);
        }
        let mut statement = self.connection.prepare(
            "SELECT w.id, w.session_id, w.name, w.kind, w.harness_id, w.lifecycle_status, r.state FROM workflows w
             LEFT JOIN workflow_runs r ON r.workflow_id = w.id
             JOIN sessions s ON s.id = w.session_id WHERE s.folder = ?1 AND w.closed_at IS NULL ORDER BY w.id",
        )?;
        Ok(statement
            .query_map([folder.as_ref()], |row| {
                let workflow_id = WorkflowId(unsigned_column(row, 0)?);
                let kind: String = row.get(3)?;
                let harness: Option<String> = row.get(4)?;
                let agent_status: Option<String> = row.get(5)?;
                Ok(StoredWorkflow {
                    workflow_id,
                    session_id: SessionId(unsigned_column(row, 1)?),
                    name: row.get(2)?,
                    kind: match kind.as_str() {
                        "draft" => WorkflowKind::Draft,
                        "terminal" => WorkflowKind::Terminal,
                        "single_agent" => WorkflowKind::SingleAgent,
                        "agents" => WorkflowKind::Agents,
                        _ => {
                            return Err(rusqlite::Error::FromSqlConversionFailure(
                                3,
                                rusqlite::types::Type::Text,
                                format!("unknown workflow kind {kind:?}").into(),
                            ));
                        }
                    },
                    harness: harness.as_deref().and_then(harness_from_name),
                    agent_status: agent_status.as_deref().and_then(status_from_name),
                    agents: agents.remove(&workflow_id).unwrap_or_default(),
                    run: row
                        .get::<_, Option<String>>(6)?
                        .map(|value| {
                            crate::WorkflowRun::from_stored_json(&value)
                                .map(Box::new)
                                .map_err(|error| {
                                    rusqlite::Error::FromSqlConversionFailure(
                                        6,
                                        rusqlite::types::Type::Text,
                                        Box::new(error),
                                    )
                                })
                        })
                        .transpose()?,
                })
            })?
            .collect::<Result<_, _>>()?)
    }

    /// Creates a workflow and one agent per role, in role order.
    pub(crate) fn create_workflow(
        &mut self,
        session: SessionId,
        name: &str,
        kind: WorkflowKind,
        roles: &[&str],
    ) -> Result<(WorkflowId, Vec<AgentId>), StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT INTO workflows (session_id, name, kind) VALUES (?1, ?2, ?3)",
            params![sql_integer(session.0)?, name, kind_name(kind)],
        )?;
        let workflow_id = transaction.last_insert_rowid();
        let mut agent_ids = Vec::with_capacity(roles.len());
        for role in roles {
            transaction.execute(
                "INSERT INTO agents (workflow_id, role) VALUES (?1, ?2)",
                params![workflow_id, role],
            )?;
            agent_ids.push(AgentId(
                u64::try_from(transaction.last_insert_rowid())
                    .map_err(|_| StoreError::InvalidIdentifier)?,
            ));
        }
        transaction.commit()?;
        Ok((
            WorkflowId(u64::try_from(workflow_id).map_err(|_| StoreError::InvalidIdentifier)?),
            agent_ids,
        ))
    }

    pub(crate) fn update_workflow(
        &self,
        id: WorkflowId,
        name: &str,
        kind: WorkflowKind,
        harness: Option<HarnessId>,
    ) -> Result<(), StoreError> {
        self.connection.execute(
            "UPDATE workflows SET name = ?2, kind = ?3, harness_id = ?4 WHERE id = ?1",
            params![
                sql_integer(id.0)?,
                name,
                kind_name(kind),
                harness.map(harness_name)
            ],
        )?;
        Ok(())
    }

    /// Records how a single agent ended, so the outcome survives a restart.
    pub(crate) fn update_agent_status(
        &self,
        id: WorkflowId,
        status: WorkflowStatus,
    ) -> Result<(), StoreError> {
        self.connection.execute(
            "UPDATE workflows SET lifecycle_status = ?2 WHERE id = ?1",
            params![sql_integer(id.0)?, status_name(status)],
        )?;
        Ok(())
    }

    pub(crate) fn close_workflow(&self, id: WorkflowId, closed_at: u64) -> Result<(), StoreError> {
        self.connection.execute(
            "UPDATE workflows SET closed_at = ?2 WHERE id = ?1",
            params![sql_integer(id.0)?, sql_integer(closed_at)?],
        )?;
        Ok(())
    }

    pub(crate) fn start_workflow_run(
        &mut self,
        id: WorkflowId,
        run: &mut crate::WorkflowRun,
    ) -> Result<(), StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "UPDATE workflows SET kind = 'agents', name = ?2 WHERE id = ?1",
            params![sql_integer(id.0)?, run.workflow_type.definition.name],
        )?;
        for agent in &mut run.agents {
            transaction.execute(
                "INSERT INTO agents (workflow_id, role) VALUES (?1, ?2)",
                params![sql_integer(id.0)?, agent.label],
            )?;
            agent.agent_id = u64::try_from(transaction.last_insert_rowid())
                .map_err(|_| StoreError::InvalidIdentifier)?;
        }
        transaction.execute(
            "INSERT INTO workflow_runs (workflow_id, state) VALUES (?1, ?2)",
            params![sql_integer(id.0)?, serde_json::to_string(run)?],
        )?;
        transaction.commit()?;
        Ok(())
    }
}

fn kind_name(kind: WorkflowKind) -> &'static str {
    match kind {
        WorkflowKind::Draft => "draft",
        WorkflowKind::Terminal => "terminal",
        WorkflowKind::SingleAgent => "single_agent",
        WorkflowKind::Agents => "agents",
    }
}

fn status_name(status: WorkflowStatus) -> Option<&'static str> {
    match status {
        WorkflowStatus::Running => Some("running"),
        WorkflowStatus::Exited => Some("exited"),
        WorkflowStatus::Failed => Some("failed"),
        WorkflowStatus::Cancelled => Some("cancelled"),
        WorkflowStatus::Interrupted => Some("interrupted"),
        WorkflowStatus::Closed | WorkflowStatus::Completed => None,
    }
}

fn status_from_name(name: &str) -> Option<WorkflowStatus> {
    match name {
        "running" => Some(WorkflowStatus::Running),
        "exited" => Some(WorkflowStatus::Exited),
        "failed" => Some(WorkflowStatus::Failed),
        "cancelled" => Some(WorkflowStatus::Cancelled),
        "interrupted" => Some(WorkflowStatus::Interrupted),
        _ => None,
    }
}

pub(super) fn harness_name(harness: HarnessId) -> &'static str {
    match harness {
        HarnessId::Codex => "codex",
        HarnessId::ClaudeCode => "claude_code",
        HarnessId::Pi => "pi",
        HarnessId::Antigravity => "antigravity",
        HarnessId::Omp => "omp",
        HarnessId::Opencode => "opencode",
    }
}

fn harness_from_name(name: &str) -> Option<HarnessId> {
    match name {
        "codex" => Some(HarnessId::Codex),
        "claude_code" => Some(HarnessId::ClaudeCode),
        "pi" => Some(HarnessId::Pi),
        "antigravity" => Some(HarnessId::Antigravity),
        "omp" => Some(HarnessId::Omp),
        "opencode" => Some(HarnessId::Opencode),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_harness_workflows_keep_their_harness_after_reopening_the_store() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("store.sqlite");
        let folder = Path::new("/folder");
        {
            let mut store = Store::open(&database).unwrap();
            let session = store.create_session(folder, "Session", 1).unwrap();
            for harness in [HarnessId::Antigravity, HarnessId::Omp, HarnessId::Opencode] {
                let (id, _) = store
                    .create_workflow(session, "New workflow", WorkflowKind::Draft, &[])
                    .unwrap();
                store
                    .update_workflow(
                        id,
                        harness.definition().name,
                        WorkflowKind::SingleAgent,
                        Some(harness),
                    )
                    .unwrap();
                store
                    .update_agent_status(id, WorkflowStatus::Cancelled)
                    .unwrap();
            }
        }
        let reopened = Store::open(&database).unwrap();
        let workflows = reopened.workflows(folder).unwrap();
        assert_eq!(workflows.len(), 3);
        for (workflow, harness) in
            workflows
                .iter()
                .zip([HarnessId::Antigravity, HarnessId::Omp, HarnessId::Opencode])
        {
            assert_eq!(workflow.harness, Some(harness));
            assert_eq!(workflow.agent_status, Some(WorkflowStatus::Cancelled));
        }
    }

    #[test]
    fn an_agent_that_cant_be_stored_rolls_back_its_whole_workflow() {
        let mut store = Store::open_in_memory().unwrap();
        let folder = Path::new("/folder");
        let session = store.create_session(folder, "Session", 1).unwrap();
        store
            .connection
            .execute_batch(
                "CREATE TRIGGER reject_reviewer BEFORE INSERT ON agents WHEN NEW.role = 'Reviewer'
                 BEGIN SELECT RAISE(ABORT, 'rejected'); END",
            )
            .unwrap();
        assert!(
            store
                .create_workflow(
                    session,
                    "Agents",
                    WorkflowKind::Agents,
                    &["Implementer", "Reviewer"]
                )
                .is_err()
        );
        assert!(store.workflows(folder).unwrap().is_empty());
        let agents: i64 = store
            .connection
            .query_row("SELECT COUNT(*) FROM agents", [], |row| row.get(0))
            .unwrap();
        assert_eq!(agents, 0);
    }

    #[test]
    fn a_workflow_of_an_unknown_kind_fails_the_load_instead_of_becoming_a_terminal() {
        let mut store = Store::open_in_memory().unwrap();
        let folder = Path::new("/folder");
        let session = store.create_session(folder, "Session", 1).unwrap();
        store
            .connection
            .execute_batch(&format!(
                "PRAGMA ignore_check_constraints = ON;
                 INSERT INTO workflows (session_id, name, kind) VALUES ({}, 'Future', 'future');
                 PRAGMA ignore_check_constraints = OFF;",
                session.0
            ))
            .unwrap();
        assert!(store.workflows(folder).is_err());
    }
}
