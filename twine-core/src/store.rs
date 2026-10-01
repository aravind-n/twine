use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, TransactionBehavior, params};
use thiserror::Error;
use tracing::info;

mod harness_sessions;
mod harness_steps;
mod recovery;
mod run_traces;
mod traces;
mod workflow_types;
mod workflows;
pub(crate) use traces::{NewTraceSpan, TraceEnding};

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
    // 4: Single-agent workflows record their harness and how the agent last ended.
    "CREATE TABLE workflows_new (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('draft', 'terminal', 'single_agent')),
        harness TEXT CHECK (harness IN ('codex', 'claude_code', 'pi')),
        agent_status TEXT CHECK (agent_status IN ('running', 'exited', 'failed', 'cancelled'))
    ) STRICT;
    INSERT INTO workflows_new (id, session_id, name, kind)
        SELECT id, session_id, name, kind FROM workflows;
    UPDATE sqlite_sequence SET seq = MAX(seq, COALESCE(
        (SELECT seq FROM sqlite_sequence WHERE name = 'workflows'), 0))
        WHERE name = 'workflows_new';
    DROP TABLE workflows;
    ALTER TABLE workflows_new RENAME TO workflows;
    CREATE INDEX workflows_session ON workflows(session_id)",
    // 5: Agents workflows and their agents' roles. SQLite can't change a CHECK constraint, so the
    // workflows table is rebuilt, keeping its IDs and its AUTOINCREMENT high-water mark so closed
    // workflows' IDs are never reused.
    "CREATE TABLE workflows_v5 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('draft', 'terminal', 'single_agent', 'agents')),
        harness TEXT CHECK (harness IN ('codex', 'claude_code', 'pi')),
        agent_status TEXT CHECK (agent_status IN ('running', 'exited', 'failed', 'cancelled'))
    ) STRICT;
    INSERT INTO workflows_v5 (id, session_id, name, kind, harness, agent_status)
        SELECT id, session_id, name, kind, harness, agent_status FROM workflows;
    DELETE FROM sqlite_sequence WHERE name = 'workflows_v5';
    INSERT INTO sqlite_sequence (name, seq)
        SELECT 'workflows_v5', seq FROM sqlite_sequence WHERE name = 'workflows';
    DROP TABLE workflows;
    ALTER TABLE workflows_v5 RENAME TO workflows;
    CREATE INDEX workflows_session ON workflows(session_id);
    CREATE TABLE agents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workflow_id INTEGER NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
        role TEXT NOT NULL
    ) STRICT;
    CREATE INDEX agents_workflow ON agents(workflow_id)",
    // 6: Trace history, including closed tabs.
    "ALTER TABLE workflows ADD COLUMN closed_at INTEGER;
    CREATE TABLE trace_lanes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workflow_id INTEGER NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
        lane_key TEXT NOT NULL,
        name TEXT NOT NULL,
        is_agent INTEGER NOT NULL CHECK (is_agent IN (0, 1)),
        role TEXT,
        harness TEXT,
        UNIQUE (workflow_id, lane_key)
    ) STRICT;
    CREATE TABLE trace_spans (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        lane_id INTEGER NOT NULL REFERENCES trace_lanes(id) ON DELETE CASCADE,
        title TEXT NOT NULL,
        started_at INTEGER NOT NULL CHECK (started_at >= 0),
        ended_at INTEGER CHECK (ended_at >= started_at),
        status TEXT NOT NULL CHECK (status IN ('running', 'exited', 'failed', 'stopped')),
        terminal_id INTEGER
    ) STRICT;
    CREATE INDEX trace_spans_lane ON trace_spans(lane_id, id);
    CREATE INDEX trace_spans_terminal ON trace_spans(terminal_id);
    CREATE TABLE trace_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workflow_id INTEGER NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
        span_id INTEGER REFERENCES trace_spans(id) ON DELETE CASCADE,
        timestamp INTEGER NOT NULL CHECK (timestamp >= 0),
        kind TEXT NOT NULL CHECK (kind IN ('processStarted', 'processExited', 'processFailed', 'processStopped')),
        message TEXT NOT NULL,
        terminal_id INTEGER,
        byte_offset INTEGER,
        CHECK ((terminal_id IS NULL) = (byte_offset IS NULL)),
        CHECK (terminal_id IS NULL OR terminal_id > 0),
        CHECK (byte_offset IS NULL OR byte_offset >= 0)
    ) STRICT;
    CREATE INDEX trace_events_workflow ON trace_events(workflow_id, id);
    CREATE INDEX trace_events_span ON trace_events(span_id, id)",
    // 7: Pinned workflow executions and durable events for each stage invocation.
    "CREATE TABLE workflow_runs (
        workflow_id INTEGER PRIMARY KEY REFERENCES workflows(id) ON DELETE CASCADE,
        state TEXT NOT NULL,
        trace_sequence INTEGER NOT NULL DEFAULT 0
    ) STRICT;
    ALTER TABLE trace_spans ADD COLUMN run_generation INTEGER;
    CREATE TABLE trace_events_v7 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workflow_id INTEGER NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
        span_id INTEGER REFERENCES trace_spans(id) ON DELETE CASCADE,
        timestamp INTEGER NOT NULL CHECK (timestamp >= 0),
        kind TEXT NOT NULL CHECK (kind IN ('processStarted', 'processExited', 'processFailed', 'processStopped', 'workflowEvent')),
        message TEXT NOT NULL,
        terminal_id INTEGER,
        byte_offset INTEGER,
        CHECK ((terminal_id IS NULL) = (byte_offset IS NULL)),
        CHECK (terminal_id IS NULL OR terminal_id > 0),
        CHECK (byte_offset IS NULL OR byte_offset >= 0)
    ) STRICT;
    INSERT INTO trace_events_v7 SELECT * FROM trace_events;
    DELETE FROM sqlite_sequence WHERE name = 'trace_events_v7';
    INSERT INTO sqlite_sequence (name, seq)
        SELECT 'trace_events_v7', seq FROM sqlite_sequence WHERE name = 'trace_events';
    DROP TABLE trace_events;
    ALTER TABLE trace_events_v7 RENAME TO trace_events;
    CREATE INDEX trace_events_workflow ON trace_events(workflow_id, id);
    CREATE INDEX trace_events_span ON trace_events(span_id, id)",
    // 8: Ordered terminal sizes at an anchored trace event's byte boundary.
    "ALTER TABLE trace_events ADD COLUMN boundary_sizes BLOB CHECK
        (boundary_sizes IS NULL OR (length(boundary_sizes) <= 2048 AND length(boundary_sizes) % 8 = 0))",
    // 9: Single-agent lifecycle includes interruption without rebuilding history's parent table.
    "ALTER TABLE workflows ADD COLUMN lifecycle_status TEXT CHECK
        (lifecycle_status IN ('running', 'exited', 'failed', 'cancelled', 'interrupted'));
    UPDATE workflows SET lifecycle_status = agent_status WHERE kind = 'single_agent'",
    // 10: Assignment spans end on explicit completion, independently of process lifetimes.
    // Existing spans retain their recorded lifecycle semantics.
    "ALTER TABLE trace_spans ADD COLUMN work_span INTEGER NOT NULL DEFAULT 0 CHECK (work_span IN (0, 1))",
    // 11: Correlate asynchronous harness events with the prompt that owns them.
    "ALTER TABLE trace_spans ADD COLUMN harness_turn_id TEXT;
     CREATE UNIQUE INDEX trace_harness_turn ON trace_spans(terminal_id, harness_turn_id)
     WHERE harness_turn_id IS NOT NULL",
    // 12: Keep terminal ownership even when an idle process has no Activity span.
    "CREATE TABLE workflow_terminals (
        terminal_id INTEGER PRIMARY KEY CHECK (terminal_id > 0),
        workflow_id INTEGER NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
        agent_id INTEGER
    ) STRICT;
    CREATE INDEX workflow_terminals_workflow ON workflow_terminals(workflow_id, terminal_id);
    INSERT OR IGNORE INTO workflow_terminals (terminal_id, workflow_id, agent_id)
        SELECT s.terminal_id, l.workflow_id,
            CASE WHEN l.lane_key LIKE 'agent:%' THEN CAST(SUBSTR(l.lane_key, 7) AS INTEGER) END
        FROM trace_spans s JOIN trace_lanes l ON l.id = s.lane_id
        JOIN workflows w ON w.id = l.workflow_id
        WHERE s.terminal_id > 0 AND (w.kind IN ('draft', 'terminal') OR l.is_agent = 1);
    INSERT OR IGNORE INTO workflow_terminals (terminal_id, workflow_id)
        SELECT e.terminal_id, e.workflow_id FROM trace_events e
        JOIN workflows w ON w.id = e.workflow_id
        WHERE e.terminal_id > 0 AND w.kind IN ('draft', 'terminal')",
    // 13: Extend harness choices without rebuilding history's parent table. The legacy harness
    // column's CHECK constraint remains; new reads and writes use harness_id instead.
    "ALTER TABLE workflows ADD COLUMN harness_id TEXT CHECK
        (harness_id IN ('codex', 'claude_code', 'pi', 'antigravity', 'omp'));
     UPDATE workflows SET harness_id = harness",
    // 14: Keep the checked column for existing databases and use an extensible harness ID.
    // Rust validates harness choices; retaining the parent table preserves dependent history.
    "ALTER TABLE workflows RENAME COLUMN harness_id TO legacy_harness_id;
     ALTER TABLE workflows ADD COLUMN harness_id TEXT;
     UPDATE workflows SET harness_id = legacy_harness_id",
    // 15: Exact harness sessions, tied to terminal ownership rather than a shared folder.
    "ALTER TABLE workflow_terminals ADD COLUMN harness_session TEXT"
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
    pub(crate) fn execute_test_sql(&self, sql: &str) {
        self.connection
            .execute_batch(sql)
            .expect("test SQL should execute");
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
    #[error("failed to encode workflow run state")]
    RunEncoding(#[from] serde_json::Error),
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
    use crate::workflow::SessionId;

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

    fn legacy_workflow_history() -> Connection {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .pragma_update(None, "foreign_keys", true)
            .unwrap();
        for migration in &MIGRATIONS[..11] {
            connection.execute_batch(migration).unwrap();
        }
        connection.pragma_update(None, "user_version", 11).unwrap();
        connection.execute_batch(
            "INSERT INTO sessions (id, folder, name, started_at) VALUES (1, '/folder', 'Session', 123);
             INSERT INTO workflows (id, session_id, name, kind, harness, lifecycle_status, closed_at)
                 VALUES (1, 1, 'Claude Code', 'single_agent', 'claude_code', 'cancelled', 456),
                        (2, 1, 'Agents', 'agents', NULL, NULL, NULL),
                        (99, 1, 'Deleted', 'draft', NULL, NULL, NULL);
             DELETE FROM workflows WHERE id = 99;
             INSERT INTO agents (id, workflow_id, role) VALUES (7, 2, 'Worker');
             INSERT INTO workflow_runs (workflow_id, state, trace_sequence) VALUES (2, 'kept run state', 3);
             INSERT INTO trace_lanes (id, workflow_id, lane_key, name, is_agent, harness)
                 VALUES (8, 2, 'worker', 'Worker', 1, 'pi');
             INSERT INTO trace_spans (id, lane_id, title, started_at, status, harness_turn_id)
                 VALUES (9, 8, 'Task', 123, 'running', 'turn-1');
             INSERT INTO trace_events (id, workflow_id, span_id, timestamp, kind, message)
                 VALUES (10, 2, 9, 123, 'processStarted', 'Started');"
        ).unwrap();
        connection
    }

    #[test]
    fn new_harness_migration_preserves_workflows_and_dependent_history() {
        let connection = legacy_workflow_history();
        let mut store = Store::with_connection(connection).unwrap();
        let preserved: (String, String, i64) = store
            .connection
            .query_row(
                "SELECT harness_id, lifecycle_status, closed_at FROM workflows WHERE id = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(preserved, ("claude_code".into(), "cancelled".into(), 456));
        let run: (String, i64) = store
            .connection
            .query_row(
                "SELECT state, trace_sequence FROM workflow_runs WHERE workflow_id = 2",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(run, ("kept run state".into(), 3));
        for (table, id) in [
            ("agents", 7),
            ("trace_lanes", 8),
            ("trace_spans", 9),
            ("trace_events", 10),
        ] {
            let stored: i64 = store
                .connection
                .query_row(&format!("SELECT id FROM {table}"), [], |row| row.get(0))
                .unwrap();
            assert_eq!(stored, id);
        }
        assert!(
            store
                .connection
                .prepare("PRAGMA foreign_key_check")
                .unwrap()
                .query([])
                .unwrap()
                .next()
                .unwrap()
                .is_none()
        );
        for harness in [
            crate::HarnessId::Antigravity,
            crate::HarnessId::Omp,
            crate::HarnessId::Opencode,
        ] {
            store
                .update_workflow(
                    crate::WorkflowId(1),
                    harness.definition().name,
                    crate::WorkflowKind::SingleAgent,
                    Some(harness),
                )
                .unwrap();
            let stored: String = store
                .connection
                .query_row("SELECT harness_id FROM workflows WHERE id = 1", [], |row| {
                    row.get(0)
                })
                .unwrap();
            assert_eq!(stored, super::workflows::harness_name(harness));
        }
        let (id, _) = store
            .create_workflow(SessionId(1), "New", crate::WorkflowKind::Draft, &[])
            .unwrap();
        assert!(id.0 > 99, "Deleted workflow IDs must not be reused");
        store
            .connection
            .execute("DELETE FROM workflows WHERE id = 2", [])
            .unwrap();
        for table in [
            "agents",
            "workflow_runs",
            "trace_lanes",
            "trace_spans",
            "trace_events",
        ] {
            let remaining: i64 = store
                .connection
                .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                    row.get(0)
                })
                .unwrap();
            assert_eq!(
                remaining, 0,
                "Deleting a workflow still cascades to {table}"
            );
        }
    }

    #[test]
    fn harness_migrations_preserve_version_twelve_terminal_ownership() {
        let connection = legacy_workflow_history();
        connection.execute_batch(MIGRATIONS[11]).unwrap();
        connection.pragma_update(None, "user_version", 12).unwrap();
        connection
            .execute_batch(
                "INSERT INTO workflow_terminals (terminal_id, workflow_id, agent_id)
                 VALUES (42, 1, NULL), (43, 2, 7)",
            )
            .unwrap();

        let store = Store::with_connection(connection).unwrap();
        let harness: String = store
            .connection
            .query_row("SELECT harness_id FROM workflows WHERE id = 1", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(harness, "claude_code");
        for (workflow, terminal, agent) in [(1, 42, None), (2, 43, Some(crate::AgentId(7)))] {
            let history = store.terminal_history(crate::WorkflowId(workflow)).unwrap();
            assert_eq!(history.len(), 1);
            assert_eq!(history[0].terminal_id.value(), terminal);
            assert_eq!(history[0].agent_id, agent);
        }
        store
            .connection
            .execute("DELETE FROM workflows WHERE id = 2", [])
            .unwrap();
        assert_eq!(store.terminal_history(crate::WorkflowId(2)).unwrap(), []);
        assert_eq!(
            store.terminal_history(crate::WorkflowId(1)).unwrap().len(),
            1
        );
        assert!(
            store
                .connection
                .prepare("PRAGMA foreign_key_check")
                .unwrap()
                .query([])
                .unwrap()
                .next()
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn extensible_harness_migration_preserves_version_thirteen_choices_and_history() {
        let connection = legacy_workflow_history();
        for migration in &MIGRATIONS[11..13] {
            connection.execute_batch(migration).unwrap();
        }
        connection.pragma_update(None, "user_version", 13).unwrap();
        connection
            .execute("UPDATE workflows SET harness_id = 'omp' WHERE id = 1", [])
            .unwrap();
        let mut store = Store::with_connection(connection).unwrap();
        let preserved: (String, String, i64) = store
            .connection
            .query_row(
                "SELECT harness_id, lifecycle_status, closed_at FROM workflows WHERE id = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(preserved, ("omp".into(), "cancelled".into(), 456));
        store
            .update_workflow(
                crate::WorkflowId(1),
                "OpenCode",
                crate::WorkflowKind::SingleAgent,
                Some(crate::HarnessId::Opencode),
            )
            .unwrap();
        let harness: String = store
            .connection
            .query_row("SELECT harness_id FROM workflows WHERE id = 1", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(harness, "opencode");
        for (table, id) in [
            ("agents", 7),
            ("trace_lanes", 8),
            ("trace_spans", 9),
            ("trace_events", 10),
        ] {
            let stored: i64 = store
                .connection
                .query_row(&format!("SELECT id FROM {table}"), [], |row| row.get(0))
                .unwrap();
            assert_eq!(stored, id);
        }
        let (id, _) = store
            .create_workflow(SessionId(1), "New", crate::WorkflowKind::Draft, &[])
            .unwrap();
        assert!(id.0 > 99);
        assert!(
            store
                .connection
                .prepare("PRAGMA foreign_key_check")
                .unwrap()
                .query([])
                .unwrap()
                .next()
                .unwrap()
                .is_none()
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
            .create_workflow(id, "Terminal", crate::WorkflowKind::Terminal, &[])
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
    fn migration_from_version_two_keeps_workflows_and_stores_a_harness() {
        let mut connection = Connection::open_in_memory().unwrap();
        connection
            .pragma_update(None, "foreign_keys", true)
            .unwrap();
        connection.execute_batch(MIGRATIONS[0]).unwrap();
        connection.execute_batch(MIGRATIONS[1]).unwrap();
        connection
            .execute_batch(
                "INSERT INTO sessions VALUES (1, '/folder', 'Session', 1);
                 INSERT INTO workflows VALUES (1, 1, 'Terminal', 'terminal');
                 INSERT INTO workflows VALUES (2, 1, 'Terminal', 'terminal');
                 INSERT INTO workflows VALUES (3, 1, 'Terminal', 'terminal');
                 DELETE FROM workflows WHERE id IN (2, 3)",
            )
            .unwrap();
        connection.pragma_update(None, "user_version", 2).unwrap();
        migrate(&mut connection).unwrap();
        let mut store = Store::with_connection(connection).unwrap();

        // Workflow 3 was deleted before the migration, and its ID must not come back.
        let (id, _) = store
            .create_workflow(
                SessionId(1),
                "New workflow",
                crate::WorkflowKind::Draft,
                &[],
            )
            .unwrap();
        assert!(
            id.0 > 3,
            "deleted workflow IDs must not be reused, got {id:?}"
        );
        store
            .update_workflow(
                id,
                "Single agent",
                crate::WorkflowKind::SingleAgent,
                Some(crate::HarnessId::ClaudeCode),
            )
            .unwrap();

        let workflows = store.workflows(Path::new("/folder")).unwrap();
        assert_eq!(workflows.len(), 2);
        assert_eq!(workflows[0].kind, crate::WorkflowKind::Terminal);
        assert_eq!(workflows[0].harness, None);
        assert_eq!(workflows[1].kind, crate::WorkflowKind::SingleAgent);
        assert_eq!(workflows[1].harness, Some(crate::HarnessId::ClaudeCode));
    }

    #[test]
    fn migration_to_agents_keeps_workflows_and_never_reuses_their_ids() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .pragma_update(None, "foreign_keys", true)
            .unwrap();
        for migration in &MIGRATIONS[..4] {
            connection.execute_batch(migration).unwrap();
        }
        connection.pragma_update(None, "user_version", 4).unwrap();
        connection
            .execute_batch(
                "INSERT INTO sessions (folder, name, started_at) VALUES ('/folder', 'Session', 1);
                 INSERT INTO workflows (session_id, name, kind)
                     VALUES (1, 'New workflow', 'draft'), (1, 'Terminal', 'terminal'),
                         (1, 'Closed', 'terminal');
                 DELETE FROM workflows WHERE id = 3;",
            )
            .unwrap();
        let mut store = Store::with_connection(connection).unwrap();
        let folder = Path::new("/folder");
        assert_eq!(
            store
                .workflows(folder)
                .unwrap()
                .iter()
                .map(|workflow| (
                    workflow.workflow_id.0,
                    workflow.name.as_str(),
                    workflow.kind
                ))
                .collect::<Vec<_>>(),
            [
                (1, "New workflow", crate::WorkflowKind::Draft),
                (2, "Terminal", crate::WorkflowKind::Terminal)
            ]
        );

        let (workflow_id, agent_ids) = store
            .create_workflow(
                crate::SessionId(1),
                "Agents",
                crate::WorkflowKind::Agents,
                &["Implementer", "Reviewer"],
            )
            .unwrap();
        assert_eq!(
            workflow_id.0, 4,
            "a closed workflow's ID must not be reused"
        );
        let workflows = store.workflows(folder).unwrap();
        let agents = &workflows.last().unwrap().agents;
        assert_eq!(
            agents
                .iter()
                .map(|agent| (agent.agent_id, agent.role.as_str()))
                .collect::<Vec<_>>(),
            [(agent_ids[0], "Implementer"), (agent_ids[1], "Reviewer")]
        );
        assert!(
            workflows[..2]
                .iter()
                .all(|workflow| workflow.agents.is_empty())
        );

        store
            .connection
            .execute(
                "DELETE FROM workflows WHERE id = ?1",
                [sql_integer(workflow_id.0).unwrap()],
            )
            .unwrap();
        let remaining: i64 = store
            .connection
            .query_row("SELECT COUNT(*) FROM agents", [], |row| row.get(0))
            .unwrap();
        assert_eq!(remaining, 0, "deleting a workflow deletes its agents");
        assert!(
            store
                .connection
                .execute(
                    "INSERT INTO workflows (session_id, name, kind) VALUES (1, 'Other', 'other')",
                    [],
                )
                .is_err()
        );
    }

    #[test]
    fn migration_from_version_three_preserves_types_sessions_and_workflows() {
        let connection = Connection::open_in_memory().unwrap();
        for migration in &MIGRATIONS[..3] {
            connection.execute_batch(migration).unwrap();
        }
        connection.pragma_update(None, "user_version", 3).unwrap();
        connection.execute_batch(
            "INSERT INTO sessions (id, folder, name, started_at) VALUES (1, '/folder', 'Kept session', 123);
             INSERT INTO workflows (id, session_id, name, kind) VALUES (1, 1, 'Kept workflow', 'terminal');
             INSERT INTO folder_selection (folder, session_id) VALUES ('/folder', 1);
             INSERT INTO workflow_types (id) VALUES (1);
             INSERT INTO workflow_type_versions (type_id, version, definition, created_at)
             VALUES (1, 1, 'kept definition', 123);"
        ).unwrap();
        let mut store = Store::with_connection(connection).unwrap();
        assert_eq!(
            usize::try_from(schema_version(&store.connection)).unwrap(),
            MIGRATIONS.len()
        );
        assert_eq!(
            store.sessions(Path::new("/folder")).unwrap()[0].name,
            "Kept session"
        );
        assert_eq!(
            store.selected_session(Path::new("/folder")).unwrap(),
            Some(crate::SessionId(1))
        );
        let workflows = store.workflows(Path::new("/folder")).unwrap();
        assert_eq!(workflows.len(), 1);
        assert_eq!(workflows[0].name, "Kept workflow");
        assert_eq!(
            store.workflow_type_version(1, 1).unwrap().as_deref(),
            Some("kept definition")
        );
        assert_eq!(
            store
                .add_workflow_type_version(1, "new definition", 124)
                .unwrap(),
            Some(2)
        );
        let summary = store.trace_summary(crate::WorkflowId(1)).unwrap();
        assert_eq!(summary.span_count, 0);
        let span = store
            .start_trace_span(&NewTraceSpan {
                workflow_id: crate::WorkflowId(1),
                lane_key: "terminal",
                lane_name: "Terminal",
                is_agent: false,
                role: None,
                harness: None,
                title: "Shell",
                started_at: 124,
                anchor: None,
            })
            .unwrap();
        assert_eq!(
            store
                .trace_summary(crate::WorkflowId(1))
                .unwrap()
                .span_count,
            1
        );
        assert_eq!(store.trace_events(span, None, 10).unwrap().events.len(), 1);
        store.close_workflow(crate::WorkflowId(1), 125).unwrap();
        assert!(store.workflows(Path::new("/folder")).unwrap().is_empty());
        assert_eq!(
            store
                .workflow_trace(crate::WorkflowId(1), None, 10)
                .unwrap()
                .spans
                .len(),
            1
        );
    }

    #[test]
    fn migration_from_version_four_keeps_agent_harness_status_and_adds_traces() {
        let connection = Connection::open_in_memory().unwrap();
        for migration in &MIGRATIONS[..4] {
            connection.execute_batch(migration).unwrap();
        }
        connection.pragma_update(None, "user_version", 4).unwrap();
        connection.execute_batch(
            "INSERT INTO sessions (id, folder, name, started_at) VALUES (1, '/folder', 'Session', 123);
             INSERT INTO workflows (id, session_id, name, kind, harness, agent_status)
             VALUES (1, 1, 'Claude Code', 'single_agent', 'claude_code', 'cancelled');"
        ).unwrap();
        let mut store = Store::with_connection(connection).unwrap();
        assert_eq!(
            usize::try_from(schema_version(&store.connection)).unwrap(),
            MIGRATIONS.len()
        );
        let workflows = store.workflows(Path::new("/folder")).unwrap();
        assert_eq!(workflows.len(), 1);
        assert_eq!(workflows[0].kind, crate::WorkflowKind::SingleAgent);
        assert_eq!(workflows[0].harness, Some(crate::HarnessId::ClaudeCode));
        assert_eq!(
            workflows[0].agent_status,
            Some(crate::WorkflowStatus::Cancelled)
        );
        let span = store
            .start_trace_span(&NewTraceSpan {
                workflow_id: workflows[0].workflow_id,
                lane_key: "agent",
                lane_name: "Agent",
                is_agent: true,
                role: Some("agent"),
                harness: Some("Claude Code"),
                title: "Claude Code",
                started_at: 124,
                anchor: None,
            })
            .unwrap();
        assert_eq!(store.trace_events(span, None, 10).unwrap().events.len(), 1);
        store.close_workflow(workflows[0].workflow_id, 125).unwrap();
        assert!(store.workflows(Path::new("/folder")).unwrap().is_empty());
        assert_eq!(
            store
                .workflow_trace(workflows[0].workflow_id, None, 10)
                .unwrap()
                .spans
                .len(),
            1
        );
    }

    #[test]
    fn migration_from_version_five_preserves_agent_identity_and_role_order() {
        let connection = Connection::open_in_memory().unwrap();
        for migration in &MIGRATIONS[..5] {
            connection.execute_batch(migration).unwrap();
        }
        connection.pragma_update(None, "user_version", 5).unwrap();
        connection.execute_batch(
            "INSERT INTO sessions (id, folder, name, started_at) VALUES (1, '/folder', 'Session', 123);
             INSERT INTO workflows (id, session_id, name, kind) VALUES (1, 1, 'Agents', 'agents');
             INSERT INTO agents (id, workflow_id, role) VALUES (7, 1, 'Reviewer'), (8, 1, 'Implementer');"
        ).unwrap();
        let store = Store::with_connection(connection).unwrap();
        let workflows = store.workflows(Path::new("/folder")).unwrap();
        assert_eq!(workflows[0].kind, crate::WorkflowKind::Agents);
        assert_eq!(
            workflows[0]
                .agents
                .iter()
                .map(|agent| (agent.agent_id.0, agent.role.as_str()))
                .collect::<Vec<_>>(),
            [(7, "Reviewer"), (8, "Implementer")]
        );
        assert_eq!(
            store
                .trace_summary(workflows[0].workflow_id)
                .unwrap()
                .span_count,
            0
        );
        assert_eq!(
            usize::try_from(schema_version(&store.connection)).unwrap(),
            MIGRATIONS.len()
        );
    }

    #[test]
    fn migration_from_version_six_keeps_trace_ids_and_accepts_workflow_events() {
        let connection = Connection::open_in_memory().unwrap();
        for migration in &MIGRATIONS[..6] {
            connection.execute_batch(migration).unwrap();
        }
        connection.pragma_update(None, "user_version", 6).unwrap();
        connection.execute_batch(
            "INSERT INTO sessions (id, folder, name, started_at) VALUES (1, '/folder', 'Work', 123);
             INSERT INTO workflows (id, session_id, name, kind) VALUES (1, 1, 'Shell', 'terminal');
             INSERT INTO trace_events (id, workflow_id, timestamp, kind, message)
             VALUES (80, 1, 123, 'processStarted', 'Earlier event');
             DELETE FROM trace_events WHERE id = 80;"
        ).unwrap();
        let store = Store::with_connection(connection).unwrap();
        store
            .connection
            .execute(
                "INSERT INTO trace_events (workflow_id, timestamp, kind, message)
             VALUES (1, 124, 'workflowEvent', 'Stage started')",
                [],
            )
            .unwrap();
        assert_eq!(store.connection.last_insert_rowid(), 81);
        assert_eq!(store.workflows(Path::new("/folder")).unwrap().len(), 1);
    }

    #[test]
    fn migration_preserves_idle_shell_and_agent_terminal_ownership() {
        let connection = Connection::open_in_memory().unwrap();
        for migration in &MIGRATIONS[..11] {
            connection.execute_batch(migration).unwrap();
        }
        connection.pragma_update(None, "user_version", 11).unwrap();
        connection.execute_batch(
            "INSERT INTO sessions (id, folder, name, started_at) VALUES (1, '/folder', 'Work', 1);
             INSERT INTO workflows (id, session_id, name, kind) VALUES
                (1, 1, 'Shell', 'terminal'), (2, 1, 'Agent', 'single_agent'), (3, 1, 'Run', 'agents');
             INSERT INTO trace_lanes (id, workflow_id, lane_key, name, is_agent) VALUES
                (1, 2, 'terminal', 'Terminal', 0), (2, 2, 'agent', 'Agent', 1), (3, 3, 'agent:8', 'Worker', 1);
             INSERT INTO trace_spans (lane_id, title, started_at, status, terminal_id) VALUES
                (1, 'Shell', 1, 'stopped', 20), (2, 'Agent', 2, 'exited', 21), (3, 'Worker', 2, 'exited', 31);
             INSERT INTO trace_events (workflow_id, timestamp, kind, message, terminal_id, byte_offset)
                VALUES (1, 1, 'processStarted', 'Idle shell', 10, 0);"
        ).unwrap();
        let store = Store::with_connection(connection).unwrap();
        let history = |id| store.terminal_history(crate::WorkflowId(id)).unwrap();
        assert_eq!(history(1)[0].terminal_id.value(), 10);
        assert_eq!(history(2).len(), 1);
        assert_eq!(history(2)[0].terminal_id.value(), 21);
        assert_eq!(history(3)[0].agent_id, Some(crate::AgentId(8)));
    }

    #[test]
    fn migration_from_version_nine_preserves_process_spans_and_terminal_anchors() {
        let connection = Connection::open_in_memory().unwrap();
        for migration in &MIGRATIONS[..9] {
            connection.execute_batch(migration).unwrap();
        }
        connection.pragma_update(None, "user_version", 9).unwrap();
        connection.execute_batch(
            "INSERT INTO sessions (id, folder, name, started_at) VALUES (1, '/folder', 'Work', 100);
             INSERT INTO workflows (id, session_id, name, kind) VALUES (1, 1, 'Adversarial', 'agents');
             INSERT INTO trace_lanes (id, workflow_id, lane_key, name, is_agent, role, harness)
             VALUES (1, 1, 'agent:1', 'Implementer', 1, 'implementer', 'pi');
             INSERT INTO trace_spans (id, lane_id, title, started_at, ended_at, status, terminal_id, run_generation)
             VALUES (1, 1, 'Implement', 100, 200, 'exited', 99, 1);
             INSERT INTO trace_events (id, workflow_id, span_id, timestamp, kind, message, terminal_id, byte_offset, boundary_sizes)
             VALUES (1, 1, 1, 100, 'processStarted', 'Process started.', 99, 0, X''),
                    (2, 1, 1, 200, 'processExited', 'Process exited with code 0.', 99, 42, X'');"
        ).unwrap();
        let store = Store::with_connection(connection).unwrap();
        let page = store
            .workflow_trace(crate::WorkflowId(1), None, 10)
            .unwrap();
        let span = &page.spans[0];
        assert_eq!(span.title, "Implement");
        assert_eq!((span.started_at, span.ended_at), (100, Some(200)));
        assert_eq!(span.status, crate::TraceSpanStatus::Exited);
        let events = store.trace_events(span.span_id, None, 10).unwrap().events;
        assert_eq!(events.len(), 2);
        assert_eq!(events[1].kind, crate::TraceEventKind::ProcessExited);
        assert_eq!(
            events[1].anchor,
            Some(crate::TraceAnchor {
                terminal_id: crate::TerminalId::from_value(99),
                byte_offset: 42,
                boundary_sizes: Some(vec![]),
            })
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
