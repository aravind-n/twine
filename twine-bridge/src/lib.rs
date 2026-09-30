//! C ABI adapter for the Twine core.

mod client;
mod error;
mod ffi;
mod logging;
mod protocol;
#[cfg(test)]
mod test_support;

use std::path::Path;

use error::BridgeError;
use ffi::{TwineBuffer, TwineStatus, TwineTerminalChunk, catch_status};
use twine_core::TerminalSize;

pub use client::TwineClient;

const MAX_COMMAND_BYTES: usize = 1024 * 1024;
// JSON may escape each text byte as six bytes; allow the full 2 MiB editor limit plus paths.
const MAX_FILE_SAVE_BYTES: usize = 6 * 2 * 1024 * 1024 + 16 * 1024;
const MAX_EVENT_BATCH: usize = 256;
/// The longest path macOS accepts (`PATH_MAX`).
const MAX_PATH_BYTES: usize = 1024;
const MAX_TERMINAL_INPUT_BYTES: usize = 64 * 1024;

#[unsafe(no_mangle)]
/// Polls lazy file listings and versioned text previews.
///
/// # Safety
/// Uses the same pointer, length, and ownership contract as `twine_client_send_command`.
pub unsafe extern "C" fn twine_client_poll_files(
    client: *mut TwineClient,
    request_bytes: *const u8,
    request_length: usize,
    out_snapshot: *mut TwineBuffer,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: The caller supplies writable, aligned output storage without a live allocation.
        unsafe { ffi::initialize_buffer(out_snapshot) }?;
        // SAFETY: The caller guarantees readable input and a live client for this call.
        let response = unsafe {
            ffi::with_input_bytes(request_bytes, request_length, MAX_COMMAND_BYTES, |bytes| {
                ffi::with_client(client, |client| client.poll_files(bytes))
            })
        }?;
        // SAFETY: Output was validated before allocating the response.
        unsafe { ffi::write_buffer(out_snapshot, TwineBuffer::from_vec(response)) }
    })
}

#[unsafe(no_mangle)]
/// Saves text through core, returning a saved preview, conflict preview, or failure message as JSON.
///
/// # Safety
/// Uses the same pointer, length, and ownership contract as `twine_client_send_command`, with
/// a `MAX_FILE_SAVE_BYTES` input limit to accommodate escaped text.
pub unsafe extern "C" fn twine_client_save_file(
    client: *mut TwineClient,
    request_bytes: *const u8,
    request_length: usize,
    out_result: *mut TwineBuffer,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: The caller supplies writable, aligned output storage without a live allocation.
        unsafe { ffi::initialize_buffer(out_result) }?;
        // SAFETY: The caller guarantees readable input and a live client for this call.
        let response = unsafe {
            ffi::with_input_bytes(
                request_bytes,
                request_length,
                MAX_FILE_SAVE_BYTES,
                |bytes| ffi::with_client(client, |client| client.save_file(bytes)),
            )
        }?;
        // SAFETY: Output was validated before allocating the response.
        unsafe { ffi::write_buffer(out_result, TwineBuffer::from_vec(response)) }
    })
}

#[unsafe(no_mangle)]
/// Creates a bridge client whose core keeps its database in `data_directory`.
///
/// # Safety
///
/// A null `out_client` is rejected without dereferencing any other pointer. Otherwise it must
/// point to aligned, writable storage for one client pointer. A data directory longer than
/// `MAX_PATH_BYTES` is rejected without reading `data_directory`. For a nonzero length at or below
/// the limit, a null `data_directory` is rejected; otherwise it must point to
/// `data_directory_length` readable bytes.
pub unsafe extern "C" fn twine_client_create(
    data_directory: *const u8,
    data_directory_length: usize,
    out_client: *mut *mut TwineClient,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::write_client(out_client, std::ptr::null_mut()) }?;
        logging::initialize()?;
        // SAFETY: Guaranteed by this function's input contract. The borrowed bytes stay scoped to
        // the callback.
        let client = unsafe {
            ffi::with_input_bytes(
                data_directory,
                data_directory_length,
                MAX_PATH_BYTES,
                |bytes| {
                    let path = Path::new(
                        std::str::from_utf8(bytes).map_err(|_| BridgeError::InvalidUtf8)?,
                    );
                    if !path.is_absolute() {
                        return Err(BridgeError::InvalidArgument);
                    }
                    TwineClient::new(path)
                },
            )
        }?;
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::write_client(out_client, Box::into_raw(Box::new(client))) }
    })
}

#[unsafe(no_mangle)]
/// Destroys a bridge client.
///
/// # Safety
///
/// A null `client` is accepted. Otherwise it must be a live, correctly aligned pointer returned by
/// `twine_client_create` and must be destroyed exactly once with no concurrent operations.
pub unsafe extern "C" fn twine_client_destroy(client: *mut TwineClient) -> TwineStatus {
    catch_status(|| {
        if client.is_null() {
            return Ok(());
        }

        // SAFETY: The C contract requires the pointer to have come from `twine_client_create` and
        // to be destroyed exactly once. Swift keeps it actor-isolated and follows that contract.
        unsafe { drop(Box::from_raw(client)) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
/// Sends one serialized command to the core.
///
/// # Safety
///
/// A null `out_response` is rejected without dereferencing any other pointer. Otherwise it must
/// point to aligned, writable storage and must not contain an unreleased bridge allocation. A
/// command larger than `MAX_COMMAND_BYTES` is rejected without reading `command_bytes` or `client`.
/// For a nonzero command at or below the limit, a null `command_bytes` is rejected; otherwise it
/// must point to `command_length` readable bytes. A null `client` is rejected; otherwise it must be
/// live, correctly aligned, and exclusively owned for the call.
pub unsafe extern "C" fn twine_client_send_command(
    client: *mut TwineClient,
    command_bytes: *const u8,
    command_length: usize,
    out_response: *mut TwineBuffer,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::initialize_buffer(out_response) }?;
        // SAFETY: Guaranteed by this function's input and client contracts. The borrowed bytes stay
        // scoped to the callback.
        let response = unsafe {
            ffi::with_input_bytes(command_bytes, command_length, MAX_COMMAND_BYTES, |bytes| {
                // SAFETY: The outer function's contract keeps the client alive for this call.
                ffi::with_client(client, |client| client.send_command(bytes))
            })
        }?;
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::write_buffer(out_response, TwineBuffer::from_vec(response)) }
    })
}

#[unsafe(no_mangle)]
/// Returns a serialized state snapshot.
///
/// # Safety
///
/// A null `out_snapshot` is rejected without dereferencing it. Otherwise it must point to aligned,
/// writable storage and must not contain an unreleased bridge allocation. A null `client` is
/// rejected; otherwise it must be live, correctly aligned, and exclusively owned for the call.
pub unsafe extern "C" fn twine_client_snapshot(
    client: *mut TwineClient,
    out_snapshot: *mut TwineBuffer,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::initialize_buffer(out_snapshot) }?;
        // SAFETY: Guaranteed by this function's client contract.
        let snapshot = unsafe { ffi::with_client(client, TwineClient::snapshot) }?;
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::write_buffer(out_snapshot, TwineBuffer::from_vec(snapshot)) }
    })
}

