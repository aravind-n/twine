use rusqlite::{OptionalExtension, params};

use super::{Store, StoreError, sql_integer};
use crate::TerminalId;

impl Store {
    pub(crate) fn remember_harness_session(
        &self,
        terminal: TerminalId,
        session: &str,
    ) -> Result<(), StoreError> {
        self.connection.execute(
            "UPDATE workflow_terminals SET harness_session = ?2 WHERE terminal_id = ?1",
            params![sql_integer(terminal.value())?, session],
        )?;
        Ok(())
    }

    pub(crate) fn harness_session(
        &self,
        terminal: TerminalId,
    ) -> Result<Option<String>, StoreError> {
        Ok(self
            .connection
            .query_row(
                "SELECT harness_session FROM workflow_terminals WHERE terminal_id = ?1",
                [sql_integer(terminal.value())?],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten())
    }
}
