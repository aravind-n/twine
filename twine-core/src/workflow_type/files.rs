use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;

use super::{CatalogError, WorkflowType, WorkflowTypeDefinition, WorkflowTypeRef, validate};
use crate::store::Store;

const MAX_FILE_BYTES: u64 = 1024 * 1024;

/// Keep macOS-valid symbols and Unicode. Remove path separators, colon, and NUL;
/// strip leading periods so saved workflows remain visible in Finder.
pub(super) fn filename_stem(name: &str) -> Option<String> {
    let normalized = name.trim().to_lowercase().nfc().collect::<String>();
    let mut stem = String::new();
    let mut space = false;
    for character in normalized.chars() {
        if character.is_whitespace() {
            space = !stem.is_empty();
        } else if !matches!(character, '/' | ':' | '\0') {
            if space {
                stem.push('_');
            }
            stem.push(character);
            space = false;
        }
    }
    let stem = stem.trim_start_matches('.').to_owned();
    (!stem.is_empty()).then_some(stem)
}

fn save_path(
    directory: &Path,
    name: &str,
    current: Option<&Path>,
) -> Result<(PathBuf, String), CatalogError> {
    let workflows = list(directory)?;
    let entries = fs::read_dir(directory)?.collect::<Result<Vec<_>, _>>()?;
    let available = |stem: &str, display_name: &str| {
        !workflows.iter().any(|(path, workflow)| {
            Some(path.as_path()) != current
                && filename_stem(&workflow.definition.name) == filename_stem(display_name)
        }) && !entries.iter().any(|entry| {
            Some(entry.path().as_path()) != current
                && entry
                    .file_name()
                    .to_string_lossy()
                    .to_lowercase()
                    .nfc()
                    .collect::<String>()
                    == format!("{stem}.toml")
        })
    };
    if name.trim().is_empty() {
        for suffix in 0..=u32::MAX {
            let (stem, display_name) = if suffix == 0 {
                ("untitled".to_owned(), "Untitled".to_owned())
            } else {
                (format!("untitled-{suffix}"), format!("Untitled-{suffix}"))
            };
            if available(&stem, &display_name) {
                return Ok((directory.join(format!("{stem}.toml")), display_name));
            }
        }
        return Err(CatalogError::Conflict);
    }
    let stem = filename_stem(name).ok_or(CatalogError::FileFormat)?;
    if !available(&stem, name) {
        return Err(CatalogError::DuplicateName);
    }
    Ok((directory.join(format!("{stem}.toml")), name.to_owned()))
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct WorkflowFile {
    schema_version: u32,
    id: u64,
    version: u32,
    definition: WorkflowTypeDefinition,
}

impl WorkflowFile {
    fn workflow_type(self) -> Result<WorkflowType, CatalogError> {
        if !matches!(self.schema_version, 1 | 2) || self.id == 0 || self.version == 0 {
            return Err(CatalogError::FileFormat);
        }
        validate(&self.definition).map_err(CatalogError::Invalid)?;
        Ok(WorkflowType {
            reference: WorkflowTypeRef::User {
                type_id: self.id,
                version: self.version,
            },
            definition: self.definition,
        })
    }
}

pub(super) fn read(path: &Path) -> Result<WorkflowType, CatalogError> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    if !file.metadata()?.is_file() || file.metadata()?.len() > MAX_FILE_BYTES {
        return Err(CatalogError::FileFormat);
    }
    let mut contents = String::new();
    file.take(MAX_FILE_BYTES + 1)
        .read_to_string(&mut contents)?;
    if contents.len() as u64 > MAX_FILE_BYTES {
        return Err(CatalogError::FileFormat);
    }
    decode(&contents)
}

