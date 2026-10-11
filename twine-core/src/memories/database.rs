use super::discovery::{Backing, Collector, identifier, source};
use super::locations::repository_root;
use super::{MemoryHarness, MemoryKind, MemoryScope};
use crate::{FileContent, TEXT_LIMIT};
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{self, Read};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use thiserror::Error;

const DATABASE_LIMIT: u64 = 64 * 1024 * 1024;
const RECORD_LIMIT: usize = 256;

#[derive(Debug, Error)]
enum DatabaseError {
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Sql(#[from] rusqlite::Error),
    #[error("The memory database exceeds the 64 MiB snapshot limit.")]
    TooLarge,
    #[error("The memory database changed during its snapshot. Refresh to retry.")]
    Changed,
}

struct Snapshot {
    _directory: tempfile::TempDir,
    connection: Connection,
}

#[derive(Eq, PartialEq)]
struct Identity {
    device: u64,
    inode: u64,
    length: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}

fn identity(root: &Path, path: &Path) -> Result<Option<Identity>, DatabaseError> {
    match crate::files::access::open_file(root, path, false) {
        Ok(file) => {
            let m = file.metadata()?;
            Ok(Some(Identity {
                device: m.dev(),
                inode: m.ino(),
                length: m.len(),
                modified: (m.mtime(), m.mtime_nsec()),
                changed: (m.ctime(), m.ctime_nsec()),
            }))
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

impl Snapshot {
    fn open(root: &Path, path: &Path) -> Result<Self, DatabaseError> {
        Self::open_with_hook(root, path, || {})
    }

    fn open_with_hook(
        root: &Path,
        path: &Path,
        after_main: impl FnOnce(),
    ) -> Result<Self, DatabaseError> {
        let directory = tempfile::tempdir()?;
        let target = directory.path().join("memory.sqlite");
        let wal = PathBuf::from(format!("{}-wal", path.display()));
        let before = (identity(root, path)?, identity(root, &wal)?);
        copy_part(root, path, &target)?;
        after_main();
        let target_wal = directory.path().join("memory.sqlite-wal");
        match copy_part(root, &wal, &target_wal) {
            Ok(()) => {}
            Err(DatabaseError::Io(e)) if e.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        if before != (identity(root, path)?, identity(root, &wal)?) {
            return Err(DatabaseError::Changed);
        }
        // SQLite may create SHM and recover WAL only beside this private copy.
        let connection = Connection::open_with_flags(
            &target,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        connection.pragma_update(None, "query_only", true)?;
        Ok(Self {
            _directory: directory,
            connection,
        })
    }
}

fn copy_part(root: &Path, path: &Path, target: &Path) -> Result<(), DatabaseError> {
    let mut file = crate::files::access::open_file(root, path, false)?;
    let before = file.metadata()?;
    if before.len() > DATABASE_LIMIT {
        return Err(DatabaseError::TooLarge);
    }
    let mut output = File::create_new(target)?;
    if io::copy(&mut (&mut file).take(DATABASE_LIMIT + 1), &mut output)? > DATABASE_LIMIT {
        return Err(DatabaseError::TooLarge);
    }
    let after = file.metadata()?;
    if before.len() != after.len() || before.modified()? != after.modified()? {
        return Err(DatabaseError::Changed);
    }
    Ok(())
}

fn columns(connection: &Connection, table: &str) -> Result<HashSet<String>, rusqlite::Error> {
    let mut query = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    query.query_map([], |row| row.get(1))?.collect()
}

fn database_paths(root: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    let mut paths: Vec<_> = entries
        .take(super::SOURCE_LIMIT)
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| {
            let name = p.file_name().unwrap_or_default().to_string_lossy();
            name.ends_with(".sqlite")
                && (name.starts_with("memories_") || name.starts_with("state_"))
        })
        .collect();
    paths.sort();
    paths.truncate(32);
    paths
}

fn thread_context(root: &Path, paths: &[PathBuf], ids: &[String]) -> HashMap<String, String> {
    let mut context = HashMap::new();
    for path in paths.iter().rev().filter(|p| {
        p.file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .starts_with("state_")
    }) {
        let Ok(snapshot) = Snapshot::open(root, path) else {
            continue;
        };
        let Ok(mut query) = snapshot
            .connection
            .prepare("SELECT substr(cwd, 1, 4096) FROM threads WHERE id = ?")
        else {
            continue;
        };
        for id in ids {
            if context.contains_key(id) {
                continue;
            }
            if let Ok(Some(cwd)) = query
                .query_row([id], |row| row.get::<_, String>(0))
                .optional()
            {
                context.insert(id.clone(), cwd);
            }
        }
        if context.len() == ids.len() {
            break;
        }
    }
    context
}

pub(super) fn discover(root: &Path, folder: Option<&Path>, collector: &mut Collector) {
    let paths = database_paths(root);
    for path in &paths {
        match discover_database(root, path, folder, &paths, collector) {
            Ok(()) => {}
            Err(error) => collector
                .diagnostics
                .push(format!("Cannot inspect {}: {error}", path.display())),
        }
    }
}

fn discover_database(
    root: &Path,
    path: &Path,
    folder: Option<&Path>,
    state_paths: &[PathBuf],
    collector: &mut Collector,
) -> Result<(), DatabaseError> {
    let snapshot = Snapshot::open(root, path)?;
    let connection = &snapshot.connection;
    let fields = columns(connection, "stage1_outputs")?;
    if !fields.contains("thread_id") {
        return Ok(());
    }
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let group = format!("Codex SQLite: {name}");
    let count: i64 =
        connection.query_row("SELECT count(*) FROM stage1_outputs", [], |r| r.get(0))?;
    let metadata = json!({"database": path, "table": "stage1_outputs", "recordCount": count,
        "columns": fields, "note": "Extraction records are separate from consolidated files. This read uses a private database/WAL snapshot and never updates the original database."});
    let mut status = source(
        path,
        &format!("{name} · {count} extraction records"),
        MemoryHarness::Codex,
        MemoryScope::Global,
        MemoryKind::StoreStatus,
        &group,
    );
    status.format = "json".into();
    collector.push(
        status,
        Backing::Text(serde_json::to_string_pretty(&metadata).unwrap_or_default()),
    );
    let mut query = connection.prepare(&extraction_query(&fields))?;
    let rows = query
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, Option<String>>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, bool>(3)?,
                r.get::<_, bool>(4)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let ids: Vec<_> = rows.iter().map(|r| r.0.clone()).collect();
    let context = thread_context(root, state_paths, &ids);
    for (thread, slug, generated, raw, summary) in rows {
        for (column, kind, present) in [
            ("raw_memory", MemoryKind::RawMemory, raw),
            ("rollout_summary", MemoryKind::RolloutSummary, summary),
        ] {
            if !present {
                continue;
            }
            let title = format!(
                "{} · {}",
                slug.as_deref().unwrap_or(&thread),
                column.replace('_', " ")
            );
            let mut entry = source(
                path,
                &title,
                MemoryHarness::Codex,
                MemoryScope::Global,
                kind,
                &group,
            );
            entry.location = format!("{}#stage1_outputs/{thread}/{column}", path.display());
            entry.id = identifier(&entry.location);
            entry.format = "markdown".into();
            entry.modified_at = u64::try_from(generated).ok().filter(|v| *v > 0);
            if let Some(cwd) = context.get(&thread) {
                entry.association = Some(format!(
                    "Source folder: {cwd}. Stored in the global SQLite database."
                ));
                if folder.is_some_and(|folder| {
                    repository_root(folder) == repository_root(Path::new(cwd))
                }) {
                    entry.scope = MemoryScope::Folder;
                }
            }
            collector.push(
                entry,
                Backing::Database {
                    root: root.to_owned(),
                    path: path.to_owned(),
                    thread: thread.clone(),
                    column: column.into(),
                },
            );
        }
    }
    if count > i64::try_from(RECORD_LIMIT).unwrap_or(i64::MAX) {
        collector.diagnostics.push(format!(
            "{name}: showing the newest {RECORD_LIMIT} extraction records of {count}."
        ));
    }
    Ok(())
}

fn extraction_query(fields: &HashSet<String>) -> String {
    let slug = if fields.contains("rollout_slug") {
        "rollout_slug"
    } else {
        "NULL"
    };
    let generated = if fields.contains("generated_at") {
        "generated_at"
    } else {
        "0"
    };
    let raw = if fields.contains("raw_memory") {
        "coalesce(length(trim(raw_memory)), 0) > 0"
    } else {
        "0"
    };
    let summary = if fields.contains("rollout_summary") {
        "coalesce(length(trim(rollout_summary)), 0) > 0"
    } else {
        "0"
    };
    format!(
        "SELECT thread_id, {slug}, {generated}, {raw}, {summary} FROM stage1_outputs ORDER BY 3 DESC LIMIT {RECORD_LIMIT}"
    )
}

pub(super) fn read_record(root: &Path, path: &Path, thread: &str, column: &str) -> FileContent {
    match read_text(root, path, thread, column) {
        Ok(content) => content,
        Err(error) => FileContent::Unavailable(error.to_string()),
    }
}

fn read_text(
    root: &Path,
    path: &Path,
    thread: &str,
    column: &str,
) -> Result<FileContent, DatabaseError> {
    if !matches!(column, "raw_memory" | "rollout_summary") {
        return Ok(FileContent::Unsupported);
    }
    let snapshot = Snapshot::open(root, path)?;
    let sql =
        format!("SELECT length(CAST({column} AS BLOB)) FROM stage1_outputs WHERE thread_id = ?");
    let length: Option<i64> = snapshot
        .connection
        .query_row(&sql, [thread], |r| r.get(0))
        .optional()?;
    let Some(length) = length else {
        return Ok(FileContent::Missing);
    };
    if length > i64::try_from(TEXT_LIMIT).unwrap_or(i64::MAX) {
        return Ok(FileContent::TooLarge);
    }
    let sql = format!("SELECT {column} FROM stage1_outputs WHERE thread_id = ?");
    let text: String = snapshot
        .connection
        .query_row(&sql, [thread], |r| r.get(0))?;
    if text.as_bytes().contains(&0) {
        return Ok(FileContent::Binary);
    }
    Ok(FileContent::Text(text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_includes_committed_wal_without_modifying_original_files() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("memories_1.sqlite");
        let db = Connection::open(&path).unwrap();
        db.pragma_update(None, "journal_mode", "wal").unwrap();
        db.execute_batch("CREATE TABLE stage1_outputs(thread_id TEXT, raw_memory TEXT, rollout_summary TEXT, generated_at INTEGER); INSERT INTO stage1_outputs VALUES('a', 'raw note', 'summary', 100);").unwrap();
        let before = std::fs::read(&path).unwrap();
        let wal = std::fs::read(format!("{}-wal", path.display())).unwrap();
        assert_eq!(
            read_record(root.path(), &path, "a", "raw_memory"),
            FileContent::Text("raw note".into())
        );
        assert_eq!(before, std::fs::read(&path).unwrap());
        assert_eq!(
            wal,
            std::fs::read(format!("{}-wal", path.display())).unwrap()
        );
        assert_eq!(
            read_record(root.path(), &path, "missing", "raw_memory"),
            FileContent::Missing
        );
        assert_eq!(
            read_record(root.path(), &path, "a", "title; DROP TABLE stage1_outputs"),
            FileContent::Unsupported
        );
    }

    #[test]
    fn v2_summary_only_records_and_empty_stores_are_visible() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("memories_v2_1.sqlite");
        let db = Connection::open(&path).unwrap();
        db.execute_batch("CREATE TABLE stage1_outputs(thread_id TEXT, rollout_summary TEXT, rollout_slug TEXT, generated_at INTEGER); INSERT INTO stage1_outputs VALUES('a','v2 summary','twine',100);").unwrap();
        let mut collector = Collector::new(false);
        discover(root.path(), None, &mut collector);
        assert_eq!(collector.entries.len(), 2);
        assert_eq!(collector.entries[1].source.kind, MemoryKind::RolloutSummary);
        db.execute("DELETE FROM stage1_outputs", []).unwrap();
        let mut collector = Collector::new(false);
        discover(root.path(), None, &mut collector);
        assert_eq!(collector.entries.len(), 1);
        assert!(
            collector.entries[0]
                .source
                .title
                .contains("0 extraction records")
        );
    }

    #[test]
    fn checkpoint_between_pair_copies_is_rejected() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("memories_1.sqlite");
        let db = Connection::open(&path).unwrap();
        db.pragma_update(None, "journal_mode", "wal").unwrap();
        db.execute_batch("CREATE TABLE values_for_test(id INTEGER, value TEXT); INSERT INTO values_for_test VALUES(1,'a'),(2,'x'); PRAGMA wal_checkpoint(TRUNCATE); UPDATE values_for_test SET value='b' WHERE id=1;").unwrap();
        let result = Snapshot::open_with_hook(root.path(), &path, || {
            db.execute_batch(
                "PRAGMA wal_checkpoint(TRUNCATE); UPDATE values_for_test SET value='y' WHERE id=2;",
            )
            .unwrap();
        });
        assert!(matches!(result, Err(DatabaseError::Changed)));
    }

    #[test]
    fn selected_extraction_can_find_its_folder_beyond_the_old_thread_cap() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("folder");
        std::fs::create_dir_all(folder.join(".git")).unwrap();
        let path = root.path().join("state_5.sqlite");
        let db = Connection::open(&path).unwrap();
        db.execute_batch("CREATE TABLE threads(id TEXT PRIMARY KEY, cwd TEXT); CREATE TABLE stage1_outputs(thread_id TEXT, raw_memory TEXT, rollout_summary TEXT, generated_at INTEGER); WITH RECURSIVE ids(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM ids WHERE n < 5000) INSERT INTO threads SELECT CAST(n AS TEXT),'/other' FROM ids; INSERT INTO stage1_outputs VALUES('5000','note','',100);").unwrap();
        db.execute(
            "UPDATE threads SET cwd = ? WHERE id = '5000'",
            [folder.to_string_lossy().as_ref()],
        )
        .unwrap();
        let mut collector = Collector::new(false);
        discover(root.path(), Some(&folder), &mut collector);
        assert!(collector.entries.iter().any(
            |e| e.source.kind == MemoryKind::RawMemory && e.source.scope == MemoryScope::Folder
        ));
    }
}
