//! Discovery of local harness memories, instructions, and extraction records.
//! Database reads use private snapshots; explicit edits are limited to Markdown files.
mod database;
mod discovery;
mod editing;
mod locations;

pub use editing::save;

use crate::FileContent;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use thiserror::Error;

pub const SOURCE_LIMIT: usize = 1_024;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MemoryRequest {
    pub folder: Option<PathBuf>,
    pub source_id: Option<String>,
    pub examples_root: Option<PathBuf>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MemoryHarness {
    Codex,
    ClaudeCode,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MemoryScope {
    Global,
    Folder,
    OtherFolder,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MemoryKind {
    Summary,
    Durable,
    RawMemory,
    RolloutSummary,
    Instructions,
    Rule,
    AgentMemory,
    Skill,
    Extension,
    Artifact,
    StoreStatus,
    Configuration,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemorySource {
    pub id: String,
    pub title: String,
    pub harness: MemoryHarness,
    pub scope: MemoryScope,
    pub kind: MemoryKind,
    pub location: String,
    pub group: String,
    pub format: String,
    pub modified_at: Option<u64>,
    pub example: bool,
    pub association: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryCatalog {
    pub sources: Vec<MemorySource>,
    pub diagnostics: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryRead {
    pub source: MemorySource,
    pub text: Option<String>,
    pub message: Option<String>,
    #[serde(skip)]
    pub file: Option<crate::FilePreview>,
}

#[derive(Debug, Error)]
pub enum MemoryError {
    #[error("Memory discovery requires absolute folder paths.")]
    InvalidPath,
    #[error("The source is no longer available. Refresh the source list.")]
    MissingSource,
    #[error("Only local Markdown files can be edited from Memories.")]
    UnsupportedEdit,
    #[error(transparent)]
    File(#[from] crate::FileError),
}

/// Lists bounded local sources without generating or editing memory.
///
/// # Errors
/// Returns an error when a requested folder or example root is not absolute.
pub fn catalog(request: &MemoryRequest) -> Result<MemoryCatalog, MemoryError> {
    let (sources, diagnostics) = discovery::discover(request)?;
    Ok(MemoryCatalog {
        sources: sources.into_iter().map(|e| e.source).collect(),
        diagnostics,
    })
}

/// Reads a source by a discovered opaque ID.
///
/// # Errors
/// Returns an error for invalid paths or a source that is no longer discoverable.
pub fn read(request: &MemoryRequest) -> Result<MemoryRead, MemoryError> {
    let id = request
        .source_id
        .as_ref()
        .ok_or(MemoryError::MissingSource)?;
    let (entries, _) = discovery::discover(request)?;
    let entry = entries
        .into_iter()
        .find(|e| &e.source.id == id)
        .ok_or(MemoryError::MissingSource)?;
    let mut file = None;
    let content = match entry.backing {
        discovery::Backing::File { root, path } => {
            let preview = crate::files::read_preview(&root, &path);
            let content = preview.content.clone();
            file = Some(preview);
            content
        }
        discovery::Backing::Text(text) => FileContent::Text(text),
        discovery::Backing::Database {
            root,
            path,
            thread,
            column,
        } => database::read_record(&root, &path, &thread, &column),
    };
    let (text, message) = match content {
        FileContent::Text(text) => (Some(text), None),
        FileContent::Binary => (
            None,
            Some("This source is binary, rather than UTF-8 text.".into()),
        ),
        FileContent::TooLarge => (
            None,
            Some("This source exceeds the 2 MiB reading limit.".into()),
        ),
        FileContent::Missing => (
            None,
            Some("This source was removed. Refresh the list.".into()),
        ),
        FileContent::Unsupported => (
            None,
            Some("Symbolic links and special files cannot be read.".into()),
        ),
        FileContent::Unavailable(message) => (None, Some(message)),
    };
    Ok(MemoryRead {
        source: entry.source,
        text,
        message,
        file,
    })
}
