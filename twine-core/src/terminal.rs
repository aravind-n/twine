use std::path::PathBuf;

use thiserror::Error;

mod launcher;
mod manager;
mod process;
mod pty;
mod stream;
mod transcript;

#[cfg(not(test))]
pub(crate) use launcher::login_shell;
pub(crate) use manager::{TerminalManager, TerminalObservation};
pub(crate) use stream::{ReplayPosition, TerminalStream};
pub(crate) use transcript::Recording;
pub(crate) use transcript::TranscriptRecorder;
pub use transcript::TranscriptRequest;
pub use transcript::TranscriptSize;
pub use transcript::{MAX_TRANSCRIPT_READ_BYTES, TranscriptError, TranscriptPage, TranscriptRead};

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct TerminalId(u64);

impl TerminalId {
    #[must_use]
    pub const fn from_value(value: u64) -> Self {
        Self(value)
    }

    #[must_use]
    pub const fn value(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct TerminalSize {
    pub rows: u16,
    pub columns: u16,
    pub pixel_width: u16,
    pub pixel_height: u16,
}

impl TerminalSize {
    /// # Errors
    ///
    /// Returns an error when either character dimension is zero.
    pub fn validate(self) -> Result<Self, TerminalError> {
        if self.rows == 0 || self.columns == 0 {
            return Err(TerminalError::InvalidSize {
                rows: self.rows,
                columns: self.columns,
            });
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalExit {
    pub exit_code: u32,
    pub signal: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TerminalStatus {
    Running,
    Exited(TerminalExit),
    Failed { message: String },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalState {
    pub terminal_id: TerminalId,
    pub status: TerminalStatus,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalChunk {
    pub terminal_id: TerminalId,
    pub offset: u64,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Error)]
pub enum TerminalError {
    #[error("terminal output chunk has {chunk_bytes} bytes, exceeding capacity {capacity_bytes}")]
    ChunkTooLarge {
        chunk_bytes: usize,
        capacity_bytes: usize,
    },
    #[error("terminal output chunks must not be empty")]
    EmptyChunk,
    #[error("terminal size must be nonzero, received {columns} columns by {rows} rows")]
    InvalidSize { rows: u16, columns: u16 },
    #[error("terminal byte offset overflowed")]
    OffsetOverflow,
    #[error("terminal {terminal_id:?} is not open")]
    NotOpen { terminal_id: TerminalId },
    #[error("failed to {operation}: {message}")]
    Pty {
        operation: &'static str,
        message: String,
    },
    #[error("terminal state lock is poisoned")]
    Poisoned,
    #[error("failed to {operation}: {message}")]
    Thread {
        operation: &'static str,
        message: String,
    },
    #[error("cannot use {path} as a terminal working directory: {message}")]
    WorkingDirectory { path: PathBuf, message: String },
    #[error("terminal output capacity must be greater than zero")]
    ZeroCapacity,
    #[error(transparent)]
    Transcript(#[from] TranscriptError),
}
