use std::panic::{AssertUnwindSafe, catch_unwind};

use tracing::error;

use crate::TwineClient;
use crate::client::BridgeError;

#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};

#[cfg(test)]
static LIVE_BUFFERS: AtomicUsize = AtomicUsize::new(0);

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TwineStatus {
    Ok = 0,
    Empty = 1,
    NullPointer = 2,
    InvalidUtf8 = 3,
    MalformedCommand = 4,
    InvalidArgument = 5,
    CursorExpired = 6,
    InternalError = 7,
    Panic = 8,
}

#[repr(C)]
#[derive(Debug)]
pub struct TwineBuffer {
    pub data: *mut u8,
    pub length: usize,
}

impl TwineBuffer {
    pub const fn empty() -> Self {
        Self {
            data: std::ptr::null_mut(),
            length: 0,
        }
    }

    pub fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self::empty();
        }

        let mut bytes = bytes.into_boxed_slice();
        let buffer = Self {
            data: bytes.as_mut_ptr(),
            length: bytes.len(),
        };
        std::mem::forget(bytes);
        #[cfg(test)]
        LIVE_BUFFERS.fetch_add(1, Ordering::SeqCst);
        buffer
    }
}

#[repr(C)]
#[derive(Debug)]
pub struct TwineTerminalChunk {
    pub terminal_id: u64,
    pub offset: u64,
    pub bytes: TwineBuffer,
}

impl TwineTerminalChunk {
    pub const fn empty() -> Self {
        Self {
            terminal_id: 0,
            offset: 0,
            bytes: TwineBuffer::empty(),
        }
    }

    pub fn from_core(chunk: twine_core::TerminalChunk) -> Self {
        Self {
            terminal_id: chunk.terminal_id.value(),
            offset: chunk.offset,
            bytes: TwineBuffer::from_vec(chunk.bytes),
        }
    }
}

pub(crate) fn catch_status(operation: impl FnOnce() -> Result<(), BridgeError>) -> TwineStatus {
    match catch_unwind(AssertUnwindSafe(|| {
        match catch_unwind(AssertUnwindSafe(operation)) {
            Ok(Ok(())) => TwineStatus::Ok,
            Ok(Err(error)) => {
                let status = status_for_error(&error);
                if !matches!(status, TwineStatus::Empty) {
                    error!(error = %describe(&error), ?status, "bridge operation failed");
                }
                status
            }
            Err(_) => {
                error!("Rust panic contained at C boundary");
                TwineStatus::Panic
            }
        }
    })) {
        Ok(status) => status,
        Err(_) => TwineStatus::Panic,
    }
}

/// Formats an error with its causes, which would otherwise be lost: the error's message alone names
/// the operation that failed, and the causes say why.
fn describe(error: &dyn std::error::Error) -> String {
    let mut description = error.to_string();
    let mut source = error.source();
    while let Some(cause) = source {
        description.push_str(": ");
        description.push_str(&cause.to_string());
        source = cause.source();
    }
    description
}

/// # Safety
///
/// A null `client` is rejected without dereferencing it. Otherwise it must point to a live,
/// correctly aligned `TwineClient` created by this bridge. The caller must prevent destruction and
/// mutable aliasing for the duration of `operation`.
pub(crate) unsafe fn with_client<T>(
    client: *mut TwineClient,
    operation: impl FnOnce(&TwineClient) -> Result<T, BridgeError>,
) -> Result<T, BridgeError> {
    // SAFETY: Null is rejected. The reference stays inside this call while the caller-owned bridge
    // handle is alive; Swift serializes access to the handle.
    let client = unsafe { client.as_ref() }.ok_or(BridgeError::NullPointer)?;
    operation(client)
}

/// # Safety
///
/// A null `buffer` is rejected without dereferencing it. Otherwise it must point to aligned,
/// writable storage for one `TwineBuffer` and must not contain a live bridge allocation.
pub(crate) unsafe fn initialize_buffer(buffer: *mut TwineBuffer) -> Result<(), BridgeError> {
    // SAFETY: The caller supplies the same writable output pointer required by `write_buffer`.
    unsafe { write_buffer(buffer, TwineBuffer::empty()) }
}

/// # Safety
///
/// A null `chunk` is rejected without dereferencing it. Otherwise it must point to aligned, writable
/// storage for one `TwineTerminalChunk` and its byte buffer must not contain a live bridge
/// allocation.
pub(crate) unsafe fn initialize_terminal_chunk(
    chunk: *mut TwineTerminalChunk,
) -> Result<(), BridgeError> {
    // SAFETY: The caller supplies the same writable output pointer required by
    // `write_terminal_chunk`.
    unsafe { write_terminal_chunk(chunk, TwineTerminalChunk::empty()) }
}

/// # Safety
///
/// When `length` exceeds `maximum_length`, `bytes` is not accessed. For a nonzero length at or below
/// the maximum, a null pointer is rejected; otherwise `bytes` must point to at least `length`
/// readable, initialized bytes that remain live for the duration of `operation`. For zero length,
/// the pointer is not accessed.
pub(crate) unsafe fn with_input_bytes<T>(
    bytes: *const u8,
    length: usize,
    maximum_length: usize,
    operation: impl FnOnce(&[u8]) -> Result<T, BridgeError>,
) -> Result<T, BridgeError> {
    if length > maximum_length {
        return Err(BridgeError::InputTooLarge);
    }
    if length == 0 {
        return operation(&[]);
    }
    if bytes.is_null() {
        return Err(BridgeError::NullPointer);
    }

    // SAFETY: The pointer is non-null and the C caller promises `length` readable bytes for the
    // duration of the call. The reference is scoped to `operation` and cannot escape.
    operation(unsafe { std::slice::from_raw_parts(bytes, length) })
}

