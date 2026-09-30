use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, TransactionBehavior, params};
use thiserror::Error;
use tracing::info;

mod workflow_types;
mod workflows;

pub(crate) use workflow_types::StoredWorkflowType;

/// Schema migrations in the order they apply. `PRAGMA user_version` counts the ones already applied,
/// so append new migrations and never change or reorder one that has shipped.
const MIGRATIONS: &[&str] = &[
    // 1: Recent folders, and the folder that was open when Twine last quit.
    "CREATE TABLE recent_folders (
        path TEXT PRIMARY KEY NOT NULL,
        last_opened_at INTEGER NOT NULL,
        is_open INTEGER NOT NULL DEFAULT 0 CHECK (is_open IN (0, 1))
    ) STRICT",
    // 2: Sessions and workflow tabs outlive terminal processes and the recent-folder list.
    "CREATE TABLE sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        folder TEXT NOT NULL,
        name TEXT NOT NULL,
        started_at INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX sessions_folder ON sessions(folder);
    CREATE TABLE workflows (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('draft', 'terminal'))
    ) STRICT;
    CREATE INDEX workflows_session ON workflows(session_id);
    CREATE TABLE folder_selection (
        folder TEXT PRIMARY KEY NOT NULL,
        session_id INTEGER REFERENCES sessions(id) ON DELETE SET NULL
    ) STRICT",
    // 3: User-made workflow types. Versions are only ever added, so running workflows keep theirs.
    "CREATE TABLE workflow_types (
        id INTEGER PRIMARY KEY AUTOINCREMENT
    ) STRICT;
    CREATE TABLE workflow_type_versions (
        type_id INTEGER NOT NULL REFERENCES workflow_types(id) ON DELETE CASCADE,
        version INTEGER NOT NULL CHECK (version > 0),
        definition TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (type_id, version)
    ) STRICT",
];

/// How long a write waits for another connection, such as a second Twine process, to release the
/// database.
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

/// A recent folder as stored, without the file system checks the folder module adds.
#[derive(Debug, Eq, PartialEq)]
pub(crate) struct StoredFolder {
    pub(crate) path: PathBuf,
    /// Whether the folder was open when Twine last quit.
    pub(crate) is_open: bool,
}

/// The SQLite database that holds Twine's persistent state.
#[derive(Debug)]
pub(crate) struct Store {
    connection: Connection,
}

impl Store {
    /// Opens the database at `path`, creating the file and its directory if needed, and applies
    /// pending migrations.
    pub(crate) fn open(path: &Path) -> Result<Self, StoreError> {
        if let Some(directory) = path.parent() {
            std::fs::create_dir_all(directory).map_err(|source| StoreError::CreateDirectory {
                path: directory.to_owned(),
                source,
            })?;
        }
        let connection = Connection::open(path).map_err(|source| StoreError::Open {
            path: path.to_owned(),
            source,
        })?;
        Self::with_connection(connection)
    }

    #[cfg(test)]
    pub(crate) fn open_in_memory() -> Result<Self, StoreError> {
        Self::with_connection(Connection::open_in_memory()?)
    }

