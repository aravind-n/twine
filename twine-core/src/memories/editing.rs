use super::{MemoryError, MemoryRequest, discovery};
use crate::{FileSaveOutcome, FileSaveRequest, FileVersion};

/// Save an explicitly selected Markdown source using its last-read disk version.
///
/// # Errors
/// Rejects undiscovered sources, non-Markdown resources, and unsafe or failed file writes.
pub fn save(
    request: &MemoryRequest,
    text: String,
    expected_version: FileVersion,
    overwrite: bool,
) -> Result<FileSaveOutcome, MemoryError> {
    let id = request
        .source_id
        .as_ref()
        .ok_or(MemoryError::MissingSource)?;
    let (entries, _) = discovery::discover(request)?;
    let entry = entries
        .into_iter()
        .find(|entry| &entry.source.id == id)
        .ok_or(MemoryError::MissingSource)?;
    let discovery::Backing::File { root, path } = entry.backing else {
        return Err(MemoryError::UnsupportedEdit);
    };
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    if !extension.eq_ignore_ascii_case("md") && !extension.eq_ignore_ascii_case("markdown") {
        return Err(MemoryError::UnsupportedEdit);
    }
    Ok(crate::files::save(&FileSaveRequest {
        folder: root,
        path,
        text,
        expected_version,
        overwrite,
    })?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::FileContent;
    use std::fs;

    #[test]
    fn markdown_edits_preserve_external_changes_until_explicit_overwrite() {
        let fixture = tempfile::tempdir().unwrap();
        let root = fixture.path().join("home/.codex/memories");
        fs::create_dir_all(&root).unwrap();
        let path = root.join("MEMORY.md");
        fs::write(&path, "# Original\n").unwrap();
        let mut request = MemoryRequest {
            examples_root: Some(fixture.path().to_owned()),
            ..MemoryRequest::default()
        };
        request.source_id = Some(
            super::super::catalog(&request)
                .unwrap()
                .sources
                .into_iter()
                .find(|source| source.location == path.display().to_string())
                .unwrap()
                .id,
        );
        let original = super::super::read(&request).unwrap().file.unwrap();
        let FileSaveOutcome::Saved(saved) = save(
            &request,
            "# Edited\n".into(),
            original.version.unwrap(),
            false,
        )
        .unwrap() else {
            panic!("expected a saved file");
        };
        assert_eq!(saved.content, FileContent::Text("# Edited\n".into()));
        let version = saved.version.unwrap();
        fs::write(&path, "# Harness update\n").unwrap();
        assert!(matches!(
            save(&request, "# My edit\n".into(), version.clone(), false).unwrap(),
            FileSaveOutcome::Conflict(_)
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "# Harness update\n");
        assert!(matches!(
            save(&request, "# My edit\n".into(), version, true).unwrap(),
            FileSaveOutcome::Saved(_)
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "# My edit\n");
    }

    #[test]
    fn edits_reject_settings_non_markdown_files_and_replaced_symlinks() {
        let fixture = tempfile::tempdir().unwrap();
        let root = fixture.path().join("home/.claude/agent-memory/helper");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("data.json"), "{}").unwrap();
        let path = root.join("MEMORY.md");
        fs::write(&path, "original").unwrap();
        let mut request = MemoryRequest {
            examples_root: Some(fixture.path().to_owned()),
            ..MemoryRequest::default()
        };
        let catalog = super::super::catalog(&request).unwrap();
        for source in catalog.sources.iter().filter(|source| {
            source.example
                && (source.title == "data.json"
                    || source.kind == super::super::MemoryKind::Configuration)
        }) {
            request.source_id = Some(source.id.clone());
            assert!(matches!(
                save(
                    &request,
                    "edit".into(),
                    FileVersion {
                        fingerprint: "unused".into(),
                        utf8_bom: false
                    },
                    true
                ),
                Err(MemoryError::UnsupportedEdit)
            ));
        }
        request.source_id = Some(
            catalog
                .sources
                .into_iter()
                .find(|source| source.location == path.display().to_string())
                .unwrap()
                .id,
        );
        let version = super::super::read(&request)
            .unwrap()
            .file
            .unwrap()
            .version
            .unwrap();
        let outside = fixture.path().join("outside.md");
        fs::write(&outside, "untouched").unwrap();
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&outside, &path).unwrap();
        assert!(save(&request, "edit".into(), version, true).is_err());
        assert_eq!(fs::read_to_string(outside).unwrap(), "untouched");
    }
}
