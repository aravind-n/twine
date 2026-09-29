use std::sync::OnceLock;

use tracing_oslog::OsLogger;
use tracing_subscriber::prelude::*;

use crate::client::BridgeError;

const SUBSYSTEM: &str = "com.twineproject.Twine";
const CATEGORY: &str = "rust";

static INITIALIZATION: OnceLock<Result<(), String>> = OnceLock::new();

pub(crate) fn initialize() -> Result<(), BridgeError> {
    INITIALIZATION
        .get_or_init(|| {
            let subscriber =
                tracing_subscriber::registry().with(OsLogger::new(SUBSYSTEM, CATEGORY));
            tracing::subscriber::set_global_default(subscriber).map_err(|error| error.to_string())
        })
        .clone()
        .map_err(BridgeError::Subscriber)
}
