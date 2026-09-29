use std::sync::Mutex;

/// Serializes tests that change process-wide state: environment variables, and the tracing callsite
/// cache that a test logging from another thread can fill while a scoped subscriber is installed.
pub(crate) static TEST_LOCK: Mutex<()> = Mutex::new(());