/// Bundled defaults and user files share the same format and validation.
pub(super) fn decode(contents: &str) -> Result<WorkflowType, CatalogError> {
    if contents.len() as u64 > MAX_FILE_BYTES {
        return Err(CatalogError::FileFormat);
    }
    toml::from_str::<WorkflowFile>(contents)
        .map_err(|_| CatalogError::FileFormat)?
        .workflow_type()
}

pub(super) fn list(directory: &Path) -> Result<Vec<(PathBuf, WorkflowType)>, CatalogError> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.into()),
    };
    let mut paths = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "toml")
        })
        .collect::<Vec<_>>();
    paths.sort();
    let mut types = Vec::new();
    let mut ids = std::collections::HashSet::new();
    for path in paths {
        if let Ok(workflow_type) = read(&path) {
            let WorkflowTypeRef::User { type_id, .. } = workflow_type.reference else {
                continue;
            };
            if ids.insert(type_id) {
                types.push((path, workflow_type));
            } else {
                tracing::warn!("skipping a duplicate workflow file");
            }
        } else {
            tracing::warn!("skipping an unreadable workflow file");
        }
    }
    types.sort_by(|a, b| a.1.definition.name.cmp(&b.1.definition.name));
    Ok(types)
}

fn archive(directory: &Path, reference: WorkflowTypeRef) -> PathBuf {
    let WorkflowTypeRef::User { type_id, version } = reference else {
        unreachable!("user files only")
    };
    directory
        .join(".history")
        .join(type_id.to_string())
        .join(format!("{version}.toml"))
}

pub(super) fn get(
    directory: &Path,
    reference: WorkflowTypeRef,
) -> Result<Option<WorkflowType>, CatalogError> {
    if let Some((_, workflow_type)) = list(directory)?
        .into_iter()
        .find(|(_, value)| value.reference == reference)
    {
        return Ok(Some(workflow_type));
    }
    match read(&archive(directory, reference)) {
        Ok(value) if value.reference == reference => Ok(Some(value)),
        Ok(_) => Err(CatalogError::FileFormat),
        Err(CatalogError::Io(error)) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

pub(super) fn create(
    directory: &Path,
    definition: &WorkflowTypeDefinition,
) -> Result<WorkflowTypeRef, CatalogError> {
    validate(definition).map_err(CatalogError::Invalid)?;
    let _lock = lock_for_write(directory)?;
    // Stable identity is independent of the file's name and location.
    let id = u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| CatalogError::FileFormat)?
            .as_nanos(),
    )
    .map_err(|_| CatalogError::FileFormat)?;
    let reference = WorkflowTypeRef::User {
        type_id: id,
        version: 1,
    };
    let (path, name) = save_path(directory, &definition.name, None)?;
    let mut definition = definition.clone();
    definition.name = name;
    write(directory, &path, reference, &definition, false)?;
    Ok(reference)
}

pub(super) fn edit(
    directory: &Path,
    source: WorkflowTypeRef,
    definition: &WorkflowTypeDefinition,
    expected: Option<&WorkflowTypeDefinition>,
) -> Result<WorkflowTypeRef, CatalogError> {
    let _lock = lock_for_write(directory)?;
    let WorkflowTypeRef::User { type_id, version } = source else {
        return Err(CatalogError::Conflict);
    };
    let (path, current) = list(directory)?
        .into_iter()
        .find(|(_, value)| {
            matches!(value.reference,
        WorkflowTypeRef::User { type_id: id, .. } if id == type_id)
        })
        .ok_or(CatalogError::NotFound(source))?;
    if current.reference != source
        || expected.is_some_and(|expected| expected != &current.definition)
    {
        return Err(CatalogError::Conflict);
    }
    let reference = WorkflowTypeRef::User {
        type_id,
        version: version.checked_add(1).ok_or(CatalogError::Conflict)?,
    };
    let (target, name) = save_path(directory, &definition.name, Some(&path))?;
    let mut definition = definition.clone();
    definition.name = name;
    // Validate before moving the current file. The exclusive rename cannot overwrite
    // another file, even if an external editor creates it after the catalog check.
    encode(reference, &definition)?;
    // Preserve the previous contents even if the user has edited them outside Twine.
    atomic_write(
        &archive(directory, source),
        &encode(source, &current.definition)?,
    )?;
    if target != path {
        rename_exclusive(&path, &target)?;
    }
    if let Err(error) = write(directory, &target, reference, &definition, true) {
        if target != path
            && let Err(error) = rename_exclusive(&target, &path)
        {
            tracing::warn!(%error, "could not restore the workflow filename after a failed save");
        }
        return Err(error);
    }
    Ok(reference)
}

