use super::error::BridgeError;
use super::ffi::{self, TwineBuffer, TwineStatus, catch_status};
use super::protocol::files::{Version, encode_preview, encode_save};
use serde::Deserialize;
use twine_core::memories::MemoryRequest;

#[unsafe(no_mangle)]
/// Lists local memory sources without an application runtime.
///
/// # Safety
/// Follows the bounded input and output ownership contracts in `twine_bridge.h`.
pub unsafe extern "C" fn twine_memory_catalog(
    bytes: *const u8,
    length: usize,
    output: *mut TwineBuffer,
) -> TwineStatus {
    // SAFETY: Forwarded caller contract, checked by the shared FFI helpers.
    unsafe { request(bytes, length, output, false) }
}

#[unsafe(no_mangle)]
/// Reads one discovered memory source by its opaque ID.
///
/// # Safety
/// Follows the bounded input and output ownership contracts in `twine_bridge.h`.
pub unsafe extern "C" fn twine_memory_read(
    bytes: *const u8,
    length: usize,
    output: *mut TwineBuffer,
) -> TwineStatus {
    // SAFETY: Forwarded caller contract, checked by the shared FFI helpers.
    unsafe { request(bytes, length, output, true) }
}

unsafe fn request(
    bytes: *const u8,
    length: usize,
    output: *mut TwineBuffer,
    read: bool,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Null is rejected before the output is initialized.
        unsafe { ffi::initialize_buffer(output) }?;
        // SAFETY: The caller provides readable input under the documented length bound.
        let response = unsafe {
            ffi::with_input_bytes(bytes, length, super::MAX_COMMAND_BYTES, |bytes| {
                let request: MemoryRequest =
                    serde_json::from_slice(bytes).map_err(|_| BridgeError::MalformedCommand)?;
                if read {
                    let read = twine_core::memories::read(&request)?;
                    let mut value = serde_json::to_value(&read)?;
                    value["file"] = read
                        .file
                        .as_ref()
                        .map_or(serde_json::Value::Null, encode_preview);
                    Ok(serde_json::to_vec(&value)?)
                } else {
                    Ok(serde_json::to_vec(&twine_core::memories::catalog(
                        &request,
                    )?)?)
                }
            })
        }?;
        // SAFETY: The output was validated before allocating an owned response.
        unsafe { ffi::write_buffer(output, TwineBuffer::from_vec(response)) }
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SaveRequest {
    source: MemoryRequest,
    text: String,
    expected_version: Version,
    overwrite: bool,
}

#[unsafe(no_mangle)]
/// Saves one discovered local Markdown file after checking its disk version.
///
/// # Safety
/// Follows the bounded input and output ownership contracts in `twine_bridge.h`.
pub unsafe extern "C" fn twine_memory_save(
    bytes: *const u8,
    length: usize,
    output: *mut TwineBuffer,
) -> TwineStatus {
    catch_status(|| {
        // SAFETY: Null is rejected before initialization; input uses the shared bound.
        unsafe { ffi::initialize_buffer(output) }?;
        // SAFETY: The caller supplies readable bytes; the helper rejects invalid lengths.
        let response = unsafe {
            ffi::with_input_bytes(bytes, length, super::MAX_FILE_SAVE_BYTES, |bytes| {
                let request: SaveRequest =
                    serde_json::from_slice(bytes).map_err(|_| BridgeError::MalformedCommand)?;
                Ok(encode_save(twine_core::memories::save(
                    &request.source,
                    request.text,
                    request.expected_version.into(),
                    request.overwrite,
                ))?)
            })
        }?;
        // SAFETY: The output was validated before allocating an owned response.
        unsafe { ffi::write_buffer(output, TwineBuffer::from_vec(response)) }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_calls_reject_invalid_pointers_and_oversized_requests() {
        let mut output = TwineBuffer::empty();
        // SAFETY: All rejected arguments are checked without dereferencing them.
        unsafe {
            assert_eq!(
                twine_memory_catalog(std::ptr::null(), 1, &raw mut output),
                TwineStatus::NullPointer
            );
            assert_eq!(
                twine_memory_read(
                    std::ptr::null(),
                    super::super::MAX_COMMAND_BYTES + 1,
                    &raw mut output
                ),
                TwineStatus::InvalidArgument
            );
            assert_eq!(
                twine_memory_catalog(std::ptr::null(), 0, std::ptr::null_mut()),
                TwineStatus::NullPointer
            );
            assert_eq!(
                twine_memory_save(std::ptr::null(), 1, &raw mut output),
                TwineStatus::NullPointer
            );
            assert_eq!(
                twine_memory_save(
                    std::ptr::null(),
                    super::super::MAX_FILE_SAVE_BYTES + 1,
                    &raw mut output
                ),
                TwineStatus::InvalidArgument
            );
        }
        assert!(output.data.is_null());
    }
}
