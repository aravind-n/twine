use std::path::Path;

use rusqlite::{OptionalExtension, params};

use super::{Store, StoreError};
use crate::workflow::{Session, SessionId, SessionStatus, WorkflowId, WorkflowKind};

pub(crate) struct StoredWorkflow {
    pub workflow_id: WorkflowId,
    pub session_id: SessionId,
    pub name: String,
    pub kind: WorkflowKind,
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
        let mut statement = self.connection.prepare(
            "SELECT w.id, w.session_id, w.name, w.kind FROM workflows w
             JOIN sessions s ON s.id = w.session_id WHERE s.folder = ?1 ORDER BY w.id",
        )?;
        Ok(statement
            .query_map([folder.to_string_lossy().as_ref()], |row| {
                let kind: String = row.get(3)?;
                Ok(StoredWorkflow {
                    workflow_id: WorkflowId(unsigned_column(row, 0)?),
                    session_id: SessionId(unsigned_column(row, 1)?),
                    name: row.get(2)?,
                    kind: if kind == "draft" {
                        WorkflowKind::Draft
                    } else {
                        WorkflowKind::Terminal
                    },
                })
            })?
            .collect::<Result<_, _>>()?)
    }

    pub(crate) fn create_workflow(
        &self,
        session: SessionId,
        name: &str,
        kind: WorkflowKind,
    ) -> Result<WorkflowId, StoreError> {
        self.connection.execute(
            "INSERT INTO workflows (session_id, name, kind) VALUES (?1, ?2, ?3)",
            params![sql_integer(session.0)?, name, kind_name(kind)],
        )?;
        Ok(WorkflowId(
            u64::try_from(self.connection.last_insert_rowid())
                .map_err(|_| StoreError::InvalidIdentifier)?,
        ))
    }

    pub(crate) fn update_workflow(
        &self,
        id: WorkflowId,
        name: &str,
        kind: WorkflowKind,
    ) -> Result<(), StoreError> {
        self.connection.execute(
            "UPDATE workflows SET name = ?2, kind = ?3 WHERE id = ?1",
            params![sql_integer(id.0)?, name, kind_name(kind)],
        )?;
        Ok(())
    }

    pub(crate) fn delete_workflow(&self, id: WorkflowId) -> Result<(), StoreError> {
        self.connection
            .execute("DELETE FROM workflows WHERE id = ?1", [sql_integer(id.0)?])?;
        Ok(())
    }
}

fn kind_name(kind: WorkflowKind) -> &'static str {
    match kind {
        WorkflowKind::Draft => "draft",
        WorkflowKind::Terminal => "terminal",
    }
}

fn sql_integer(value: u64) -> Result<i64, StoreError> {
    i64::try_from(value).map_err(|_| StoreError::InvalidIdentifier)
}

fn unsigned_column(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<u64> {
    let value: i64 = row.get(index)?;
    u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(index, value))
}