/// # Safety
///
/// A null `buffer` is rejected without dereferencing it. Otherwise it must point to aligned,
/// writable storage. A nonempty value must be the unchanged pointer/length pair returned by this
/// bridge and must not have been released before.
pub(crate) unsafe fn release_buffer(buffer: *mut TwineBuffer) -> Result<(), BridgeError> {
    // SAFETY: Null is rejected before dereferencing.
    let buffer = unsafe { buffer.as_mut() }.ok_or(BridgeError::NullPointer)?;
    if buffer.data.is_null() {
        if buffer.length == 0 {
            return Ok(());
        }
        return Err(BridgeError::InvalidArgument);
    }
    if buffer.length == 0 {
        return Err(BridgeError::InvalidArgument);
    }

    // SAFETY: The C contract requires this exact pointer/length pair to have been returned by the
    // bridge and released once. Rebuilding the boxed slice returns it to Rust's allocator.
    unsafe {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            buffer.data,
            buffer.length,
        )));
    }
    buffer.data = std::ptr::null_mut();
    buffer.length = 0;
    #[cfg(test)]
    LIVE_BUFFERS.fetch_sub(1, Ordering::SeqCst);
    Ok(())
}

/// # Safety
///
/// A null `out_buffer` is rejected without dereferencing it. Otherwise it must point to aligned,
/// writable storage for one `TwineBuffer` and must not contain a live bridge allocation.
pub(crate) unsafe fn write_buffer(
    out_buffer: *mut TwineBuffer,
    buffer: TwineBuffer,
) -> Result<(), BridgeError> {
    // SAFETY: Null is rejected. The caller provides writable storage for one C-compatible value.
    *unsafe { out_buffer.as_mut() }.ok_or(BridgeError::NullPointer)? = buffer;
    Ok(())
}

/// # Safety
///
/// A null `out_client` is rejected without dereferencing it. Otherwise it must point to aligned,
/// writable storage for one client pointer.
pub(crate) unsafe fn write_client(
    out_client: *mut *mut TwineClient,
    client: *mut TwineClient,
) -> Result<(), BridgeError> {
    // SAFETY: Null is rejected. The caller provides writable storage for one pointer.
    *unsafe { out_client.as_mut() }.ok_or(BridgeError::NullPointer)? = client;
    Ok(())
}

/// # Safety
///
/// A null `out_chunk` is rejected without dereferencing it. Otherwise it must point to aligned,
/// writable storage for one `TwineTerminalChunk` and its byte buffer must not contain a live bridge
/// allocation.
pub(crate) unsafe fn write_terminal_chunk(
    out_chunk: *mut TwineTerminalChunk,
    chunk: TwineTerminalChunk,
) -> Result<(), BridgeError> {
    // SAFETY: Null is rejected. The caller provides writable storage for one C-compatible value.
    *unsafe { out_chunk.as_mut() }.ok_or(BridgeError::NullPointer)? = chunk;
    Ok(())
}

fn status_for_error(error: &BridgeError) -> TwineStatus {
    if error.is_cursor_expired() {
        return TwineStatus::CursorExpired;
    }

    match error {
        BridgeError::InputTooLarge | BridgeError::InvalidArgument => TwineStatus::InvalidArgument,
        BridgeError::Empty => TwineStatus::Empty,
        BridgeError::InvalidUtf8 => TwineStatus::InvalidUtf8,
        BridgeError::MalformedCommand => TwineStatus::MalformedCommand,
        BridgeError::NullPointer => TwineStatus::NullPointer,
        BridgeError::Application(_)
        | BridgeError::Serialization(_)
        | BridgeError::Subscriber(_) => TwineStatus::InternalError,
    }
}

#[cfg(test)]
pub(crate) fn live_buffer_count() -> usize {
    LIVE_BUFFERS.load(Ordering::SeqCst)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use twine_core::{ApplicationError, StoreError};

    use super::*;

    #[test]
    fn logged_errors_include_their_causes() {
        let error =
            BridgeError::Application(ApplicationError::Store(StoreError::CreateDirectory {
                path: PathBuf::from("/data"),
                source: std::io::Error::from(std::io::ErrorKind::PermissionDenied),
            }));
        assert_eq!(
            describe(&error),
            "failed to create the data directory /data: permission denied"
        );
    }

    #[test]
    fn input_bytes_validate_pointer_and_length_before_borrowing() {
        let bytes = [1, 2, 3];
        assert_eq!(
            // SAFETY: `bytes` remains live and readable for the callback.
            unsafe { with_input_bytes(bytes.as_ptr(), bytes.len(), 3, |input| Ok(input.len())) }
                .expect("valid bytes should be visible inside the callback"),
            3
        );
        assert_eq!(
            // SAFETY: A zero-length input does not require a readable pointer.
            unsafe { with_input_bytes(std::ptr::null(), 0, 3, |input| Ok(input.len())) }
                .expect("an empty input should not require a pointer"),
            0
        );
        assert!(matches!(
            // SAFETY: This intentionally invalid pair is rejected before dereferencing the pointer.
            unsafe { with_input_bytes(std::ptr::null(), 1, 3, |_| Ok(())) },
            Err(BridgeError::NullPointer)
        ));
        assert!(matches!(
            // SAFETY: The oversized length is rejected before a slice is constructed.
            unsafe { with_input_bytes(bytes.as_ptr(), 4, 3, |_| Ok(())) },
            Err(BridgeError::InputTooLarge)
        ));
    }
}
