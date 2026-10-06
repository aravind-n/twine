//! Versioned settings-file access, independent of an open folder or application runtime.

use std::fs;
use std::path::{Path, PathBuf};

use thiserror::Error;
use toml::de::DeTable;

use super::{Config, ConfigDiagnostic, ConfigProblem, default_source, publish_default};
use crate::files::{self, FileError, FilePreview, FileSaveOutcome, FileSaveRequest};

#[derive(Debug, Error)]
pub enum ConfigEditError {
    #[error("Cannot find the user config directory.")]
    MissingDirectory,
    #[error("Could not open the config file: {0}")]
    Open(String),
    #[error("The settings editor can only save the user config file.")]
    InvalidPath,
    #[error("Cannot apply settings: {0}")]
    InvalidConfig(ConfigDiagnostic),
    #[error(transparent)]
    Save(#[from] FileError),
}

/// Opens the user's actual source, including comments and invalid TOML, creating defaults if absent.
///
/// # Errors
/// Returns an error if the user config directory cannot be found or the starter file cannot be created.
pub fn read_user_file() -> Result<FilePreview, ConfigEditError> {
    read_file(&Config::user_path().ok_or(ConfigEditError::MissingDirectory)?)
}

/// Saves only the user config file, preserving the file editor's version and conflict semantics.
///
/// # Errors
/// Returns an error for a different path, an unavailable config directory, or a failed file save.
pub fn save_user_file(request: &FileSaveRequest) -> Result<FileSaveOutcome, ConfigEditError> {
    save_file(
        &Config::user_path().ok_or(ConfigEditError::MissingDirectory)?,
        request,
    )
}

/// Saves an automatic-install choice made in the host's update UI without losing comments.
/// The root config overrides imported policy. Reject a stale choice if the accepted policy changed;
/// concurrent file edits retain the existing version-conflict protection.
///
/// # Errors
/// Returns an error if the config is unavailable, invalid, or cannot be saved.
pub fn set_user_automatic_updates(
    enabled: bool,
    expected_previous: bool,
) -> Result<FileSaveOutcome, ConfigEditError> {
    set_automatic_updates(
        &Config::user_path().ok_or(ConfigEditError::MissingDirectory)?,
        enabled,
        expected_previous,
    )
}

fn set_automatic_updates(
    path: &Path,
    enabled: bool,
    expected_previous: bool,
) -> Result<FileSaveOutcome, ConfigEditError> {
    let file = read_file(path)?;
    let files::FileContent::Text(source) = &file.content else {
        return Err(ConfigEditError::Open(
            "The config file is not editable text.".into(),
        ));
    };
    let loaded = Config::load_source(&file.path, source);
    if let Some(diagnostic) = loaded
        .diagnostics
        .into_iter()
        .find(|diagnostic| diagnostic.problem != ConfigProblem::UnknownKey)
    {
        return Err(ConfigEditError::InvalidConfig(diagnostic));
    }
    if loaded.config.updates.automatically_install != expected_previous {
        return Ok(FileSaveOutcome::Conflict(file));
    }
    let text = update_install_source(source, enabled)?;
    let request = FileSaveRequest {
        folder: file
            .path
            .parent()
            .ok_or(ConfigEditError::InvalidPath)?
            .to_owned(),
        path: file.path,
        text,
        expected_version: file
            .version
            .ok_or_else(|| ConfigEditError::Open("The config file has no version.".into()))?,
        overwrite: false,
    };
    save_file(path, &request)
}

/// Edit parser-provided source spans so comments and ignored values survive byte for byte.
/// In particular, ignored integers need not fit the signed integer type used by TOML serializers.
fn update_install_source(source: &str, enabled: bool) -> Result<String, ConfigEditError> {
    let document = DeTable::parse(source)
        .map_err(|_| ConfigEditError::Open("The config file has invalid TOML.".into()))?;
    let updates = document.get_ref().get("updates");
    let mut text = source.to_owned();
    if let Some(value) = updates.and_then(|value| value.get_ref().get("automatically_install")) {
        text.replace_range(value.span(), if enabled { "true" } else { "false" });
    } else if let Some(updates) = updates {
        let span = updates.span();
        match source.as_bytes().get(span.start) {
            Some(b'{') => {
                let empty = updates.get_ref().as_table().is_some_and(DeTable::is_empty);
                text.insert_str(
                    span.start + 1,
                    &format!(
                        " automatically_install = {enabled}{}",
                        if empty { " " } else { "," }
                    ),
                );
            }
            Some(b'[') => {
                // Explicit-table spans cover the header. Insert after its comment, if any.
                let end = source[span.end..]
                    .find('\n')
                    .map(|offset| span.end + offset + 1);
                let newline = if source.contains("\r\n") {
                    "\r\n"
                } else {
                    "\n"
                };
                if let Some(end) = end {
                    text.insert_str(end, &format!("automatically_install = {enabled}{newline}"));
                } else {
                    text.insert_str(
                        source.len(),
                        &format!("{newline}automatically_install = {enabled}{newline}"),
                    );
                }
            }
            _ => text.insert_str(0, &format!("updates.automatically_install = {enabled}\n")),
        }
    } else {
        text.insert_str(0, &format!("updates.automatically_install = {enabled}\n"));
    }
    Ok(text)
}

fn editor_path(path: &Path) -> Result<PathBuf, ConfigEditError> {
    // Config directories can be symlinks (including /tmp on macOS). Pin their resolved path,
    // while the file access layer still rejects a symlink in place of config.toml itself.
    let parent = path.parent().ok_or(ConfigEditError::InvalidPath)?;
    let directory =
        fs::canonicalize(parent).map_err(|error| ConfigEditError::Open(error.to_string()))?;
    Ok(directory.join(path.file_name().ok_or(ConfigEditError::InvalidPath)?))
}

fn read_file(path: &Path) -> Result<FilePreview, ConfigEditError> {
    let parent = path.parent().ok_or(ConfigEditError::InvalidPath)?;
    fs::create_dir_all(parent).map_err(|error| ConfigEditError::Open(error.to_string()))?;
    let path = editor_path(path)?;
    let parent = path.parent().ok_or(ConfigEditError::InvalidPath)?;
    let preview = files::read_preview(parent, &path);
    if preview.content != files::FileContent::Missing {
        return Ok(preview);
    }
    let source = default_source().map_err(|error| ConfigEditError::Open(error.to_string()))?;
    publish_default(&path, &source).map_err(|error| ConfigEditError::Open(error.to_string()))?;
    Ok(files::read_preview(parent, &path))
}

fn save_file(path: &Path, request: &FileSaveRequest) -> Result<FileSaveOutcome, ConfigEditError> {
    let path = editor_path(path)?;
    if request.path != path || Some(request.folder.as_path()) != path.parent() {
        return Err(ConfigEditError::InvalidPath);
    }
    let loaded = Config::load_source(&path, &request.text);
    if let Some(diagnostic) = loaded
        .diagnostics
        .into_iter()
        .find(|diagnostic| diagnostic.problem != ConfigProblem::UnknownKey)
    {
        return Err(ConfigEditError::InvalidConfig(diagnostic));
    }
    Ok(files::save(request)?)
}

#[cfg(test)]
mod tests {
    use std::os::unix::ffi::OsStrExt;