#[unsafe(no_mangle)]
/// Returns serialized events after a sequence cursor.
///
/// # Safety
///
/// A null `out_events` is rejected without dereferencing it. Otherwise it must point to aligned,
/// writable storage and must not contain an unreleased bridge allocation. A null `client` is
/// rejected; otherwise it must be live, correctly aligned, and exclusively owned for the call.
pub unsafe extern "C" fn twine_client_events_after(
    client: *mut TwineClient,
    sequence: u64,
    limit: u32,
    out_events: *mut TwineBuffer,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::initialize_buffer(out_events) }?;
        if limit == 0 || usize::try_from(limit).unwrap_or(usize::MAX) > MAX_EVENT_BATCH {
            return Err(BridgeError::InvalidArgument);
        }

        // SAFETY: Guaranteed by this function's client contract.
        let events = unsafe {
            ffi::with_client(client, |client| {
                client.events_after(sequence, limit as usize)
            })
        }?;
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::write_buffer(out_events, TwineBuffer::from_vec(events)) }
    })
}

#[unsafe(no_mangle)]
/// Returns a page of durable spans; a zero `before_span_id` reads the newest page.
///
/// # Safety
/// The client must be live and exclusively owned during this call. The output must identify aligned,
/// writable storage without a live bridge allocation. Null pointers are rejected before use.
pub unsafe extern "C" fn twine_client_workflow_trace(
    client: *mut TwineClient,
    workflow_id: u64,
    before_span_id: u64,
    limit: u32,
    out_page: *mut TwineBuffer,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::initialize_buffer(out_page) }?;
        if limit == 0 || limit as usize > twine_core::MAX_TRACE_PAGE_SIZE {
            return Err(BridgeError::InvalidArgument);
        }
        // SAFETY: Guaranteed by this function's client contract.
        let page = unsafe {
            ffi::with_client(client, |client| {
                client.workflow_trace(workflow_id, before_span_id, limit as usize)
            })
        }?;
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::write_buffer(out_page, TwineBuffer::from_vec(page)) }
    })
}

#[unsafe(no_mangle)]
/// Returns a page of span events; a zero `after_event_id` reads from the beginning.
///
/// # Safety
/// The client must be live and exclusively owned during this call. The output must identify aligned,
/// writable storage without a live bridge allocation. Null pointers are rejected before use.
pub unsafe extern "C" fn twine_client_trace_events(
    client: *mut TwineClient,
    span_id: u64,
    after_event_id: u64,
    limit: u32,
    out_page: *mut TwineBuffer,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::initialize_buffer(out_page) }?;
        if limit == 0 || limit as usize > twine_core::MAX_TRACE_PAGE_SIZE {
            return Err(BridgeError::InvalidArgument);
        }
        // SAFETY: Guaranteed by this function's client contract.
        let page = unsafe {
            ffi::with_client(client, |client| {
                client.trace_events(span_id, after_event_id, limit as usize)
            })
        }?;
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::write_buffer(out_page, TwineBuffer::from_vec(page)) }
    })
}

#[unsafe(no_mangle)]
/// Removes and returns the next binary terminal-output chunk.
///
/// # Safety
///
/// A null `out_chunk` is rejected without dereferencing it. Otherwise it must point to aligned,
/// writable storage and its byte buffer must not contain an unreleased bridge allocation. A null
/// `client` is rejected; otherwise it must be live, correctly aligned, and exclusively owned for
/// the call.
pub unsafe extern "C" fn twine_client_next_terminal_chunk(
    client: *mut TwineClient,
    out_chunk: *mut TwineTerminalChunk,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::initialize_terminal_chunk(out_chunk) }?;
        // SAFETY: Guaranteed by this function's client contract.
        let Some(chunk) = (unsafe { ffi::with_client(client, TwineClient::next_terminal_chunk) })?
        else {
            return Err(BridgeError::Empty);
        };
        // SAFETY: Guaranteed by this function's output contract.
        unsafe { ffi::write_terminal_chunk(out_chunk, TwineTerminalChunk::from_core(chunk)) }
    })
}

/// An exclusively owned pending transcript read. Destroy exactly once after completion/cancellation.
pub struct TwineTranscriptRequest(twine_core::TranscriptRequest);

#[unsafe(no_mangle)]
/// Starts a transcript read without waiting for disk. Empty means retry when queue space is available.
///
/// # Safety
/// Non-null client must be live and exclusively owned. Non-null output must be aligned writable
/// storage without an unreleased request. Null pointers are rejected before dereferencing.
pub unsafe extern "C" fn twine_client_request_transcript(
    client: *mut TwineClient,
    terminal_id: u64,
    offset: u64,
    limit: u32,
    out_request: *mut *mut TwineTranscriptRequest,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: The caller guarantees aligned writable storage; null is checked.
        let output = unsafe { out_request.as_mut() }.ok_or(BridgeError::NullPointer)?;
        *output = std::ptr::null_mut();
        if limit == 0 || limit as usize > twine_core::MAX_TRANSCRIPT_READ_BYTES {
            return Err(BridgeError::InvalidArgument);
        }
        // SAFETY: The client is exclusively owned and alive for this call.
        let request = unsafe {
            ffi::with_client(client, |client| {
                client.request_terminal_transcript(terminal_id, offset, limit as usize)
            })
        }?
        .ok_or(BridgeError::Empty)?;
        *output = Box::into_raw(Box::new(TwineTranscriptRequest(request)));
        Ok(())
    })
}

#[unsafe(no_mangle)]
/// Polls a transcript request without waiting for storage. Empty means it is still pending.
///
/// # Safety
/// Non-null request must be live and exclusively owned. Non-null output must be aligned writable
/// storage without an unreleased allocation. Null pointers are rejected before dereferencing.
pub unsafe extern "C" fn twine_transcript_request_poll(
    request: *mut TwineTranscriptRequest,
    out_page: *mut TwineBuffer,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Output meets the buffer contract, and the helper checks null.
        unsafe { ffi::initialize_buffer(out_page) }?;
        // SAFETY: The caller keeps its exclusively owned request alive through this call.
        let request = unsafe { request.as_ref() }.ok_or(BridgeError::NullPointer)?;
        let page = request
            .0
            .poll()
            .map_err(|error| {
                BridgeError::Application(twine_core::ApplicationError::Terminal(
                    twine_core::TerminalError::Transcript(error),
                ))
            })?
            .ok_or(BridgeError::Empty)?;
        // SAFETY: The output storage is valid as described above.
        unsafe {
            ffi::write_buffer(
                out_page,
                TwineBuffer::from_vec(client::encode_transcript(page)),
            )
        }
    })
}