    fn with_connection(mut connection: Connection) -> Result<Self, StoreError> {
        connection.busy_timeout(BUSY_TIMEOUT)?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "foreign_keys", true)?;
        migrate(&mut connection)?;
        Ok(Self { connection })
    }

    /// Returns the recent folders, most recently opened first.
    pub(crate) fn recent_folders(&self) -> Result<Vec<StoredFolder>, StoreError> {
        query_recent_folders(&self.connection)
    }

    /// Records `path` as the open folder and the most recently opened one, then forgets all but the
    /// `limit` most recent folders. Returns the recent folders after the change.
    ///
    /// The recorded time is at least one millisecond after every stored time, so the new folder
    /// sorts first even if the clock went backward or two folders open in the same millisecond.
    pub(crate) fn record_folder_opened(
        &mut self,
        path: &str,
        opened_at_millis: i64,
        limit: i64,
    ) -> Result<Vec<StoredFolder>, StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "UPDATE recent_folders SET is_open = 0 WHERE is_open = 1",
            [],
        )?;
        transaction.execute(
            "INSERT INTO recent_folders (path, last_opened_at, is_open)
             VALUES (?1, MAX(?2, (SELECT COALESCE(MAX(last_opened_at), 0) + 1 FROM recent_folders)), 1)
             ON CONFLICT (path) DO UPDATE
             SET last_opened_at = excluded.last_opened_at, is_open = 1",
            params![path, opened_at_millis],
        )?;
        transaction.execute(
            "DELETE FROM recent_folders WHERE path NOT IN
             (SELECT path FROM recent_folders ORDER BY last_opened_at DESC LIMIT ?1)",
            [limit],
        )?;
        let folders = query_recent_folders(&transaction)?;
        transaction.commit()?;
        Ok(folders)
    }

    /// Records that no folder is open, so the next launch shows the start page. Returns the recent
    /// folders after the change.
    pub(crate) fn record_folder_closed(&mut self) -> Result<Vec<StoredFolder>, StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "UPDATE recent_folders SET is_open = 0 WHERE is_open = 1",
            [],
        )?;
        let folders = query_recent_folders(&transaction)?;
        transaction.commit()?;
        Ok(folders)
    }

    /// Forgets the recent folder at `path`. Returns the recent folders after the change.
    pub(crate) fn remove_recent_folder(
        &mut self,
        path: &str,
    ) -> Result<Vec<StoredFolder>, StoreError> {
        let transaction = self.connection.transaction()?;
        transaction.execute("DELETE FROM recent_folders WHERE path = ?1", [path])?;
        let folders = query_recent_folders(&transaction)?;
        transaction.commit()?;
        Ok(folders)
    }
}

