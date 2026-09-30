use std::path::PathBuf;

use serde::Deserialize;
use serde_json::{Value, json};
use twine_core::{FileContent, FileKind, FileSnapshot, TEXT_LIMIT};

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
    let file = snapshot.file.as_ref().map_or(Value::Null, |file| {
        let (status, text, message) = match &file.content {
            FileContent::Text(text) => ("text", Some(text.as_str()), None),
            FileContent::Binary => ("binary", None, None),
            FileContent::TooLarge => ("tooLarge", None, None),
            FileContent::Missing => ("missing", None, None),
            FileContent::Unsupported => ("unsupported", None, None),
            FileContent::Unavailable(message) => ("unavailable", None, Some(message.as_str())),
        };
        json!({"path": file.path, "status": status, "text": text, "message": message})
    });
    serde_json::to_vec(&json!({
        "revision": snapshot.revision, "folder": snapshot.folder,
        "directories": directories, "file": file, "textLimit": TEXT_LIMIT,
    }))
}
