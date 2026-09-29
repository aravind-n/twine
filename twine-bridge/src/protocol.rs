use serde::{Deserialize, Serialize};
use serde_json::Value;
use twine_core::{
    ApplicationState, Command, CommandDisposition, CommandReceipt, CommandResult, Event, EventKind,
    RequestId, Snapshot, StateEvent,
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
struct WireSnapshot {
    sequence: u64,
    state: WireApplicationState,
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
enum WireApplicationState {
    Ready,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireEventBatch {
    events: Vec<WireEvent>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireEvent {
    sequence: u64,
    event: WireEventKind,
}

#[derive(Serialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum WireEventKind {
    ApplicationReady,
    CommandCompleted {
        request_id: u64,
        result: WireCommandResult,
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
        other => DecodedCommand::Unsupported(other.to_owned()),
    };
    Ok(CommandEnvelope {
        request_id: RequestId(raw.request_id),
        command,
    })
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
    })
}

pub(crate) fn encode_events(events: &[Event]) -> Result<Vec<u8>, serde_json::Error> {
    let events = events
        .iter()
        .map(|event| WireEvent {
            sequence: event.sequence,
            event: match event.kind {
                EventKind::State(StateEvent::ApplicationReady) => WireEventKind::ApplicationReady,
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