fn query_recent_folders(connection: &Connection) -> Result<Vec<StoredFolder>, StoreError> {
    let mut statement = connection
        .prepare("SELECT path, is_open FROM recent_folders ORDER BY last_opened_at DESC")?;
    let folders = statement
        .query_map([], |row| {
            Ok(StoredFolder {
                path: PathBuf::from(row.get::<_, String>(0)?),
                is_open: row.get(1)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(folders)
}

/// Applies pending migrations in one transaction that takes the write lock before reading the
/// schema version, so a second Twine process opening the database waits instead of migrating it
/// again.
fn migrate(connection: &mut Connection) -> Result<(), StoreError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let version: i64 = transaction.pragma_query_value(None, "user_version", |row| row.get(0))?;
    let applied = usize::try_from(version)
        .ok()
        .filter(|applied| *applied <= MIGRATIONS.len())
        .ok_or(StoreError::UnsupportedSchemaVersion { version })?;

    for (version, migration) in (1_i64..).zip(MIGRATIONS).skip(applied) {
        transaction
            .execute_batch(migration)
            .map_err(|source| StoreError::Migrate { version, source })?;
        transaction.pragma_update(None, "user_version", version)?;
        info!(version, "applied database migration");
    }
    transaction.commit()?;
    Ok(())
}

fn sql_integer(value: u64) -> Result<i64, StoreError> {
    i64::try_from(value).map_err(|_| StoreError::InvalidIdentifier)
}

fn unsigned_column(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<u64> {
    let value: i64 = row.get(index)?;
    u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(index, value))
}

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("database returned an invalid identifier")]
    InvalidIdentifier,
    #[error("failed to create the data directory {}", path.display())]
    CreateDirectory {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to apply database migration {version}")]
    Migrate {
        version: i64,
        #[source]
        source: rusqlite::Error,
    },
    #[error("failed to open the database {}", path.display())]
    Open {
        path: PathBuf,
        #[source]
        source: rusqlite::Error,
    },
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error("database schema version {version} is not one this version of Twine supports")]
    UnsupportedSchemaVersion { version: i64 },
}

#[cfg(test)]
mod tests {
    use super::*;

    fn schema_version(connection: &Connection) -> i64 {
        connection
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .expect("the schema version should be readable")
    }

    #[test]
    fn open_creates_the_directory_and_migrates_once() {
        let directory = tempfile::tempdir().expect("a temporary directory should be available");
        let path = directory.path().join("nested").join("twine.db");

        let store = Store::open(&path).expect("the store should open");
        assert_eq!(
            schema_version(&store.connection),
            i64::try_from(MIGRATIONS.len()).expect("the migration count fits in i64")
        );
        drop(store);

        let reopened = Store::open(&path).expect("the migrated store should reopen");
        assert_eq!(
            schema_version(&reopened.connection),
            i64::try_from(MIGRATIONS.len()).expect("the migration count fits in i64")
        );
    }

    #[test]
    fn migration_from_version_one_preserves_folders_and_adds_session_storage() {
        let mut connection = Connection::open_in_memory().unwrap();
        connection.execute_batch(MIGRATIONS[0]).unwrap();
        connection
            .execute("INSERT INTO recent_folders VALUES ('/folder', 1, 1)", [])
            .unwrap();
        connection.pragma_update(None, "user_version", 1).unwrap();
        migrate(&mut connection).unwrap();
        let mut store = Store::with_connection(connection).unwrap();
        assert_eq!(
            store.recent_folders().unwrap(),
            [StoredFolder {
                path: "/folder".into(),
                is_open: true
            }]
        );
        let id = store
            .create_session(Path::new("/folder"), "Session", 123)
            .unwrap();
        store
            .create_workflow(id, "Terminal", crate::WorkflowKind::Terminal)
            .unwrap();
        assert_eq!(
            store.selected_session(Path::new("/folder")).unwrap(),
            Some(id)
        );
        assert_eq!(store.workflows(Path::new("/folder")).unwrap().len(), 1);
    }

    #[test]
    fn migration_from_version_two_preserves_sessions_and_adds_workflow_types() {
        let mut connection = Connection::open_in_memory().unwrap();
        connection.execute_batch(MIGRATIONS[0]).unwrap();
        connection.execute_batch(MIGRATIONS[1]).unwrap();
        connection
            .execute(
                "INSERT INTO sessions (folder, name, started_at) VALUES ('/folder', 'Kept', 1)",
                [],
            )
            .unwrap();
        connection.pragma_update(None, "user_version", 2).unwrap();
        migrate(&mut connection).unwrap();
        let mut store = Store::with_connection(connection).unwrap();
        assert_eq!(
            store.sessions(Path::new("/folder")).unwrap()[0].name,
            "Kept"
        );
        let type_id = store.create_workflow_type("definition", 1).unwrap();
        assert_eq!(
            store
                .add_workflow_type_version(type_id, "edited", 2)
                .unwrap(),
            Some(2)
        );
        assert_eq!(
            store
                .add_workflow_type_version(type_id + 1, "missing", 3)
                .unwrap(),
            None
        );
    }

    #[test]
    fn a_newer_schema_is_rejected() {
        let directory = tempfile::tempdir().expect("a temporary directory should be available");
        let path = directory.path().join("twine.db");
        let connection = Connection::open(&path).expect("the database should open");
        connection
            .pragma_update(None, "user_version", 99)
            .expect("the schema version should be writable");
        drop(connection);

        assert!(matches!(
            Store::open(&path),
            Err(StoreError::UnsupportedSchemaVersion { version: 99 })
        ));
    }

    #[test]
    fn recent_folders_are_ordered_capped_and_track_the_open_folder() {
        let mut store = Store::open_in_memory().expect("the store should open");
        store
            .record_folder_opened("/a", 5_000, 2)
            .expect("a should be recorded");
        // An earlier clock reading still sorts after the folder opened before it.
        store
            .record_folder_opened("/b", 1_000, 2)
            .expect("b should be recorded");
        store
            .record_folder_opened("/c", 1_000, 2)
            .expect("c should be recorded");

        assert_eq!(
            store.recent_folders().expect("folders should load"),
            [
                StoredFolder {
                    path: PathBuf::from("/c"),
                    is_open: true,
                },
                StoredFolder {
                    path: PathBuf::from("/b"),
                    is_open: false,
                },
            ]
        );

        store
            .record_folder_opened("/b", 1_000, 2)
            .expect("b should be recorded again");
        store
            .record_folder_closed()
            .expect("closing should be recorded");
        let remaining = store
            .remove_recent_folder("/c")
            .expect("c should be removed");
        assert_eq!(
            remaining,
            [StoredFolder {
                path: PathBuf::from("/b"),
                is_open: false,
            }]
        );
        assert_eq!(
            store.recent_folders().expect("folders should load"),
            remaining
        );
    }
}