#[unsafe(no_mangle)]
/// Releases a completed or canceled transcript request.
///
/// # Safety
/// A non-null pointer must be the unchanged live request returned by this bridge, and released once.
pub unsafe extern "C" fn twine_transcript_request_destroy(
    request: *mut TwineTranscriptRequest,
) -> TwineStatus {
    catch_status(|| {
        if request.is_null() {
            return Err(BridgeError::NullPointer);
        }
        // SAFETY: The caller returns this bridge-owned request exactly once.
        drop(unsafe { Box::from_raw(request) });
        Ok(())
    })
}

#[unsafe(no_mangle)]
/// Writes raw input bytes to a live terminal.
///
/// # Safety
///
/// An input larger than `MAX_TERMINAL_INPUT_BYTES` is rejected without reading `input_bytes`. For
/// a nonzero input at or below that limit, a null `input_bytes` is rejected; otherwise it must
/// identify `input_length` readable bytes for the duration of this call. A null `client` is
/// rejected; otherwise it must be live, correctly aligned, and exclusively owned for the call.
pub unsafe extern "C" fn twine_client_write_terminal_input(
    client: *mut TwineClient,
    terminal_id: u64,
    input_bytes: *const u8,
    input_length: usize,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Guaranteed by this function's input contract. The slice remains scoped to the
        // callback and is copied to the PTY before this call returns.
        unsafe {
            ffi::with_input_bytes(
                input_bytes,
                input_length,
                MAX_TERMINAL_INPUT_BYTES,
                |bytes| {
                    // SAFETY: The outer function's contract keeps the client alive for this call.
                    ffi::with_client(client, |client| {
                        client.write_terminal_input(terminal_id, bytes)
                    })
                },
            )
        }
    })
}

#[unsafe(no_mangle)]
/// Changes the dimensions of a live terminal's PTY.
///
/// # Safety
///
/// A null `client` is rejected; otherwise it must be live, correctly aligned, and exclusively
/// owned for the duration of this call.
pub unsafe extern "C" fn twine_client_resize_terminal(
    client: *mut TwineClient,
    terminal_id: u64,
    rows: u16,
    columns: u16,
    pixel_width: u16,
    pixel_height: u16,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Guaranteed by this function's client contract.
        unsafe {
            ffi::with_client(client, |client| {
                client.resize_terminal(
                    terminal_id,
                    TerminalSize {
                        rows,
                        columns,
                        pixel_width,
                        pixel_height,
                    },
                )
            })
        }
    })
}

#[unsafe(no_mangle)]
/// Releases a bridge buffer.
///
/// # Safety
///
/// A null `buffer` is rejected without dereferencing it. Otherwise it must point to aligned,
/// writable storage. A nonempty buffer must contain the unchanged allocation returned by this
/// bridge and must be released exactly once.
pub unsafe extern "C" fn twine_buffer_release(buffer: *mut TwineBuffer) -> TwineStatus {
    // SAFETY: Guaranteed by this function's contract.
    catch_status(|| unsafe { ffi::release_buffer(buffer) })
}

#[cfg(test)]
mod tests {
    use std::ffi::{OsStr, OsString};
    use std::path::PathBuf;
    use std::time::{Duration, Instant};

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    use tempfile::TempDir;

    use super::*;
    use crate::test_support::TEST_LOCK;

    struct EnvironmentOverride {
        key: &'static str,
        previous: Option<OsString>,
    }

    impl EnvironmentOverride {
        fn set(key: &'static str, value: &OsStr) -> Self {
            let previous = std::env::var_os(key);
            // SAFETY: Bridge tests that override the environment hold `TEST_LOCK`. Client
            // creation reads HOME synchronously, and terminal creation reads SHELL synchronously.
            unsafe { std::env::set_var(key, value) };
            Self { key, previous }
        }
    }

    impl Drop for EnvironmentOverride {
        fn drop(&mut self) {
            // SAFETY: The guard is dropped while its test still holds `TEST_LOCK`.
            unsafe {
                if let Some(previous) = &self.previous {
                    std::env::set_var(self.key, previous);
                } else {
                    std::env::remove_var(self.key);
                }
            }
        }
    }

    /// Creates a client with a fresh data directory, which must outlive the client.
    fn create_client() -> (TempDir, *mut TwineClient) {
        let data = tempfile::tempdir().expect("a data directory should be available");
        let client = create_client_in(data.path());
        (data, client)
    }

    fn create_client_in(data_directory: &Path) -> *mut TwineClient {
        let home = tempfile::tempdir().expect("an isolated home directory should be available");
        let _home_override = EnvironmentOverride::set("HOME", home.path().as_os_str());
        let path = data_directory
            .to_str()
            .expect("the test data directory should be UTF-8");
        let mut client = std::ptr::null_mut();
        assert_eq!(
            // SAFETY: The path bytes are live for the call and the output points to writable
            // storage for one client pointer.
            unsafe { twine_client_create(path.as_ptr(), path.len(), &raw mut client) },
            TwineStatus::Ok
        );
        assert!(!client.is_null());
        assert!(home.path().join(".config/twine/config.toml").is_file());
        client
    }

    fn send_command(client: *mut TwineClient, command: &str) -> serde_json::Value {
        let mut response = TwineBuffer::empty();
        assert_eq!(
            // SAFETY: The test client and command bytes are live and the output is empty.
            unsafe {
                twine_client_send_command(
                    client,
                    command.as_ptr(),
                    command.len(),
                    &raw mut response,
                )
            },
            TwineStatus::Ok
        );
        serde_json::from_slice(&take_buffer(response)).expect("the response should be JSON")
    }

    fn snapshot(client: *mut TwineClient) -> serde_json::Value {
        let mut snapshot = TwineBuffer::empty();
        assert_eq!(
            // SAFETY: The test client is live and the output storage is empty and writable.
            unsafe { twine_client_snapshot(client, &raw mut snapshot) },
            TwineStatus::Ok
        );
        serde_json::from_slice(&take_buffer(snapshot)).expect("the snapshot should be JSON")
    }

    fn events_after(client: *mut TwineClient, sequence: u64) -> serde_json::Value {
        let mut events = TwineBuffer::empty();
        assert_eq!(
            // SAFETY: The test client is live and the output storage is empty and writable.
            unsafe { twine_client_events_after(client, sequence, 16, &raw mut events) },
            TwineStatus::Ok
        );
        serde_json::from_slice(&take_buffer(events)).expect("the events should be JSON")
    }

    fn destroy(client: *mut TwineClient) {
        // SAFETY: The live test client is destroyed exactly once after all operations finish.
        assert_eq!(unsafe { twine_client_destroy(client) }, TwineStatus::Ok);
    }

    fn take_buffer(mut buffer: TwineBuffer) -> Vec<u8> {
        let bytes = if buffer.length == 0 {
            Vec::new()
        } else {
            // SAFETY: The buffer was returned by this bridge and remains owned until release.
            unsafe { std::slice::from_raw_parts(buffer.data, buffer.length) }.to_vec()
        };
        // SAFETY: This is the unchanged bridge allocation and has not been released.
        assert_eq!(
            unsafe { twine_buffer_release(&raw mut buffer) },
            TwineStatus::Ok
        );
        assert!(buffer.data.is_null());
        assert_eq!(buffer.length, 0);
        bytes
    }

