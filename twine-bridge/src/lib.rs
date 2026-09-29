//! C ABI adapter for the Twine core.

mod client;
mod ffi;
mod logging;
mod protocol;

use client::BridgeError;
use ffi::{TwineBuffer, TwineStatus, TwineTerminalChunk, catch_status};

pub use client::TwineClient;

const MAX_COMMAND_BYTES: usize = 1024 * 1024;
const MAX_EVENT_BATCH: usize = 256;

#[unsafe(no_mangle)]
/// Creates a bridge client.
///
/// # Safety
///
/// A null `out_client` is rejected without dereferencing it. Otherwise it must point to aligned,
/// writable storage for one client pointer.
pub unsafe extern "C" fn twine_client_create(out_client: *mut *mut TwineClient) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Guaranteed by this function's contract.
        unsafe { ffi::write_client(out_client, std::ptr::null_mut()) }?;
        logging::initialize()?;
        let client = Box::new(TwineClient::new()?);
        // SAFETY: Guaranteed by this function's contract.
        unsafe { ffi::write_client(out_client, Box::into_raw(client)) }
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
    use std::sync::Mutex;

    use tracing_subscriber::{Layer, prelude::*};

    use super::*;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn create_client() -> *mut TwineClient {
        let mut client = std::ptr::null_mut();
        // SAFETY: The output points to writable storage for one client pointer.
        assert_eq!(
            unsafe { twine_client_create(&raw mut client) },
            TwineStatus::Ok
        );
        assert!(!client.is_null());
        client
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

    #[test]
    fn command_round_trip_and_event_stream_preserve_request_id() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let client = create_client();
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
        let client = create_client();
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
        assert_eq!(
            // SAFETY: A null output is permitted by the ABI contract and rejected by the bridge.
            unsafe { twine_client_create(std::ptr::null_mut()) },
            TwineStatus::NullPointer
        );

        let client = create_client();
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
    fn terminal_stream_preserves_binary_bytes_and_absolute_offset() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let client = create_client();
        // SAFETY: The client is alive and actor-style exclusive access is maintained in this test.
        let client_ref = unsafe { &*client };
        let terminal_id = client_ref
            .application()
            .open_terminal()
            .expect("terminal should open");
        client_ref
            .application()
            .publish_terminal_output(terminal_id, vec![0, 0xff, b'a'])
            .expect("terminal output should fit");

        let mut chunk = TwineTerminalChunk::empty();
        assert_eq!(
            // SAFETY: The test client is live and the output storage is empty and writable.
            unsafe { twine_client_next_terminal_chunk(client, &raw mut chunk) },
            TwineStatus::Ok
        );
        assert_eq!(chunk.terminal_id, terminal_id.value());
        assert_eq!(chunk.offset, 0);
        assert_eq!(take_buffer(chunk.bytes), vec![0, 0xff, b'a']);

        // SAFETY: The live test client is destroyed exactly once after all operations finish.
        assert_eq!(unsafe { twine_client_destroy(client) }, TwineStatus::Ok);
    }

    #[test]
    fn repeated_buffer_release_returns_live_count_to_zero() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let client = create_client();
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
    fn panic_guard_returns_status_instead_of_unwinding() {
        let _guard = TEST_LOCK.lock().expect("test lock should be available");
        let status = ffi::catch_status(|| -> Result<(), BridgeError> {
            panic!("test panic");
        });
        assert_eq!(status, TwineStatus::Panic);
    }

    #[test]
    fn panic_guard_contains_diagnostic_subscriber_panics() {
        struct PanickingLayer;

        impl<S> Layer<S> for PanickingLayer
        where
            S: tracing::Subscriber,
        {
            fn on_event(
                &self,
                _event: &tracing::Event<'_>,
                _context: tracing_subscriber::layer::Context<'_, S>,
            ) {
                panic!("test subscriber panic");
            }
        }

        let subscriber = tracing_subscriber::registry().with(PanickingLayer);
        tracing::subscriber::with_default(subscriber, || {
            let status = ffi::catch_status(|| Err(BridgeError::InvalidArgument));
            assert_eq!(status, TwineStatus::Panic);
        });
    }
}
