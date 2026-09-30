#![cfg_attr(
    not(test),
    expect(
        dead_code,
        reason = "commands for the workflow type catalog arrive with its UI"
    )
)]

use rusqlite::{OptionalExtension, TransactionBehavior, params};

use super::{Store, StoreError, sql_integer, unsigned_column};

/// One version of a user-made workflow type, with its definition as serialized text.
pub(crate) struct StoredWorkflowType {
    pub type_id: u64,
    pub version: u32,
    pub definition: String,
}

impl Store {
    /// Adds a workflow type with `definition` as its first version and returns the type's ID.
    pub(crate) fn create_workflow_type(
        &mut self,
        definition: &str,
        created_at: u64,
    ) -> Result<u64, StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute("INSERT INTO workflow_types DEFAULT VALUES", [])?;
        let type_id = transaction.last_insert_rowid();
        transaction.execute(
            "INSERT INTO workflow_type_versions (type_id, version, definition, created_at)
             VALUES (?1, 1, ?2, ?3)",
            params![type_id, definition, sql_integer(created_at)?],
        )?;
        transaction.commit()?;
        u64::try_from(type_id).map_err(|_| StoreError::InvalidIdentifier)
    }

    /// Adds the next version of a workflow type and returns its number, or `None` if the type
    /// doesn't exist.
    pub(crate) fn add_workflow_type_version(
        &mut self,
        type_id: u64,
        definition: &str,
        created_at: u64,
    ) -> Result<Option<u32>, StoreError> {
        // Take the write lock before reading the latest version, so another Twine process can't
        // add the same version in between.
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let latest: Option<i64> = transaction.query_row(
            "SELECT MAX(version) FROM workflow_type_versions WHERE type_id = ?1",
            [sql_integer(type_id)?],
            |row| row.get(0),
        )?;
        let Some(latest) = latest else {
            return Ok(None);
        };
        let version = latest + 1;
        transaction.execute(
            "INSERT INTO workflow_type_versions (type_id, version, definition, created_at)
             VALUES (?1, ?2, ?3, ?4)",
            params![
                sql_integer(type_id)?,
                version,
                definition,
                sql_integer(created_at)?
            ],
        )?;
        transaction.commit()?;
        Ok(Some(
            u32::try_from(version).map_err(|_| StoreError::InvalidIdentifier)?,
        ))
    }

    pub(crate) fn workflow_type_version(
        &self,
        type_id: u64,
        version: u32,
    ) -> Result<Option<String>, StoreError> {
        Ok(self
            .connection
            .query_row(
                "SELECT definition FROM workflow_type_versions
                 WHERE type_id = ?1 AND version = ?2",
                params![sql_integer(type_id)?, version],
                |row| row.get(0),
            )
            .optional()?)
    }

    /// Returns the latest version of every workflow type, oldest type first.
    pub(crate) fn latest_workflow_types(&self) -> Result<Vec<StoredWorkflowType>, StoreError> {
        let mut statement = self.connection.prepare(
            "SELECT v.type_id, v.version, v.definition FROM workflow_type_versions v
             WHERE v.version =
                 (SELECT MAX(version) FROM workflow_type_versions WHERE type_id = v.type_id)
             ORDER BY v.type_id",
        )?;
        Ok(statement
            .query_map([], stored_workflow_type)?
            .collect::<Result<_, _>>()?)
    }
}

fn stored_workflow_type(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredWorkflowType> {
    let version: i64 = row.get(1)?;
    Ok(StoredWorkflowType {
        type_id: unsigned_column(row, 0)?,
        version: u32::try_from(version)
            .map_err(|_| rusqlite::Error::IntegralValueOutOfRange(1, version))?,
        definition: row.get(2)?,
    })
}
