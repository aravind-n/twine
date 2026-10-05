use std::path::PathBuf;

use serde::Deserialize;
use serde_json::{Value, json};
use twine_core::{
    FileContent, FileKind, FilePreview, FileSaveOutcome, FileSaveRequest, FileSnapshot,
    FileVersion, TEXT_LIMIT,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SaveRequest {
    folder: PathBuf,
    path: PathBuf,
    text: String,
    expected_version: Version,
    overwrite: bool,
}

#[derive(Deserialize)]
struct Version {
    fingerprint: String,
    #[serde(rename = "utf8BOM")]
    utf8_bom: bool,
}

impl From<SaveRequest> for FileSaveRequest {
    fn from(request: SaveRequest) -> Self {
        Self {
            folder: request.folder,
            path: request.path,
            text: request.text,
            expected_version: FileVersion {
                fingerprint: request.expected_version.fingerprint,
                utf8_bom: request.expected_version.utf8_bom,
            },
            overwrite: request.overwrite,
        }
    }
}

pub(crate) fn encode_save<E: std::fmt::Display>(
    result: Result<FileSaveOutcome, E>,
) -> Result<Vec<u8>, serde_json::Error> {
    let value = match result {
        Ok(FileSaveOutcome::Saved(file)) => {
            json!({ "status": "saved", "file": encode_preview(&file) })
        }
        Ok(FileSaveOutcome::Conflict(file)) => {
            json!({ "status": "conflict", "file": encode_preview(&file) })
        }
        Err(error) => json!({ "status": "failed", "message": error.to_string() }),
    };
    serde_json::to_vec(&value)
}

pub(crate) fn encode_preview(file: &FilePreview) -> Value {
    let (status, text, message) = match &file.content {
        FileContent::Text(text) => ("text", Some(text.as_str()), None),
        FileContent::Binary => ("binary", None, None),
        FileContent::TooLarge => ("tooLarge", None, None),
        FileContent::Missing => ("missing", None, None),
        FileContent::Unsupported => ("unsupported", None, None),
        FileContent::Unavailable(message) => ("unavailable", None, Some(message.as_str())),
    };
    let version = file.version.as_ref().map(|version| {
        json!({
            "fingerprint": version.fingerprint, "utf8BOM": version.utf8_bom,
        })
    });
    json!({"path": file.path, "status": status, "text": text, "message": message, "version": version})
}

#[derive(Deserialize)]
pub(crate) struct FileRequest {
    pub folder: PathBuf,
    pub directories: Vec<PathBuf>,
    pub file: Option<PathBuf>,
    pub revision: Option<u64>,
}

pub(crate) fn encode_files(snapshot: &FileSnapshot) -> Result<Vec<u8>, serde_json::Error> {
    let directories: Vec<_> = snapshot
        .directories
        .iter()
        .map(|directory| {
            let entries: Vec<_> = directory
                .entries
                .iter()
                .map(|entry| {
                    json!({
                        "path": entry.path, "name": entry.name,
                        "kind": match entry.kind {
                            FileKind::Directory => "directory", FileKind::File => "file",
                            FileKind::Symlink => "symlink", FileKind::Other => "other",
                        }
                    })
                })
                .collect();
            json!({"path": directory.path, "entries": entries, "error": directory.error})
        })
        .collect();
    let file = snapshot.file.as_ref().map_or(Value::Null, encode_preview);
    serde_json::to_vec(&json!({
        "revision": snapshot.revision, "folder": snapshot.folder,
        "directories": directories, "file": file, "textLimit": TEXT_LIMIT,
    }))
}
