use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use twine_core::{
    ApplicationState, Command, CommandDisposition, CommandReceipt, CommandResult, Event, EventKind,
    FolderState, RequestId, Snapshot, StateEvent, UnavailableReason,
};

use crate::client::BridgeError;

#[derive(Debug)]
pub(crate) struct CommandEnvelope {
    pub request_id: RequestId,
    pub command: DecodedCommand,
}

#[derive(Debug)]
pub(crate) enum DecodedCommand {
    Known(Command),
    Unsupported(String),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawCommandEnvelope {
    request_id: u64,
    command: Value,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireReceipt<'a> {
    request_id: u64,
    #[serde(flatten)]
    disposition: WireDisposition<'a>,
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
enum WireDisposition<'a> {
    Accepted,
    Rejected { error: WireError<'a> },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireError<'a> {
    code: &'a str,
    message: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireSnapshot<'a> {
    sequence: u64,
    state: WireApplicationState,
    config: &'a twine_core::config::Config,
    folders: WireFolderState<'a>,
}

/// Paths serialize as strings; serde rejects a path that isn't valid UTF-8.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireFolderState<'a> {
    open_folder: Option<&'a Path>,
    recent_folders: Vec<WireRecentFolder<'a>>,
    unavailable_folder: Option<WireUnavailableFolder<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireRecentFolder<'a> {
    path: &'a Path,
    is_missing: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireUnavailableFolder<'a> {
    path: &'a Path,
    reason: WireUnavailableReason,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
enum WireUnavailableReason {
    Missing,
    Inaccessible,
}

impl<'a> From<&'a FolderState> for WireFolderState<'a> {
    fn from(folders: &'a FolderState) -> Self {
        Self {
            open_folder: folders.open_folder.as_deref(),
            recent_folders: folders
                .recent_folders
                .iter()
                .map(|folder| WireRecentFolder {
                    path: &folder.path,
                    is_missing: folder.is_missing,
                })
                .collect(),
            unavailable_folder: folders.unavailable_folder.as_ref().map(|folder| {
                WireUnavailableFolder {
                    path: &folder.path,
                    reason: match folder.reason {
                        UnavailableReason::Missing => WireUnavailableReason::Missing,
                        UnavailableReason::Inaccessible => WireUnavailableReason::Inaccessible,
                    },
                }
            }),
        }
    }
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
enum WireApplicationState {
    Ready,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireEventBatch<'a> {
    events: Vec<WireEvent<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireEvent<'a> {
    sequence: u64,
    event: WireEventKind<'a>,
}

#[derive(Serialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum WireEventKind<'a> {
    ApplicationReady,
    CommandCompleted {
        request_id: u64,
        result: WireCommandResult,
    },
    FoldersChanged {
        folders: WireFolderState<'a>,
    },
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum WireCommandResult {
    Pong,
}

pub(crate) fn decode_command(bytes: &[u8]) -> Result<CommandEnvelope, BridgeError> {
    let text = std::str::from_utf8(bytes).map_err(|_| BridgeError::InvalidUtf8)?;
    let raw: RawCommandEnvelope =
        serde_json::from_str(text).map_err(|_| BridgeError::MalformedCommand)?;
    let command_type = raw
        .command
        .get("type")
        .and_then(Value::as_str)
        .ok_or(BridgeError::MalformedCommand)?;
    let command = match command_type {
        "ping" => DecodedCommand::Known(Command::Ping),
        "openFolder" => DecodedCommand::Known(Command::OpenFolder {
            path: decode_path(&raw.command)?,
        }),
        "closeFolder" => DecodedCommand::Known(Command::CloseFolder),
        "removeRecentFolder" => DecodedCommand::Known(Command::RemoveRecentFolder {
            path: decode_path(&raw.command)?,
        }),
        other => DecodedCommand::Unsupported(other.to_owned()),
    };
    Ok(CommandEnvelope {
        request_id: RequestId(raw.request_id),
        command,
    })
}

fn decode_path(command: &Value) -> Result<PathBuf, BridgeError> {
    command
        .get("path")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .ok_or(BridgeError::MalformedCommand)
}

pub(crate) fn unsupported_receipt(request_id: RequestId, command_type: &str) -> CommandReceipt {
    CommandReceipt {
        request_id,
        disposition: CommandDisposition::Rejected {
            code: "unsupportedCommand".to_owned(),
            message: format!("unsupported command type: {command_type}"),
        },
    }
}

pub(crate) fn encode_receipt(receipt: &CommandReceipt) -> Result<Vec<u8>, serde_json::Error> {
    let disposition = match &receipt.disposition {
        CommandDisposition::Accepted => WireDisposition::Accepted,
        CommandDisposition::Rejected { code, message } => WireDisposition::Rejected {
            error: WireError { code, message },
        },
    };
    serde_json::to_vec(&WireReceipt {
        request_id: receipt.request_id.0,
        disposition,
    })
}

pub(crate) fn encode_snapshot(snapshot: &Snapshot) -> Result<Vec<u8>, serde_json::Error> {
    let state = match snapshot.state {
        ApplicationState::Ready => WireApplicationState::Ready,
    };
    serde_json::to_vec(&WireSnapshot {
        sequence: snapshot.sequence,
        state,
        config: &snapshot.config,
        folders: (&snapshot.folders).into(),
    })
}

pub(crate) fn encode_events(events: &[Event]) -> Result<Vec<u8>, serde_json::Error> {
    let events = events
        .iter()
        .map(|event| WireEvent {
            sequence: event.sequence,
            event: match &event.kind {
                EventKind::State(StateEvent::ApplicationReady) => WireEventKind::ApplicationReady,
                EventKind::State(StateEvent::FoldersChanged(folders)) => {
                    WireEventKind::FoldersChanged {
                        folders: folders.into(),
                    }
                }
                EventKind::CommandCompleted {
                    request_id,
                    result: CommandResult::Pong,
                } => WireEventKind::CommandCompleted {
                    request_id: request_id.0,
                    result: WireCommandResult::Pong,
                },
            },
        })
        .collect();
    serde_json::to_vec(&WireEventBatch { events })
}

#[cfg(test)]
mod tests {
    use super::*;
    use twine_core::config::{Appearance, ColorScheme, Config};
    use twine_core::{RecentFolder, UnavailableFolder};

    #[test]
    fn snapshot_serializes_validated_config() {
        let data = tempfile::tempdir().unwrap();
        let application = twine_core::Application::with_config(
            data.path(),
            Config {
                appearance: Appearance {
                    color_scheme: ColorScheme::Dark,
                },
            },
        )
        .unwrap();
        let bytes = encode_snapshot(&application.snapshot().unwrap()).unwrap();
        let json: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "sequence": 1,
                "state": { "status": "ready" },
                "config": { "appearance": { "color_scheme": "dark" } },
                "folders": { "openFolder": null, "recentFolders": [], "unavailableFolder": null }
            })
        );
    }

    #[test]
    fn snapshot_serializes_folder_state() {
        let snapshot = Snapshot {
            sequence: 3,
            state: ApplicationState::Ready,
            config: Config::default(),
            folders: FolderState {
                open_folder: None,
                recent_folders: vec![
                    RecentFolder {
                        path: PathBuf::from("/projects/locked"),
                        is_missing: false,
                    },
                    RecentFolder {
                        path: PathBuf::from("/projects/deleted"),
                        is_missing: true,
                    },
                ],
                unavailable_folder: Some(UnavailableFolder {
                    path: PathBuf::from("/projects/locked"),
                    reason: UnavailableReason::Inaccessible,
                }),
            },
        };
        let json: Value = serde_json::from_slice(&encode_snapshot(&snapshot).unwrap()).unwrap();
        assert_eq!(
            json["folders"],
            serde_json::json!({
                "openFolder": null,
                "recentFolders": [
                    { "path": "/projects/locked", "isMissing": false },
                    { "path": "/projects/deleted", "isMissing": true }
                ],
                "unavailableFolder": { "path": "/projects/locked", "reason": "inaccessible" }
            })
        );
    }
}
