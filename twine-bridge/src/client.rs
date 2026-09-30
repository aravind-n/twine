use std::path::Path;

use tracing::warn;
use twine_core::{Application, TerminalChunk, TerminalId, TerminalSize};

use crate::error::BridgeError;
use crate::protocol::{self, DecodedCommand};

#[repr(C)]
pub struct TwineClient {
    application: Application,
}

impl TwineClient {
    pub(crate) fn save_file(&self, bytes: &[u8]) -> Result<Vec<u8>, BridgeError> {
        let text = std::str::from_utf8(bytes).map_err(|_| BridgeError::InvalidUtf8)?;
        let request: protocol::files::SaveRequest =
            serde_json::from_str(text).map_err(|_| BridgeError::MalformedCommand)?;
        Ok(protocol::files::encode_save(
            self.application.save_file(&request.into()),
        )?)
    }

    pub(crate) fn poll_files(&self, bytes: &[u8]) -> Result<Vec<u8>, BridgeError> {
        let text = std::str::from_utf8(bytes).map_err(|_| BridgeError::InvalidUtf8)?;
        let request: protocol::files::FileRequest =
            serde_json::from_str(text).map_err(|_| BridgeError::MalformedCommand)?;
        let snapshot = self
            .application
            .poll_files(
                &request.folder,
                &request.directories,
                request.file.as_deref(),
                request.revision,
            )?
            .ok_or(BridgeError::Empty)?;
        Ok(protocol::files::encode_files(&snapshot)?)
    }

    pub(crate) fn new(data_directory: &Path) -> Result<Self, BridgeError> {
        Ok(Self {
            application: Application::new(data_directory)?,
        })
    }

    pub(crate) fn send_command(&self, bytes: &[u8]) -> Result<Vec<u8>, BridgeError> {
        let envelope = protocol::decode_command(bytes)?;
        let receipt = match envelope.command {
            DecodedCommand::Known(command) => self
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
        Ok(protocol::encode_snapshot(&self.application.snapshot()?)?)
    }

    pub(crate) fn events_after(&self, sequence: u64, limit: usize) -> Result<Vec<u8>, BridgeError> {
        Ok(protocol::encode_events(
            &self.application.events_after(sequence, limit)?,
        )?)
    }

    pub(crate) fn next_terminal_chunk(&self) -> Result<Option<TerminalChunk>, BridgeError> {
        Ok(self.application.next_terminal_chunk()?)
    }

    pub(crate) fn write_terminal_input(
        &self,
        terminal_id: u64,
        bytes: &[u8],
    ) -> Result<(), BridgeError> {
        Ok(self
            .application
            .write_terminal_input(TerminalId::from_value(terminal_id), bytes)?)
    }

    pub(crate) fn resize_terminal(
        &self,
        terminal_id: u64,
        size: TerminalSize,
    ) -> Result<(), BridgeError> {
        Ok(self
            .application
            .resize_terminal(TerminalId::from_value(terminal_id), size)?)
    }
}