    use super::*;
    use crate::files::FileContent;

    #[test]
    fn update_choices_preserve_comments_imports_and_other_policy() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        fs::write(
            directory.path().join("policy.toml"),
            "[updates]\nchannel = 'nightly'\n",
        )
        .unwrap();
        for source in [
            "# keep me\nimport = 'policy.toml'\n[terminal]\nfont_size = 18 # size\n",
            "# keep me\nimport = 'policy.toml'\n[updates]\nautomatically_check = false\nautomatically_install = false # choice\n",
            "import = 'policy.toml'\nupdates = { automatically_install = false, automatically_check = false } # keep me\n",
            "# keep me\nimport = 'policy.toml'\nupdates.automatically_install = false\n",
            "# keep me\nimport = 'policy.toml'\nupdates.automatically_check = true\n",
            "# keep me\nimport = 'policy.toml'\n[updates] # header comment",
            "# keep me\r\nimport = 'policy.toml'\r\n[updates] # header\r\n[terminal]\r\nfont_size = 18\r\n",
            "import = 'policy.toml'\nupdates = {} # keep me\n",
            "import = 'policy.toml'\nupdates = {channel = 'nightly',} # keep me\n",
            "import = 'policy.toml'\n[updates.future] # keep me\nvalue = 1\n",
        ] {
            fs::write(&path, source).unwrap();
            assert!(matches!(
                set_automatic_updates(&path, true, false).unwrap(),
                FileSaveOutcome::Saved(_)
            ));
            let saved = fs::read_to_string(&path).unwrap();
            assert!(saved.contains("# keep me"));
            assert!(saved.contains("import = 'policy.toml'"));
            if source.contains("# choice") {
                assert!(saved.contains("true # choice"));
            }
            let loaded = Config::load(&path);
            assert!(
                loaded
                    .diagnostics
                    .iter()
                    .all(|diagnostic| diagnostic.problem == ConfigProblem::UnknownKey)
            );
            assert!(loaded.config.updates.automatically_install);
            assert_eq!(
                loaded.config.updates.channel,
                super::super::UpdateChannel::Nightly
            );
            assert!(matches!(
                set_automatic_updates(&path, false, true).unwrap(),
                FileSaveOutcome::Saved(_)
            ));
            assert!(!Config::load(&path).config.updates.automatically_install);
        }
    }