pub(super) fn delete(
    directory: &Path,
    reference: WorkflowTypeRef,
    expected: &WorkflowTypeDefinition,
) -> Result<(), CatalogError> {
    let _lock = lock_for_write(directory)?;
    let WorkflowTypeRef::User { type_id, .. } = reference else {
        return Err(CatalogError::BuiltinDeletion);
    };
    let (path, _) = list(directory)?
        .into_iter()
        .find(|(_, value)| {
            matches!(value.reference,
                WorkflowTypeRef::User { type_id: id, .. } if id == type_id)
        })
        .ok_or(CatalogError::NotFound(reference))?;
    let staged = tempfile::Builder::new()
        .prefix(".delete-")
        .tempdir_in(directory)?
        .keep();
    let claimed = staged.join("workflow.toml");
    // Claim the file first. An external editor may replace its old path while
    // history is saved; deletion must only remove the claimed file.
    if let Err(error) = rename_exclusive(&path, &claimed) {
        if fs::symlink_metadata(&claimed).is_ok() {
            restore_deleted_file(&claimed, &path, &staged);
        } else {
            let _ = fs::remove_dir(&staged);
        }
        return Err(error);
    }
    if let Err(error) = delete_claimed_file(directory, &claimed, reference, expected) {
        restore_deleted_file(&claimed, &path, &staged);
        return Err(error);
    }
    fs::remove_dir(staged)?;
    File::open(directory)?.sync_all()?;
    Ok(())
}

fn restore_deleted_file(claimed: &Path, original: &Path, staged: &Path) {
    if let Err(error) = rename_exclusive(claimed, original) {
        tracing::warn!(%error, path = %staged.display(), "could not restore workflow file after failed deletion");
    }
    // This removes an empty directory only; a file that could not be restored stays safe.
    let _ = fs::remove_dir(staged);
}

fn delete_claimed_file(
    directory: &Path,
    claimed: &Path,
    reference: WorkflowTypeRef,
    expected: &WorkflowTypeDefinition,
) -> Result<(), CatalogError> {
    let current = read(claimed)?;
    if current.reference != reference || &current.definition != expected {
        return Err(CatalogError::DeletionConflict);
    }
    atomic_write(
        &archive(directory, reference),
        &encode(reference, &current.definition)?,
    )?;
    fs::remove_file(claimed)?;
    Ok(())
}

fn encode(
    reference: WorkflowTypeRef,
    definition: &WorkflowTypeDefinition,
) -> Result<String, CatalogError> {
    validate(definition).map_err(CatalogError::Invalid)?;
    let WorkflowTypeRef::User { type_id, version } = reference else {
        return Err(CatalogError::FileFormat);
    };
    let contents = toml::to_string_pretty(&WorkflowFile {
        schema_version: if definition.graph.as_ref().is_some_and(|graph| {
            !graph
                .edges
                .iter()
                .any(|edge| edge.from == "task" || edge.to == "finish")
        }) {
            2
        } else {
            1
        },
        id: type_id,
        version,
        definition: definition.clone(),
    })?;
    if contents.len() as u64 > MAX_FILE_BYTES {
        return Err(CatalogError::FileFormat);
    }
    Ok(contents)
}