    fn send_json_command(
        client: *mut TwineClient,
        command: &serde_json::Value,
    ) -> serde_json::Value {
        let command = serde_json::to_vec(&command).expect("test command should encode");
        let mut response = TwineBuffer::empty();
        assert_eq!(
            // SAFETY: The test client and command bytes are live and the output is empty.
            unsafe {
                twine_client_send_command(
                    client,
                    command.as_ptr(),
                    command.len(),
                    &raw mut response,
                )
            },
            TwineStatus::Ok
        );
        serde_json::from_slice(&take_buffer(response)).expect("command response should be JSON")
    }

    /// Writes a shell script that `SHELL` can point at, so a test controls what the terminal runs.
    fn write_test_shell(name: &str, script: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("twine-bridge-{name}-{}", std::process::id()));
        std::fs::write(&path, script).expect("test shell should be written");
        #[cfg(unix)]
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
            .expect("test shell should be executable");
        path
    }

    /// Starts a terminal in the current directory through the command ABI and returns its ID.
    fn start_terminal(client: *mut TwineClient, request_id: u64) -> u64 {
        let working_directory = std::env::current_dir().expect("current directory should exist");
        let response = send_json_command(
            client,
            &serde_json::json!({
                "requestId": request_id,
                "command": {
                    "type": "startTerminal",
                    "workingDirectory": working_directory,
                    "size": {
                        "rows": 24,
                        "columns": 80,
                        "pixelWidth": 800,
                        "pixelHeight": 480
                    }
                }
            }),
        );
        assert_eq!(response["status"], "accepted");

        let mut events = TwineBuffer::empty();
        assert_eq!(
            // SAFETY: The test client is live and the output storage is empty and writable.
            unsafe { twine_client_events_after(client, 0, 16, &raw mut events) },
            TwineStatus::Ok
        );
        let events: serde_json::Value =
            serde_json::from_slice(&take_buffer(events)).expect("terminal events should be JSON");
        events["events"]
            .as_array()
            .expect("events should be an array")
            .iter()
            .find_map(|event| {
                (event["event"]["requestId"] == request_id)
                    .then(|| event["event"]["result"]["terminalId"].as_u64())
                    .flatten()
            })
            .expect("start event should include the terminal ID")
    }

    #[test]
    fn trace_reads_validate_limits_pointers_and_release_their_buffers() {
        let _guard = TEST_LOCK.lock().unwrap();
        let (data, client) = create_client();
        let folder = tempfile::tempdir().unwrap();
        send_json_command(
            client,
            &serde_json::json!({"requestId":1,"command":{"type":"openFolder", "path":folder.path()}}),
        );
        send_json_command(
            client,
            &serde_json::json!({"requestId":2,"command":{"type":"createWorkflow", "folder":folder.path(), "kind":"terminal", "size":{"rows":24,"columns":80,"pixelWidth":800,"pixelHeight":480}}}),
        );
        let workflow_id = snapshot(client)["workflows"]["workflows"][0]["workflowId"]
            .as_u64()
            .unwrap();
        let mut buffer = TwineBuffer::empty();
        // SAFETY: All output storage and client handles are valid, except intentional null tests.
        unsafe {
            assert_eq!(
                twine_client_workflow_trace(client, workflow_id, 0, 0, &raw mut buffer),
                TwineStatus::InvalidArgument
            );
            assert!(buffer.data.is_null());
            assert_eq!(
                twine_client_workflow_trace(
                    std::ptr::null_mut(),
                    workflow_id,
                    0,
                    10,
                    &raw mut buffer
                ),
                TwineStatus::NullPointer
            );
            assert_eq!(
                twine_client_workflow_trace(client, workflow_id, 0, 10, std::ptr::null_mut()),
                TwineStatus::NullPointer
            );
            assert_eq!(
                twine_client_workflow_trace(client, workflow_id, 0, 10, &raw mut buffer),
                TwineStatus::Ok
            );
        }
        let page: serde_json::Value = serde_json::from_slice(&take_buffer(buffer)).unwrap();
        let span_id = page["spans"][0]["spanId"].as_u64().unwrap();
        assert_eq!(page["summary"]["agentCount"], 0);
        assert_eq!(page["spans"][0]["isLive"], true);
        let mut buffer = TwineBuffer::empty();
        // SAFETY: Live client and initialized writable output buffer.
        unsafe {
            assert_eq!(
                twine_client_trace_events(client, span_id, 0, 10, &raw mut buffer),
                TwineStatus::Ok
            );
        }
        let page: serde_json::Value = serde_json::from_slice(&take_buffer(buffer)).unwrap();
        assert_eq!(page["events"][0]["kind"], "processStarted");
        assert_eq!(page["events"][0]["anchor"]["byteOffset"], 0);
        let mut buffer = TwineBuffer::empty();
        // SAFETY: Invalid limits/IDs must return initialized empty outputs.
        unsafe {
            assert_eq!(
                twine_client_trace_events(client, span_id, 0, 201, &raw mut buffer),
                TwineStatus::InvalidArgument
            );
            assert_eq!(
                twine_client_trace_events(client, u64::MAX, 0, 10, &raw mut buffer),
                TwineStatus::InternalError
            );
        }
        destroy(client);
        drop(data);
        assert_eq!(ffi::live_buffer_count(), 0);
    }

    #[test]
    fn command_round_trip_and_event_stream_preserve_request_id() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let (_data, client) = create_client();
        let mut snapshot = TwineBuffer::empty();
        assert_eq!(
            // SAFETY: The test client is live and the output storage is empty and writable.
            unsafe { twine_client_snapshot(client, &raw mut snapshot) },
            TwineStatus::Ok
        );
        let snapshot: serde_json::Value =
            serde_json::from_slice(&take_buffer(snapshot)).expect("snapshot should be JSON");
        let sequence = snapshot["sequence"]
            .as_u64()
            .expect("sequence should be an integer");

        let command = br#"{"requestId":42,"command":{"type":"ping"}}"#;
        let mut response = TwineBuffer::empty();
        assert_eq!(
            // SAFETY: The test client and command bytes are live and the output is empty.
            unsafe {
                twine_client_send_command(
                    client,
                    command.as_ptr(),
                    command.len(),
                    &raw mut response,
                )
            },
            TwineStatus::Ok
        );
        let response: serde_json::Value =
            serde_json::from_slice(&take_buffer(response)).expect("response should be JSON");
        assert_eq!(response["requestId"], 42);
        assert_eq!(response["status"], "accepted");

        let mut events = TwineBuffer::empty();
        assert_eq!(
            // SAFETY: The test client is live and the output storage is empty and writable.
            unsafe { twine_client_events_after(client, sequence, 16, &raw mut events) },
            TwineStatus::Ok
        );
        let events: serde_json::Value =
            serde_json::from_slice(&take_buffer(events)).expect("events should be JSON");
        assert_eq!(events["events"][0]["sequence"], sequence + 1);
        assert_eq!(events["events"][0]["event"]["requestId"], 42);
        assert_eq!(events["events"][0]["event"]["result"]["type"], "pong");

        // SAFETY: The live test client is destroyed exactly once after all operations finish.
        assert_eq!(unsafe { twine_client_destroy(client) }, TwineStatus::Ok);
    }

    #[test]
    fn unsupported_and_malformed_commands_are_errors_not_panics() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let (_data, client) = create_client();
        let unknown = br#"{"requestId":9,"command":{"type":"launchMoon"}}"#;
        let mut response = TwineBuffer::empty();
        assert_eq!(
            // SAFETY: The test client and command bytes are live and the output is empty.
            unsafe {
                twine_client_send_command(
                    client,
                    unknown.as_ptr(),
                    unknown.len(),
                    &raw mut response,
                )
            },
            TwineStatus::Ok
        );
        let response_json: serde_json::Value =
            serde_json::from_slice(&take_buffer(response)).expect("response should be JSON");
        assert_eq!(response_json["requestId"], 9);
        assert_eq!(response_json["status"], "rejected");

        let malformed = b"not json";
        let mut malformed_response = TwineBuffer::empty();
        assert_eq!(
            // SAFETY: The test client and input bytes are live and the output is empty.
            unsafe {
                twine_client_send_command(
                    client,
                    malformed.as_ptr(),
                    malformed.len(),
                    &raw mut malformed_response,
                )
            },
            TwineStatus::MalformedCommand
        );
        assert!(malformed_response.data.is_null());

        let invalid_utf8 = [0xff];
        assert_eq!(
            // SAFETY: The test client and input bytes are live and the output is empty.
            unsafe {
                twine_client_send_command(
                    client,
                    invalid_utf8.as_ptr(),
                    invalid_utf8.len(),
                    &raw mut malformed_response,
                )
            },
            TwineStatus::InvalidUtf8
        );
        // SAFETY: The live test client is destroyed exactly once after all operations finish.
        assert_eq!(unsafe { twine_client_destroy(client) }, TwineStatus::Ok);
    }

    #[test]
    fn exported_functions_reject_invalid_arguments_and_initialize_outputs() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let data = tempfile::tempdir().expect("a data directory should be available");
        let path = data
            .path()
            .to_str()
            .expect("the test data directory should be UTF-8");
        assert_eq!(
            // SAFETY: A null output is permitted by the ABI contract and rejected by the bridge.
            unsafe { twine_client_create(path.as_ptr(), path.len(), std::ptr::null_mut()) },
            TwineStatus::NullPointer
        );
        let mut rejected = std::ptr::dangling_mut::<TwineClient>();
        for (bytes, length, status) in [
            // A nonzero length requires a readable pointer.
            (std::ptr::null(), 1, TwineStatus::NullPointer),
            (b"relative".as_ptr(), 8, TwineStatus::InvalidArgument),
            (b"".as_ptr(), 0, TwineStatus::InvalidArgument),
            (b"/\xff".as_ptr(), 2, TwineStatus::InvalidUtf8),
            // An oversized length is rejected before the pointer is read.
            (
                path.as_ptr(),
                MAX_PATH_BYTES + 1,
                TwineStatus::InvalidArgument,
            ),
        ] {
            assert_eq!(
                // SAFETY: Each input is either rejected before it is read or identifies `length`
                // live bytes; the output points to writable storage for one client pointer.
                unsafe { twine_client_create(bytes, length, &raw mut rejected) },
                status
            );
            assert!(rejected.is_null());
        }

        let (_data, client) = create_client();
        let byte = 0_u8;
        let mut response = TwineBuffer {
            data: std::ptr::dangling_mut::<u8>(),
            length: 99,
        };
        assert_eq!(
            // SAFETY: The intentionally null input is rejected before it is dereferenced; the
            // client and output storage are valid.
            unsafe { twine_client_send_command(client, std::ptr::null(), 1, &raw mut response) },
            TwineStatus::NullPointer
        );
        assert!(response.data.is_null());
        assert_eq!(response.length, 0);

        assert_eq!(
            // SAFETY: Zero-length input does not require a readable pointer; other arguments are
            // valid.
            unsafe { twine_client_send_command(client, std::ptr::null(), 0, &raw mut response) },
            TwineStatus::MalformedCommand
        );
        assert!(response.data.is_null());
        assert_eq!(
            // SAFETY: The oversized length is rejected before the one-byte pointer is read.
            unsafe {
                twine_client_send_command(
                    client,
                    &raw const byte,
                    MAX_COMMAND_BYTES + 1,
                    &raw mut response,
                )
            },
            TwineStatus::InvalidArgument
        );
        assert!(response.data.is_null());

        assert_eq!(
            // SAFETY: The test client is live and the output storage is empty and writable.
            unsafe { twine_client_events_after(client, 0, 0, &raw mut response) },
            TwineStatus::InvalidArgument
        );
        assert!(response.data.is_null());
        assert_eq!(
            // SAFETY: The test client is live and the output storage is empty and writable.
            unsafe {
                twine_client_events_after(
                    client,
                    0,
                    u32::try_from(MAX_EVENT_BATCH + 1).expect("test limit should fit"),
                    &raw mut response,
                )
            },
            TwineStatus::InvalidArgument
        );
        assert!(response.data.is_null());

        let mut chunk = TwineTerminalChunk {
            terminal_id: 99,
            offset: 99,
            bytes: TwineBuffer {
                data: std::ptr::dangling_mut::<u8>(),
                length: 99,
            },
        };
        assert_eq!(
            // SAFETY: The test client is live and the output storage has no live allocation.
            unsafe { twine_client_next_terminal_chunk(client, &raw mut chunk) },
            TwineStatus::Empty
        );
        assert_eq!(chunk.terminal_id, 0);
        assert_eq!(chunk.offset, 0);
        assert!(chunk.bytes.data.is_null());
        assert_eq!(
            // SAFETY: A null pointer is permitted by the ABI contract and rejected by the bridge.
            unsafe { twine_buffer_release(std::ptr::null_mut()) },
            TwineStatus::NullPointer
        );
        // SAFETY: The live test client is destroyed exactly once after all operations finish.
        assert_eq!(unsafe { twine_client_destroy(client) }, TwineStatus::Ok);
    }

    #[test]
    fn transcript_requests_validate_pointers_limits_and_initialize_outputs() {
        let mut request = std::ptr::dangling_mut::<TwineTranscriptRequest>();
        // SAFETY: Output storage is valid, and null clients/invalid limits are rejected before access.
        assert_eq!(
            unsafe {
                twine_client_request_transcript(std::ptr::null_mut(), 1, 0, 0, &raw mut request)
            },
            TwineStatus::InvalidArgument
        );
        assert!(request.is_null());
        // SAFETY: Null pointers are rejected before dereferencing.
        assert_eq!(
            unsafe {
                twine_client_request_transcript(std::ptr::null_mut(), 1, 0, 1, &raw mut request)
            },
            TwineStatus::NullPointer
        );
        let mut buffer = TwineBuffer::empty();
        // SAFETY: Valid empty output storage and a null request are checked by the bridge.
        assert_eq!(
            unsafe { twine_transcript_request_poll(std::ptr::null_mut(), &raw mut buffer) },
            TwineStatus::NullPointer
        );
        assert!(buffer.data.is_null());
        assert_eq!(buffer.length, 0);
        // SAFETY: A null request is rejected without reconstructing a box.
        assert_eq!(
            unsafe { twine_transcript_request_destroy(std::ptr::null_mut()) },
            TwineStatus::NullPointer
        );
    }

    #[test]
    fn terminal_functions_reject_invalid_arguments() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let (_data, client) = create_client();
        let byte = 0_u8;
        assert_eq!(
            // SAFETY: The null input is intentionally paired with a nonzero length and must be
            // rejected before it is read.
            unsafe { twine_client_write_terminal_input(client, 1, std::ptr::null(), 1) },
            TwineStatus::NullPointer
        );
        assert_eq!(
            // SAFETY: The oversized length must be rejected before the one-byte pointer is read.
            unsafe {
                twine_client_write_terminal_input(
                    client,
                    1,
                    &raw const byte,
                    MAX_TERMINAL_INPUT_BYTES + 1,
                )
            },
            TwineStatus::InvalidArgument
        );
        assert_eq!(
            // SAFETY: The client is live; the invalid size is rejected by the core.
            unsafe { twine_client_resize_terminal(client, 1, 0, 80, 800, 480) },
            TwineStatus::InvalidArgument
        );
        assert_eq!(
            // SAFETY: A null client is permitted by the ABI contract and rejected by the bridge.
            unsafe { twine_client_resize_terminal(std::ptr::null_mut(), 1, 24, 80, 800, 480) },
            TwineStatus::NullPointer
        );
        destroy(client);
    }

    #[test]
    fn terminal_stream_preserves_binary_bytes_and_absolute_offset() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let shell_path = write_test_shell(
            "binary-shell",
            "#!/bin/sh\nprintf '\\000\\377a'\nexec cat\n",
        );
        let _shell_override = EnvironmentOverride::set("SHELL", shell_path.as_os_str());
        let (_data, client) = create_client();
        let terminal_id = start_terminal(client, 60);

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut first_offset = None;
        let mut output = Vec::new();
        while output.len() < 3 {
            let mut chunk = TwineTerminalChunk::empty();
            match
                // SAFETY: The test client is live and the output storage is empty and writable.
                unsafe { twine_client_next_terminal_chunk(client, &raw mut chunk) }
            {
                TwineStatus::Ok => {
                    assert_eq!(chunk.terminal_id, terminal_id);
                    first_offset.get_or_insert(chunk.offset);
                    output.extend(take_buffer(chunk.bytes));
                }
                TwineStatus::Empty => std::thread::sleep(Duration::from_millis(5)),
                status => panic!("terminal output failed with {status:?}"),
            }
            assert!(Instant::now() < deadline, "terminal output did not arrive");
        }
        assert_eq!(first_offset, Some(0));
        assert_eq!(&output[..3], &[0, 0xff, b'a']);

        // SAFETY: The live test client is destroyed exactly once after all operations finish.
        assert_eq!(unsafe { twine_client_destroy(client) }, TwineStatus::Ok);
        std::fs::remove_file(shell_path).expect("test shell should be removed");
    }

    #[test]
    fn immediately_exiting_shell_reports_its_start_before_its_exit() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let shell_path = write_test_shell("exiting-shell", "#!/bin/sh\nexit 3\n");
        let _shell_override = EnvironmentOverride::set("SHELL", shell_path.as_os_str());
        let (_data, client) = create_client();
        let terminal_id = start_terminal(client, 80);

        let deadline = Instant::now() + Duration::from_secs(5);
        let events = loop {
            let mut buffer = TwineBuffer::empty();
            assert_eq!(
                // SAFETY: The test client is live and the output storage is empty and writable.
                unsafe { twine_client_events_after(client, 0, 16, &raw mut buffer) },
                TwineStatus::Ok
            );
            let batch: serde_json::Value =
                serde_json::from_slice(&take_buffer(buffer)).expect("events should be JSON");
            let events = batch["events"]
                .as_array()
                .expect("events should be an array")
                .clone();
            if events
                .iter()
                .any(|event| event["event"]["type"] == "terminalExited")
            {
                break events;
            }
            assert!(Instant::now() < deadline, "shell exit was not reported");
            std::thread::sleep(Duration::from_millis(5));
        };
        let position = |predicate: &dyn Fn(&serde_json::Value) -> bool| {
            events
                .iter()
                .position(|event| predicate(&event["event"]))
                .expect("event should be present")
        };
        let started = position(&|event| event["requestId"] == 80);
        let exited = position(&|event| event["type"] == "terminalExited");
        assert!(started < exited);
        assert_eq!(events[exited]["event"]["terminalId"], terminal_id);
        assert_eq!(events[exited]["event"]["exitCode"], 3);

        let input = b"late input";
        assert_eq!(
            // SAFETY: The client and input are live; the exited terminal is still retained.
            unsafe {
                twine_client_write_terminal_input(client, terminal_id, input.as_ptr(), input.len())
            },
            TwineStatus::TerminalNotRunning
        );
        assert_eq!(
            // SAFETY: The client is live and the exited terminal is still retained.
            unsafe { twine_client_resize_terminal(client, terminal_id, 24, 80, 800, 480) },
            TwineStatus::TerminalNotRunning
        );

        // SAFETY: The live test client is destroyed exactly once after all operations finish.
        assert_eq!(unsafe { twine_client_destroy(client) }, TwineStatus::Ok);
        std::fs::remove_file(shell_path).expect("test shell should be removed");
    }

    #[test]
    fn resize_abi_updates_a_live_terminal() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let shell_path = write_test_shell("test-shell", "#!/bin/sh\nexec /bin/sh\n");
        let _shell_override = EnvironmentOverride::set("SHELL", shell_path.as_os_str());
        let (_data, client) = create_client();
        let terminal_id = start_terminal(client, 70);

        assert_eq!(
            // SAFETY: The client and terminal are live and exclusively accessed by this test.
            unsafe { twine_client_resize_terminal(client, terminal_id, 37, 101, 1_010, 740) },
            TwineStatus::Ok
        );
        let input = b"stty size\nexit\n";
        assert_eq!(
            // SAFETY: The client and input bytes are live for the duration of the call.
            unsafe {
                twine_client_write_terminal_input(client, terminal_id, input.as_ptr(), input.len())
            },
            TwineStatus::Ok
        );

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut output = Vec::new();
        while !String::from_utf8_lossy(&output).contains("37 101") {
            let mut chunk = TwineTerminalChunk::empty();
            match
                // SAFETY: The test client is live and the output storage is empty and writable.
                unsafe { twine_client_next_terminal_chunk(client, &raw mut chunk) }
            {
                TwineStatus::Ok => output.extend(take_buffer(chunk.bytes)),
                TwineStatus::Empty => std::thread::sleep(Duration::from_millis(5)),
                status => panic!("terminal output failed with {status:?}"),
            }
            assert!(
                Instant::now() < deadline,
                "resized dimensions did not reach the shell; output: {}",
                String::from_utf8_lossy(&output)
            );
        }

        let close_response = send_json_command(
            client,
            &serde_json::json!({
                "requestId": 71,
                "command": {
                    "type": "closeTerminal",
                    "terminalId": terminal_id
                }
            }),
        );
        assert_eq!(close_response["status"], "accepted");

        // SAFETY: The live test client is destroyed exactly once after all operations finish.
        assert_eq!(unsafe { twine_client_destroy(client) }, TwineStatus::Ok);
        std::fs::remove_file(shell_path).expect("test shell should be removed");
    }

    #[test]
    fn repeated_buffer_release_returns_live_count_to_zero() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let (_data, client) = create_client();
        let command = br#"{"requestId":1,"command":{"type":"ping"}}"#;

        for _ in 0..10_000 {
            let mut response = TwineBuffer::empty();
            assert_eq!(
                // SAFETY: The test client and input bytes are live and the output is empty.
                unsafe {
                    twine_client_send_command(
                        client,
                        command.as_ptr(),
                        command.len(),
                        &raw mut response,
                    )
                },
                TwineStatus::Ok
            );
            let _ = take_buffer(response);
        }

        assert_eq!(ffi::live_buffer_count(), 0);
        // SAFETY: The live test client is destroyed exactly once after all operations finish.
        assert_eq!(unsafe { twine_client_destroy(client) }, TwineStatus::Ok);
    }

    #[test]
    fn folder_commands_round_trip_through_snapshot_and_events() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let (_data, client) = create_client();
        let folder = tempfile::tempdir().expect("a folder should be available");
        let path = folder
            .path()
            .to_str()
            .expect("the test folder should be UTF-8");
        let initial = snapshot(client);
        assert_eq!(
            initial["folders"],
            serde_json::json!({"openFolder": null, "recentFolders": [], "unavailableFolder": null, "currentBranch": null})
        );

        let command = serde_json::json!({
            "requestId": 1,
            "command": {"type": "openFolder", "path": path},
        });
        assert_eq!(
            send_command(client, &command.to_string())["status"],
            "accepted"
        );
        let sequence = initial["sequence"]
            .as_u64()
            .expect("sequence should be an integer");
        let events = events_after(client, sequence);
        assert_eq!(events["events"][0]["event"]["type"], "foldersChanged");
        let opened = serde_json::json!({
            "openFolder": path,
            "recentFolders": [{"path": path, "isMissing": false}],
            "unavailableFolder": null, "currentBranch": null,
        });
        assert_eq!(events["events"][0]["event"]["folders"], opened);
        assert_eq!(snapshot(client)["folders"], opened);

        let response = send_command(
            client,
            r#"{"requestId":2,"command":{"type":"closeFolder"}}"#,
        );
        assert_eq!(response["status"], "accepted");
        assert_eq!(
            snapshot(client)["folders"]["openFolder"],
            serde_json::Value::Null
        );

        let command = serde_json::json!({
            "requestId": 3,
            "command": {"type": "removeRecentFolder", "path": path},
        });
        assert_eq!(
            send_command(client, &command.to_string())["status"],
            "accepted"
        );
        assert_eq!(
            snapshot(client)["folders"]["recentFolders"],
            serde_json::json!([])
        );
        destroy(client);
    }

    #[test]
    fn folder_commands_reject_missing_folders_and_require_a_path() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let (_data, client) = create_client();
        let missing = {
            let folder = tempfile::tempdir().expect("a folder should be available");
            folder
                .path()
                .to_str()
                .expect("the test folder should be UTF-8")
                .to_owned()
        }; // Dropping `folder` deletes it.

        let command = serde_json::json!({
            "requestId": 1,
            "command": {"type": "openFolder", "path": missing},
        });
        let response = send_command(client, &command.to_string());
        assert_eq!(response["status"], "rejected");
        assert_eq!(response["error"]["code"], "folderNotFound");
        assert_eq!(
            snapshot(client)["folders"]["unavailableFolder"],
            serde_json::json!({"path": missing, "reason": "missing"})
        );

        let without_path = br#"{"requestId":2,"command":{"type":"openFolder"}}"#;
        let mut response = TwineBuffer::empty();
        assert_eq!(
            // SAFETY: The test client and command bytes are live and the output is empty.
            unsafe {
                twine_client_send_command(
                    client,
                    without_path.as_ptr(),
                    without_path.len(),
                    &raw mut response,
                )
            },
            TwineStatus::MalformedCommand
        );
        assert!(response.data.is_null());
        destroy(client);
    }

    #[test]
    fn a_new_client_reopens_the_last_folder_from_its_data_directory() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let (data, client) = create_client();
        let folder = tempfile::tempdir().expect("a folder should be available");
        let path = folder
            .path()
            .to_str()
            .expect("the test folder should be UTF-8");
        let command = serde_json::json!({
            "requestId": 1,
            "command": {"type": "openFolder", "path": path},
        });
        assert_eq!(
            send_command(client, &command.to_string())["status"],
            "accepted"
        );
        destroy(client);

        let relaunched = create_client_in(data.path());
        assert_eq!(snapshot(relaunched)["folders"]["openFolder"], path);
        destroy(relaunched);
    }
    fn poll(client: *mut TwineClient, bytes: &[u8]) -> (TwineStatus, TwineBuffer) {
        let mut output = TwineBuffer::empty();
        // SAFETY: The test client and byte slice stay live; output is writable and owns no allocation.
        let status = unsafe {
            twine_client_poll_files(client, bytes.as_ptr(), bytes.len(), &raw mut output)
        };
        (status, output)
    }

    #[test]
    fn file_snapshots_release_buffers_and_unchanged_polls_are_empty() {
        let _guard = TEST_LOCK.lock().unwrap();
        let (_data, client) = create_client();
        let folder = tempfile::tempdir().unwrap();
        let file = folder.path().join("readme.txt");
        std::fs::write(&file, "hello").unwrap();
        send_command(
            client,
            &serde_json::json!({"requestId": 1, "command": {
                "type": "openFolder", "path": folder.path()
            }})
            .to_string(),
        );
        let mut request =
            serde_json::json!({"folder": folder.path(), "directories": [], "file": file});
        let baseline = ffi::live_buffer_count();
        let deadline = Instant::now() + Duration::from_secs(2);
        let snapshot = loop {
            let (status, buffer) = poll(client, request.to_string().as_bytes());
            if status == TwineStatus::Ok {
                assert_eq!(ffi::live_buffer_count(), baseline + 1);
                break serde_json::from_slice::<serde_json::Value>(&take_buffer(buffer)).unwrap();
            }
            assert_eq!(status, TwineStatus::Empty);
            assert!(buffer.data.is_null());
            assert_eq!(buffer.length, 0);
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(ffi::live_buffer_count(), baseline);
        assert_eq!(snapshot["file"]["text"], "hello");
        assert_eq!(snapshot["textLimit"], 2 * 1024 * 1024);
        request["revision"] = snapshot["revision"].clone();
        let (status, buffer) = poll(client, request.to_string().as_bytes());
        assert_eq!(status, TwineStatus::Empty);
        assert!(buffer.data.is_null());
        assert_eq!(buffer.length, 0);
        send_command(
            client,
            r#"{"requestId":2,"command":{"type":"closeFolder"}}"#,
        );
        assert_eq!(
            poll(client, request.to_string().as_bytes()).0,
            TwineStatus::InvalidArgument
        );
        destroy(client);
    }

    #[test]
    fn file_poll_rejects_invalid_input_without_allocating() {
        let _guard = TEST_LOCK.lock().unwrap();
        let (_data, client) = create_client();
        for (bytes, expected) in [
            (b"{".as_slice(), TwineStatus::MalformedCommand),
            (&[0xff], TwineStatus::InvalidUtf8),
        ] {
            let (status, output) = poll(client, bytes);
            assert_eq!(status, expected);
            assert!(output.data.is_null());
            assert_eq!(output.length, 0);
        }
        let mut output = TwineBuffer::empty();
        // SAFETY: Invalid inputs are rejected before dereference; output is valid writable storage.
        unsafe {
            assert_eq!(
                twine_client_poll_files(client, std::ptr::null(), 1, &raw mut output),
                TwineStatus::NullPointer
            );
            assert_eq!(
                twine_client_poll_files(
                    client,
                    std::ptr::null(),
                    MAX_COMMAND_BYTES + 1,
                    &raw mut output
                ),
                TwineStatus::InvalidArgument
            );
            assert_eq!(
                twine_client_poll_files(client, std::ptr::null(), 0, std::ptr::null_mut()),
                TwineStatus::NullPointer
            );
            let request = b"{}";
            assert_eq!(
                twine_client_poll_files(
                    std::ptr::null_mut(),
                    request.as_ptr(),
                    request.len(),
                    &raw mut output
                ),
                TwineStatus::NullPointer
            );
        }
        assert!(output.data.is_null());
        assert_eq!(output.length, 0);
        destroy(client);
    }

    #[test]
    fn file_saves_return_versions_conflicts_failures_and_release_buffers() {
        let _guard = TEST_LOCK.lock().unwrap();
        let (_data, client) = create_client();
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("file");
        std::fs::write(&path, "original").unwrap();
        send_command(
            client,
            &serde_json::json!({"requestId": 1,
            "command": {"type": "openFolder", "path": root.path()}})
            .to_string(),
        );
        let query = serde_json::json!({"folder": root.path(), "directories": [], "file": path});
        let deadline = Instant::now() + Duration::from_secs(2);
        let preview = loop {
            let (status, buffer) = poll(client, query.to_string().as_bytes());
            if status == TwineStatus::Ok {
                break serde_json::from_slice::<serde_json::Value>(&take_buffer(buffer)).unwrap()["file"].clone();
            }
            assert_eq!(status, TwineStatus::Empty);
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        };
        let mut request = serde_json::json!({"folder": root.path(), "path": path,
            "text": "edited", "expectedVersion": preview["version"], "overwrite": false});
        let saved = save_json(client, &request);
        assert_eq!(saved["status"], "saved");
        assert_eq!(saved["file"]["text"], "edited");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "edited");
        request["expectedVersion"] = saved["file"]["version"].clone();
        std::fs::write(&path, "external").unwrap();
        let conflict = save_json(client, &request);
        assert_eq!(conflict["status"], "conflict");
        assert_eq!(conflict["file"]["text"], "external");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "external");
        request["overwrite"] = true.into();
        // Legal control whitespace expands in JSON, and must not inherit the 1 MiB command bound.
        request["text"] = "\u{b}".repeat(2 * 1024 * 1024).into();
        assert_eq!(save_json(client, &request)["status"], "saved");
        request["text"] = "x".repeat(2 * 1024 * 1024 + 1).into();
        assert_eq!(save_json(client, &request)["status"], "failed");
        send_command(
            client,
            r#"{"requestId":2,"command":{"type":"closeFolder"}}"#,
        );
        request["text"] = "small".into();
        let failure = save_json(client, &request);
        assert_eq!(failure["status"], "failed");
        assert!(
            failure["message"]
                .as_str()
                .unwrap()
                .contains("no longer open")
        );
        destroy(client);
    }

    fn save_json(client: *mut TwineClient, request: &serde_json::Value) -> serde_json::Value {
        let before = ffi::live_buffer_count();
        let bytes = request.to_string().into_bytes();
        let mut output = TwineBuffer::empty();
        // SAFETY: The live test client and input outlive the call; output is empty writable storage.
        assert_eq!(
            unsafe { twine_client_save_file(client, bytes.as_ptr(), bytes.len(), &raw mut output) },
            TwineStatus::Ok
        );
        assert_eq!(ffi::live_buffer_count(), before + 1);
        let value = serde_json::from_slice(&take_buffer(output)).unwrap();
        assert_eq!(ffi::live_buffer_count(), before);
        value
    }

    #[test]
    fn file_save_rejects_invalid_input_without_allocating() {
        let _guard = TEST_LOCK.lock().unwrap();
        let (_data, client) = create_client();
        let before = ffi::live_buffer_count();
        let mut output = TwineBuffer::empty();
        for (bytes, expected) in [
            (b"{".as_slice(), TwineStatus::MalformedCommand),
            (b"{}".as_slice(), TwineStatus::MalformedCommand),
            (&[0xff], TwineStatus::InvalidUtf8),
        ] {
            // SAFETY: The client and slice stay live and output is valid empty storage.
            assert_eq!(
                unsafe {
                    twine_client_save_file(client, bytes.as_ptr(), bytes.len(), &raw mut output)
                },
                expected
            );
            assert!(output.data.is_null());
        }
        // SAFETY: Invalid pointers/lengths are rejected before dereference; output is writable.
        unsafe {
            assert_eq!(
                twine_client_save_file(client, std::ptr::null(), 1, &raw mut output),
                TwineStatus::NullPointer
            );
            assert_eq!(
                twine_client_save_file(
                    client,
                    std::ptr::null(),
                    MAX_FILE_SAVE_BYTES + 1,
                    &raw mut output
                ),
                TwineStatus::InvalidArgument
            );
            assert_eq!(
                twine_client_save_file(client, std::ptr::null(), 0, std::ptr::null_mut()),
                TwineStatus::NullPointer
            );
            assert_eq!(
                twine_client_save_file(std::ptr::null_mut(), b"{}".as_ptr(), 2, &raw mut output),
                TwineStatus::NullPointer
            );
        }
        assert_eq!(ffi::live_buffer_count(), before);
        assert!(output.data.is_null());
        destroy(client);
    }
}