    #[test]
    fn update_choices_preserve_oversized_unknown_integers() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let original = "extra = 9223372036854775808\nterminal.font_size = 18\n";
        fs::write(&path, original).unwrap();
        for (enabled, previous) in [(true, false), (false, true)] {
            assert!(matches!(
                set_automatic_updates(&path, enabled, previous).unwrap(),
                FileSaveOutcome::Saved(_)
            ));
            assert!(fs::read_to_string(&path).unwrap().ends_with(original));
            assert_eq!(Config::load(&path).config.terminal.font_size.points(), 18.0);
            assert_eq!(
                Config::load(&path).config.updates.automatically_install,
                enabled
            );
        }
    }

    #[test]
    fn stale_update_choices_preserve_newer_config_policy() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let source = "updates.automatically_install = true\n";
        fs::write(&path, source).unwrap();
        assert!(matches!(
            set_automatic_updates(&path, false, false).unwrap(),
            FileSaveOutcome::Conflict(_)
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), source);
    }

    #[test]
    fn invalid_update_choices_never_replace_the_config() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        for source in [
            "invalid = @\n",
            "updates.channel = 'beta'\n",
            "updates = 42\n",
        ] {
            fs::write(&path, source).unwrap();
            assert!(set_automatic_updates(&path, true, false).is_err());
            assert_eq!(fs::read_to_string(&path).unwrap(), source);
        }
    }

    #[test]
    fn invalid_drafts_preserve_the_saved_file_including_import_validation() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let file = read_file(&path).unwrap();
        let original = fs::read_to_string(&path).unwrap();
        let mut request = FileSaveRequest {
            folder: file.path.parent().unwrap().to_owned(),
            path: file.path,
            text: String::new(),
            expected_version: file.version.unwrap(),
            overwrite: false,
        };
        for source in [
            "terminal.font_size = 100\n",
            "terminal.colors.blue = '#invalid'\n",
            "import = 'missing.toml'\n",
            "invalid = @\n",
        ] {
            request.text = source.into();
            assert!(matches!(
                save_file(&path, &request),
                Err(ConfigEditError::InvalidConfig(_))
            ));
            assert_eq!(fs::read_to_string(&path).unwrap(), original);
        }
    }

    #[test]
    fn deleted_config_reports_a_conflict_and_can_be_recreated() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let file = read_file(&path).unwrap();
        let mut request = FileSaveRequest {
            folder: file.path.parent().unwrap().to_owned(),
            path: file.path,
            text: "terminal.font_size = 18\n".into(),
            expected_version: file.version.unwrap(),
            overwrite: false,
        };
        fs::remove_file(&path).unwrap();
        let FileSaveOutcome::Conflict(conflict) = save_file(&path, &request).unwrap() else {
            panic!("expected conflict")
        };
        assert_eq!(conflict.content, FileContent::Missing);
        assert!(!path.exists());
        request.overwrite = true;
        assert!(matches!(
            save_file(&path, &request).unwrap(),
            FileSaveOutcome::Saved(_)
        ));
        assert_eq!(fs::read_to_string(path).unwrap(), request.text);
    }

    #[test]
    fn existing_files_use_bounded_preview_and_reject_links_and_special_files() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        fs::File::create(&path)
            .unwrap()
            .set_len(files::TEXT_LIMIT + 1)
            .unwrap();
        assert_eq!(read_file(&path).unwrap().content, FileContent::TooLarge);
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(directory.path().join("target"), &path).unwrap();
        assert_ne!(read_file(&path).unwrap().content, FileContent::Missing);
        assert!(!directory.path().join("target").exists());
        fs::remove_file(&path).unwrap();
        let fifo = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
        // SAFETY: The NUL-terminated path lives through this call; mkfifo retains no pointers.
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        assert_eq!(read_file(&path).unwrap().content, FileContent::Unsupported);
    }

    #[test]
    fn editor_resolves_symlinked_config_directories_for_reads_and_saves() {
        let directory = tempfile::tempdir().unwrap();
        let real = directory.path().join("real");
        fs::create_dir(&real).unwrap();
        let alias = directory.path().join("alias");
        std::os::unix::fs::symlink(&real, &alias).unwrap();
        let path = alias.join("config.toml");
        let file = read_file(&path).unwrap();
        let request = FileSaveRequest {
            folder: file.path.parent().unwrap().to_owned(),
            path: file.path.clone(),
            text: "# edited\n".into(),
            expected_version: file.version.unwrap(),
            overwrite: false,
        };
        assert!(matches!(
            save_file(&path, &request).unwrap(),
            FileSaveOutcome::Saved(_)
        ));
        assert_eq!(
            fs::read_to_string(real.join("config.toml")).unwrap(),
            "# edited\n"
        );
    }

    #[test]
    fn editor_creates_defaults_and_preserves_invalid_source() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("twine/config.toml");
        let file = read_file(&path).unwrap();
        let FileContent::Text(source) = file.content else {
            panic!("expected text")
        };
        assert!(source.contains("# brblue ="));
        fs::write(&path, "# Keep my comments\ninvalid = @\n").unwrap();
        assert_eq!(
            read_file(&path).unwrap().content,
            FileContent::Text("# Keep my comments\ninvalid = @\n".into())
        );
    }

    #[test]
    fn saves_config_without_a_folder_and_detects_external_changes() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let file = read_file(&path).unwrap();
        let mut request = FileSaveRequest {
            folder: file.path.parent().unwrap().to_owned(),
            path: file.path.clone(),
            text: "terminal.font_size = 18\n".into(),
            expected_version: file.version.unwrap(),
            overwrite: false,
        };
        let FileSaveOutcome::Saved(saved) = save_file(&path, &request).unwrap() else {
            panic!("expected saved")
        };
        assert_eq!(Config::load(&path).config.terminal.font_size.points(), 18.0);
        request.expected_version = saved.version.unwrap();
        fs::write(&path, "# external\n").unwrap();
        assert!(matches!(
            save_file(&path, &request).unwrap(),
            FileSaveOutcome::Conflict(_)
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "# external\n");
        request.overwrite = true;
        assert!(matches!(
            save_file(&path, &request).unwrap(),
            FileSaveOutcome::Saved(_)
        ));
        request.path = request.folder.join("other.toml");
        assert!(matches!(
            save_file(&path, &request),
            Err(ConfigEditError::InvalidPath)
        ));
        assert!(!request.path.exists());
    }
}