fn write(
    directory: &Path,
    path: &Path,
    reference: WorkflowTypeRef,
    definition: &WorkflowTypeDefinition,
    replace: bool,
) -> Result<(), CatalogError> {
    let contents = encode(reference, definition)?;
    atomic_write(&archive(directory, reference), &contents)?;
    persist_file(path, &contents, replace).map_err(|error| {
        if error.kind() == io::ErrorKind::AlreadyExists {
            CatalogError::DuplicateName
        } else {
            error.into()
        }
    })?;
    Ok(())
}

fn atomic_write(path: &Path, contents: &str) -> io::Result<()> {
    persist_file(path, contents, true)
}

fn persist_file(path: &Path, contents: &str, replace: bool) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("missing workflow directory"))?;
    fs::create_dir_all(parent)?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    file.write_all(contents.as_bytes())?;
    file.as_file().sync_all()?;
    if replace {
        file.persist(path)
    } else {
        file.persist_noclobber(path)
    }
    .map_err(|error| error.error)?;
    File::open(parent)?.sync_all()
}

fn rename_exclusive(from: &Path, to: &Path) -> Result<(), CatalogError> {
    rustix::fs::renameat_with(
        rustix::fs::CWD,
        from,
        rustix::fs::CWD,
        to,
        rustix::fs::RenameFlags::NOREPLACE,
    )
    .map_err(|error| {
        let error = io::Error::from(error);
        if error.kind() == io::ErrorKind::AlreadyExists {
            CatalogError::DuplicateName
        } else {
            error.into()
        }
    })?;
    if let Some(parent) = from.parent() {
        File::open(parent)?.sync_all()?;
    }
    if to.parent() != from.parent()
        && let Some(parent) = to.parent()
    {
        File::open(parent)?.sync_all()?;
    }
    Ok(())
}

// Commands run off the UI thread. Keep contention waits short and bounded; catalog refreshes
// and migrations keep the nonblocking lock so they can retry on their next refresh.
fn lock_for_write(directory: &Path) -> io::Result<File> {
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        match lock(directory) {
            Err(error)
                if error.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline =>
            {
                std::thread::sleep(Duration::from_millis(10));
            }
            result => return result,
        }
    }
}

fn lock(directory: &Path) -> io::Result<File> {
    fs::create_dir_all(directory)?;
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(directory.join(".catalog.lock"))?;
    // The OS releases the lock when the handle closes, including after a crash.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(file)
}

