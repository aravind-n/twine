use thiserror::Error;
use tracing::warn;
use twine_core::{Application, ApplicationError, EventError, TerminalChunk};

use crate::protocol::{self, DecodedCommand};

pub(crate) struct BridgeClient {
    application: Application,
}

#[repr(C)]
pub struct TwineClient {
    bridge: BridgeClient,
}

impl TwineClient {
    pub(crate) fn new() -> Result<Self, BridgeError> {
        Ok(Self {
            bridge: BridgeClient {
                application: Application::new()?,
            },
        })
    }

    pub(crate) fn send_command(&self, bytes: &[u8]) -> Result<Vec<u8>, BridgeError> {
        let envelope = protocol::decode_command(bytes)?;
        let receipt = match envelope.command {
            DecodedCommand::Known(command) => self
                .bridge
                .application
                .handle_command(envelope.request_id, command)?,
            DecodedCommand::Unsupported(command_type) => {
                warn!(request_id = envelope.request_id.0, "command rejected");
                protocol::unsupported_receipt(envelope.request_id, &command_type)
            }
        };
        Ok(protocol::encode_receipt(&receipt)?)
    }

    pub(crate) fn snapshot(&self) -> Result<Vec<u8>, BridgeError> {
        Ok(protocol::encode_snapshot(
            &self.bridge.application.snapshot()?,
        )?)
    }

    pub(crate) fn events_after(&self, sequence: u64, limit: usize) -> Result<Vec<u8>, BridgeError> {
        Ok(protocol::encode_events(
            &self.bridge.application.events_after(sequence, limit)?,
        )?)
    }

    pub(crate) fn next_terminal_chunk(&self) -> Result<Option<TerminalChunk>, BridgeError> {
        Ok(self.bridge.application.next_terminal_chunk()?)
    }

    #[cfg(test)]
    pub(crate) const fn application(&self) -> &Application {
        &self.bridge.application
    }
}

#[derive(Debug, Error)]
pub(crate) enum BridgeError {
    #[error(transparent)]
    Application(#[from] ApplicationError),
    #[error("command input exceeds the maximum size")]
    CommandTooLarge,
    #[error("no value is available")]
    Empty,
    #[error("invalid bridge argument")]
    InvalidArgument,
    #[error("input is not valid UTF-8")]
    InvalidUtf8,
    #[error("command is not valid JSON")]
    MalformedCommand,
    #[error("required pointer is null")]
    NullPointer,
    #[error("failed to initialize Rust logging: {0}")]
    Subscriber(String),
    #[error(transparent)]
    Serialization(#[from] serde_json::Error),
}

impl BridgeError {
    pub(crate) fn is_cursor_expired(&self) -> bool {
        matches!(
            self,
            Self::Application(ApplicationError::Event(EventError::CursorExpired { .. }))
        )
    }
}
