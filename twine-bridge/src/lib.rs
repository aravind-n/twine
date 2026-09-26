//! C ABI adapter for the Twine core.

#[allow(clippy::must_use_candidate)]
#[unsafe(no_mangle)]
pub extern "C" fn twine_bridge_add(left: u64, right: u64) -> u64 {
    twine_core::add(left, right)
}