/// Export legacy definitions once. Historical SQLite versions remain readable for saved runs.
pub(super) fn migrate(store: &Store) -> Result<(), CatalogError> {
    let directory = &store.workflow_directory;
    let legacy: Vec<_> = store
        .latest_workflow_types()?
        .into_iter()
        .filter(|stored| {
            !directory
                .join(".history")
                .join(stored.type_id.to_string())
                .join("sqlite-imported")
                .exists()
        })
        .collect();
    if legacy.is_empty() {
        return Ok(());
    }
    let _lock = match lock(directory) {
        Ok(lock) => lock,
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    for stored in legacy {
        let marker = directory
            .join(".history")
            .join(stored.type_id.to_string())
            .join("sqlite-imported");
        if marker.exists() {
            continue;
        }
        let Ok(workflow_type) = super::catalog::parse(&stored) else {
            continue;
        };
        if !list(directory)?.iter().any(|(_, value)| {
            matches!(value.reference,
            WorkflowTypeRef::User { type_id, .. } if type_id == stored.type_id)
        }) {
            let export = || {
                let (path, name) = save_path(directory, &workflow_type.definition.name, None)?;
                let mut definition = workflow_type.definition;
                definition.name = name;
                write(
                    directory,
                    &path,
                    workflow_type.reference,
                    &definition,
                    false,
                )
            };
            match export() {
                Ok(()) => {}
                Err(error)
                    if matches!(
                        error,
                        CatalogError::DuplicateName | CatalogError::FileFormat
                    ) || matches!(&error, CatalogError::Io(error)
                            if error.raw_os_error() == Some(libc::ENAMETOOLONG)) =>
                {
                    // Duplicate or unusable legacy names must not block the catalog.
                    // SQLite keeps their original versions readable for existing runs.
                    atomic_write(&marker, "retained in SQLite\n")?;
                    continue;
                }
                Err(error) => return Err(error),
            }
        }
        atomic_write(&marker, "imported\n")?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::BuiltinType;

    fn named(name: &str) -> WorkflowTypeDefinition {
        WorkflowTypeDefinition {
            name: name.to_owned(),
            ..BuiltinType::Adversarial.definition()
        }
    }

    #[test]
    fn saves_normalize_names_and_keep_macos_symbols_and_unicode() {
        let directory = tempfile::tempdir().unwrap();
        let reference = create(directory.path(), &named("  Review!   RÉSUMÉ  ")).unwrap();
        let path = directory.path().join("review!_résumé.toml");
        assert_eq!(read(&path).unwrap().reference, reference);
        assert!(matches!(
            create(directory.path(), &named("review! re\u{301}sume\u{301}")),
            Err(CatalogError::DuplicateName)
        ));
    }

    #[test]
    fn only_empty_names_receive_numbered_untitled_files() {
        let directory = tempfile::tempdir().unwrap();
        let first = create(directory.path(), &named("")).unwrap();
        let second = create(directory.path(), &named("   ")).unwrap();
        assert_eq!(
            read(&directory.path().join("untitled.toml"))
                .unwrap()
                .reference,
            first
        );
        let second_file = read(&directory.path().join("untitled-1.toml")).unwrap();
        assert_eq!(second_file.reference, second);
        assert_eq!(second_file.definition.name, "Untitled-1");
        for name in ["Untitled", "UNTITLED-1"] {
            assert!(matches!(
                create(directory.path(), &named(name)),
                Err(CatalogError::DuplicateName)
            ));
        }
        edit(directory.path(), second, &second_file.definition, None).unwrap();
        assert!(directory.path().join("untitled-1.toml").exists());
        assert_eq!(list(directory.path()).unwrap().len(), 2);
    }

    #[test]
    fn duplicate_creates_and_renames_preserve_both_workflows() {
        let directory = tempfile::tempdir().unwrap();
        let first = create(directory.path(), &named("My Workflow")).unwrap();
        let second = create(directory.path(), &named("Other")).unwrap();
        let original = fs::read(directory.path().join("other.toml")).unwrap();
        let duplicate = named("  MY  WORKFLOW  ");
        assert!(matches!(
            create(directory.path(), &duplicate),
            Err(CatalogError::DuplicateName)
        ));
        assert!(matches!(
            edit(directory.path(), second, &duplicate, None),
            Err(CatalogError::DuplicateName)
        ));
        assert_eq!(
            fs::read(directory.path().join("other.toml")).unwrap(),
            original
        );
        assert_eq!(
            read(&directory.path().join("my_workflow.toml"))
                .unwrap()
                .reference,
            first
        );
        let updated = edit(directory.path(), first, &named("My Workflow"), None).unwrap();
        assert_ne!(updated, first);
        assert_eq!(list(directory.path()).unwrap().len(), 2);
    }

    #[test]
    fn renaming_a_moved_workflow_keeps_identity_and_previous_versions() {
        let directory = tempfile::tempdir().unwrap();
        let original = named("First");
        let reference = create(directory.path(), &original).unwrap();
        let moved = directory.path().join("workflow-123.toml");
        fs::rename(directory.path().join("first.toml"), &moved).unwrap();
        let updated = edit(
            directory.path(),
            reference,
            &named("New Name!"),
            Some(&original),
        )
        .unwrap();
        assert!(!moved.exists());
        assert_eq!(
            read(&directory.path().join("new_name!.toml"))
                .unwrap()
                .reference,
            updated
        );
        assert_eq!(
            get(directory.path(), reference)
                .unwrap()
                .unwrap()
                .definition,
            original
        );
        assert_eq!(list(directory.path()).unwrap().len(), 1);
    }

    #[test]
    fn edits_normalize_case_and_unicode_aliases_of_the_current_filename() {
        for (name, canonical, alias) in [
            ("Review", "review.toml", "Review.toml"),
            ("Résumé", "résumé.toml", "re\u{301}sume\u{301}.toml"),
        ] {
            let directory = tempfile::tempdir().unwrap();
            let mut definition = named(name);
            let reference = create(directory.path(), &definition).unwrap();
            fs::rename(
                directory.path().join(canonical),
                directory.path().join(alias),
            )
            .unwrap();
            definition.description.push_str(" Updated.");
            let updated = edit(directory.path(), reference, &definition, None).unwrap();
            let workflows = list(directory.path()).unwrap();
            assert_eq!(workflows.len(), 1);
            assert_eq!(workflows[0].1.reference, updated);
            assert_eq!(workflows[0].1.definition, definition);
            assert_eq!(workflows[0].0.file_name().unwrap(), canonical);
        }
    }

    #[test]
    fn failed_save_restores_the_previous_filename_and_contents() {
        let directory = tempfile::tempdir().unwrap();
        let reference = create(directory.path(), &named("Original")).unwrap();
        let path = directory.path().join("original.toml");
        let contents = fs::read(&path).unwrap();
        let mut updated = named("Renamed");
        updated.description = "x".repeat(usize::try_from(MAX_FILE_BYTES).unwrap());
        assert!(matches!(
            edit(directory.path(), reference, &updated, None),
            Err(CatalogError::FileFormat)
        ));
        assert_eq!(fs::read(path).unwrap(), contents);
        assert!(!directory.path().join("renamed.toml").exists());
        assert_eq!(list(directory.path()).unwrap().len(), 1);
    }

    #[test]
    fn occupied_filenames_and_symlinks_are_never_overwritten() {
        let directory = tempfile::tempdir().unwrap();
        let occupied = directory.path().join("Occupied.toml");
        fs::write(&occupied, "external data").unwrap();
        assert!(matches!(
            create(directory.path(), &named("occupied")),
            Err(CatalogError::DuplicateName)
        ));
        assert_eq!(fs::read_to_string(occupied).unwrap(), "external data");
        std::os::unix::fs::symlink("missing", directory.path().join("link.toml")).unwrap();
        assert!(matches!(
            create(directory.path(), &named("Link")),
            Err(CatalogError::DuplicateName)
        ));
        assert_eq!(
            fs::read_link(directory.path().join("link.toml")).unwrap(),
            Path::new("missing")
        );
    }

    #[test]
    fn deleting_a_claimed_file_keeps_an_external_replacement_at_its_old_path() {
        let directory = tempfile::tempdir().unwrap();
        let original = named("External delete");
        let reference = create(directory.path(), &original).unwrap();
        let path = list(directory.path()).unwrap()[0].0.clone();
        let staged = tempfile::tempdir_in(directory.path()).unwrap();
        let claimed = staged.path().join("workflow.toml");
        rename_exclusive(&path, &claimed).unwrap();
        let WorkflowTypeRef::User { type_id, .. } = reference else {
            unreachable!()
        };
        let replacement_ref = WorkflowTypeRef::User {
            type_id,
            version: 2,
        };
        let mut replacement = original.clone();
        replacement.description.push_str(" External replacement.");
        atomic_write(&path, &encode(replacement_ref, &replacement).unwrap()).unwrap();

        delete_claimed_file(directory.path(), &claimed, reference, &original).unwrap();

        assert_eq!(read(&path).unwrap().definition, replacement);
        assert_eq!(
            get(directory.path(), reference)
                .unwrap()
                .unwrap()
                .definition,
            original
        );
        assert!(!claimed.exists());
    }

    #[test]
    fn failed_deletion_restores_the_live_file_when_history_cannot_be_written() {
        let directory = tempfile::tempdir().unwrap();
        let definition = named("Keep on failure");
        let reference = create(directory.path(), &definition).unwrap();
        let history = archive(directory.path(), reference);
        fs::remove_file(&history).unwrap();
        fs::create_dir(&history).unwrap();
        assert!(delete(directory.path(), reference, &definition).is_err());
        let workflow = read(&directory.path().join("keep_on_failure.toml")).unwrap();
        assert_eq!(workflow.reference, reference);
        assert_eq!(workflow.definition, definition);
        assert_eq!(list(directory.path()).unwrap().len(), 1);
    }

    #[test]
    fn a_save_waits_for_another_catalog_write_and_keeps_both_files() {
        let directory = tempfile::tempdir().unwrap();
        let first = create(directory.path(), &BuiltinType::Adversarial.definition()).unwrap();
        let held = lock(directory.path()).unwrap();
        let (started, waiting) = std::sync::mpsc::channel();
        let (finished, result) = std::sync::mpsc::channel();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                started.send(()).unwrap();
                finished
                    .send(create(
                        directory.path(),
                        &BuiltinType::Coordinator.definition(),
                    ))
                    .unwrap();
            });
            waiting.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(matches!(
                result.recv_timeout(Duration::from_millis(50)),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout)
            ));
            drop(held);
            let second = result
                .recv_timeout(Duration::from_secs(2))
                .unwrap()
                .unwrap();
            assert_ne!(first, second);
        });
        assert_eq!(list(directory.path()).unwrap().len(), 2);
        assert!(get(directory.path(), first).unwrap().is_some());
    }

    #[test]
    fn optional_agent_settings_and_colors_survive_file_edits() {
        use crate::{AgentColor, AgentDefaults, HarnessId};
        let directory = tempfile::tempdir().unwrap();
        let mut definition = BuiltinType::Adversarial.definition();
        for role in &mut definition.roles {
            role.color = None;
        }
        let reference = create(directory.path(), &definition).unwrap();
        let old = get(directory.path(), reference)
            .unwrap()
            .unwrap()
            .definition;
        assert!(
            old.roles
                .iter()
                .all(|role| role.color.is_none() && role.agent_defaults.is_none())
        );
        definition.roles[0].color = Some(AgentColor::Purple);
        definition.roles[0].agent_defaults = Some(AgentDefaults {
            harness: HarnessId::ClaudeCode,
            model: Some("sonnet".into()),
            effort: Some("high".into()),
            yolo: false,
        });
        let updated = edit(directory.path(), reference, &definition, Some(&old)).unwrap();
        assert_eq!(
            get(directory.path(), updated).unwrap().unwrap().definition,
            definition
        );
        assert_eq!(
            get(directory.path(), reference)
                .unwrap()
                .unwrap()
                .definition,
            old
        );
        definition.roles[0].agent_defaults.as_mut().unwrap().model = Some("--invalid".into());
        assert!(matches!(
            create(directory.path(), &definition),
            Err(CatalogError::Invalid(_))
        ));
    }

    #[test]
    fn workflow_files_can_move_and_edits_reject_stale_content() {
        let directory = tempfile::tempdir().unwrap();
        let definition = BuiltinType::Adversarial.definition();
        let reference = create(directory.path(), &definition).unwrap();
        let (path, _) = list(directory.path()).unwrap().remove(0);
        let renamed = directory.path().join("shared-review.toml");
        fs::rename(path, &renamed).unwrap();
        assert_eq!(
            get(directory.path(), reference)
                .unwrap()
                .unwrap()
                .definition,
            definition
        );
        let mut contents = fs::read_to_string(&renamed).unwrap();
        contents = contents.replace("name = \"Adversarial\"", "name = \"External edit\"");
        fs::write(&renamed, &contents).unwrap();
        assert!(matches!(
            edit(directory.path(), reference, &definition, Some(&definition)),
            Err(CatalogError::Conflict)
        ));
        assert_eq!(fs::read_to_string(renamed).unwrap(), contents);
    }

    #[test]
    fn legacy_sqlite_types_export_once_and_deleted_files_stay_deleted() {
        let mut store = Store::open_in_memory().unwrap();
        let definition = BuiltinType::Adversarial.definition();
        let id = store
            .create_workflow_type(&toml::to_string(&definition).unwrap(), 0)
            .unwrap();
        migrate(&store).unwrap();
        let (path, workflow_type) = list(&store.workflow_directory).unwrap().remove(0);
        assert_eq!(
            workflow_type.reference,
            WorkflowTypeRef::User {
                type_id: id,
                version: 1
            }
        );
        fs::remove_file(path).unwrap();
        migrate(&store).unwrap();
        assert_eq!(list(&store.workflow_directory).unwrap(), []);
    }

    #[test]
    fn duplicate_legacy_names_do_not_block_loading_or_overwrite_files() {
        let mut store = Store::open_in_memory().unwrap();
        let definition = named("Legacy review");
        let contents = toml::to_string(&definition).unwrap();
        let first = store.create_workflow_type(&contents, 0).unwrap();
        let second = store.create_workflow_type(&contents, 0).unwrap();
        migrate(&store).unwrap();
        let workflows = list(&store.workflow_directory).unwrap();
        assert_eq!(workflows.len(), 1);
        assert_eq!(workflows[0].0.file_name().unwrap(), "legacy_review.toml");
        assert_eq!(
            workflows[0].1.reference,
            WorkflowTypeRef::User {
                type_id: first,
                version: 1
            }
        );
        assert!(store.workflow_type_version(second, 1).unwrap().is_some());
        fs::remove_file(&workflows[0].0).unwrap();
        migrate(&store).unwrap();
        assert_eq!(list(&store.workflow_directory).unwrap(), []);
    }

    #[test]
    fn unusable_legacy_names_do_not_block_other_workflows_or_saved_runs() {
        let mut store = Store::open_in_memory().unwrap();
        let mut references = Vec::new();
        for name in ["/:".to_owned(), "x".repeat(300), "Valid legacy".to_owned()] {
            let definition = named(&name);
            let type_id = store
                .create_workflow_type(&toml::to_string(&definition).unwrap(), 0)
                .unwrap();
            references.push((
                WorkflowTypeRef::User {
                    type_id,
                    version: 1,
                },
                definition,
            ));
        }
        let catalog = super::super::WorkflowCatalog::new(&mut store);
        let workflows = catalog.list().unwrap();
        assert_eq!(workflows.len(), BuiltinType::ALL.len() + 1);
        assert_eq!(workflows.last().unwrap().definition.name, "Valid legacy");
        for (reference, definition) in references {
            assert_eq!(catalog.get(reference).unwrap().definition, definition);
        }
        assert_eq!(catalog.list().unwrap(), workflows);
    }

    #[test]
    fn bad_or_future_files_do_not_hide_valid_files() {
        let directory = tempfile::tempdir().unwrap();
        let reference = create(directory.path(), &BuiltinType::Adversarial.definition()).unwrap();
        fs::write(directory.path().join("bad.toml"), "invalid").unwrap();
        let valid = fs::read_to_string(&list(directory.path()).unwrap()[0].0).unwrap();
        fs::write(
            directory.path().join("future.toml"),
            valid.replace("schema_version = 1", "schema_version = 99"),
        )
        .unwrap();
        assert_eq!(list(directory.path()).unwrap().len(), 1);
        assert_eq!(
            get(directory.path(), reference).unwrap().unwrap().reference,
            reference
        );
    }
}
