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

    /// Starts a model listing, which runs the harness's CLI on a core thread.
    pub(crate) fn request_harness_models(
        &self,
        bytes: &[u8],
    ) -> Result<twine_core::ModelListRequest, BridgeError> {
        let text = std::str::from_utf8(bytes).map_err(|_| BridgeError::InvalidUtf8)?;
        let request: protocol::harnesses::ModelsRequest =
            serde_json::from_str(text).map_err(|_| BridgeError::MalformedCommand)?;
        Ok(self
            .application
            .request_harness_models(request.harness, request.folder))
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

    pub(crate) fn new_window(data_directory: &Path) -> Result<Self, BridgeError> {
        Ok(Self {
            application: Application::new_window(data_directory)?,
        })
    }

    pub(crate) fn restorable_folders(&self) -> Result<Vec<u8>, BridgeError> {
        Ok(serde_json::to_vec(&self.application.restorable_folders()?)?)
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

    pub(crate) fn workflow_trace(
        &self,
        workflow_id: u64,
        before: u64,
        limit: usize,
    ) -> Result<Vec<u8>, BridgeError> {
        let page = self.application.workflow_trace(
            twine_core::WorkflowId(workflow_id),
            (before != 0).then_some(twine_core::TraceSpanId(before)),
            limit,
        )?;
        Ok(protocol::encode_workflow_trace(&page)?)
    }

    pub(crate) fn trace_events(
        &self,
        span_id: u64,
        after: u64,
        limit: usize,
    ) -> Result<Vec<u8>, BridgeError> {
        let page = self.application.trace_events(
            twine_core::TraceSpanId(span_id),
            (after != 0).then_some(twine_core::TraceEventId(after)),
            limit,
        )?;
        Ok(protocol::encode_trace_events(&page)?)
    }

    pub(crate) fn next_terminal_chunk(&self) -> Result<Option<TerminalChunk>, BridgeError> {
        Ok(self.application.next_terminal_chunk()?)
    }

    pub(crate) fn request_terminal_transcript(
        &self,
        terminal_id: u64,
        offset: u64,
        limit: usize,
    ) -> Result<Option<twine_core::TranscriptRequest>, BridgeError> {
        Ok(self.application.request_terminal_transcript(
            TerminalId::from_value(terminal_id),
            offset,
            limit,
        )?)
    }

    pub(crate) fn write_terminal_input(
        &self,
        terminal_id: u64,
        bytes: &[u8],
        user_input: bool,
    ) -> Result<(), BridgeError> {
        let terminal = TerminalId::from_value(terminal_id);
        if user_input {
            self.application.write_terminal_input(terminal, bytes)?;
        } else {
            self.application.write_terminal_response(terminal, bytes)?;
        }
        Ok(())
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

pub(crate) fn encode_transcript(page: twine_core::TranscriptRead) -> Vec<u8> {
    use twine_core::TranscriptRead;
    let mut bytes = Vec::new();
    match page {
        TranscriptRead::Expired { .. } => bytes.extend_from_slice(&1_u64.to_le_bytes()),
        TranscriptRead::Output(page) => {
            for number in [
                if page.replay_available { 2_u64 } else { 0 },
                page.offset,
                page.next_offset,
                page.end_offset,
                page.sizes.len() as u64,
            ] {
                bytes.extend_from_slice(&number.to_le_bytes());
            }
            for resize in page.sizes {
                bytes.extend_from_slice(&resize.offset.to_le_bytes());
                for dimension in [
                    resize.size.rows,
                    resize.size.columns,
                    resize.size.pixel_width,
                    resize.size.pixel_height,
                ] {
                    bytes.extend_from_slice(&dimension.to_le_bytes());
                }
            }
            bytes.extend(page.bytes);
        }
    }
    bytes
}
