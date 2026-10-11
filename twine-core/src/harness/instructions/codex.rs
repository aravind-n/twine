//! Read effective Codex instructions through its native config API. No turn is started.
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::harness::LocatedHarness;
use crate::process::CommandChild;
use serde_json::{Value, json};

const TIMEOUT: Duration = Duration::from_secs(5);
const MAX_RESPONSE: u64 = 1024 * 1024;

pub(super) fn combined_instructions(
    located: &LocatedHarness,
    folder: &Path,
    role: &str,
) -> io::Result<String> {
    let (mut socket, child_socket) = UnixStream::pair()?;
    socket.set_write_timeout(Some(TIMEOUT))?;
    let input: OwnedFd = child_socket.try_clone()?.into();
    let output: OwnedFd = child_socket.into();
    let mut command = Command::new(&located.program);
    command
        .arg("app-server")
        .current_dir(folder)
        .env("PATH", &located.path)
        .stdin(Stdio::from(input))
        .stdout(Stdio::from(output))
        .stderr(Stdio::null());
    let mut child = CommandChild::spawn(&mut command)?;
    let deadline = Instant::now() + TIMEOUT;
    let mut reader = BufReader::new(socket.try_clone()?);
    send(
        &mut socket,
        &json!({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "twine", "version": env!("CARGO_PKG_VERSION")}}}),
    )?;
    response(&mut reader, 1, deadline)?;
    send(&mut socket, &json!({"method": "initialized"}))?;
    send(
        &mut socket,
        &json!({"id": 2, "method": "config/read", "params": {"includeLayers": false, "cwd": folder}}),
    )?;
    let config = response(&mut reader, 2, deadline)?;
    child.finish()?;
    if !config.get("config").is_some_and(Value::is_object) {
        return Err(io::Error::other(
            "Codex returned no effective configuration.",
        ));
    }
    let existing = config.pointer("/config/developer_instructions");
    match existing {
        None | Some(Value::Null) => Ok(role.to_owned()),
        Some(Value::String(text)) if text.is_empty() => Ok(role.to_owned()),
        Some(Value::String(text)) => Ok(format!("{text}\n\n{role}")),
        _ => Err(io::Error::other(
            "Codex returned an invalid instruction value.",
        )),
    }
}

fn send(socket: &mut UnixStream, value: &Value) -> io::Result<()> {
    serde_json::to_writer(&mut *socket, value)?;
    socket.write_all(b"\n")
}

fn response(reader: &mut BufReader<UnixStream>, id: u64, deadline: Instant) -> io::Result<Value> {
    let mut remaining = MAX_RESPONSE;
    loop {
        let timeout = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::TimedOut, "Codex config read timed out.")
            })?;
        reader.get_ref().set_read_timeout(Some(timeout))?;
        let mut bytes = Vec::new();
        let count = reader.take(remaining + 1).read_until(b'\n', &mut bytes)?;
        let count = u64::try_from(count).map_err(io::Error::other)?;
        if count == 0 || count > remaining {
            return Err(io::Error::other(
                "Codex config response is missing or too large.",
            ));
        }
        remaining -= count;
        let value: Value = serde_json::from_slice(&bytes)
            .map_err(|_| io::Error::other("Codex returned an invalid config response."))?;
        if value.get("id").and_then(Value::as_u64) == Some(id) {
            return value.get("result").cloned().ok_or_else(|| {
                io::Error::other("Codex could not read its effective configuration.")
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn effective_user_instructions_are_preserved_without_a_turn() {
        let directory = tempfile::tempdir().unwrap();
        let program = directory.path().join("codex");
        std::fs::write(
            &program,
            r#"#!/bin/sh
[ "$1" = app-server ] || exit 1
read init
printf '%s\n' '{"id":1,"result":{}}'
read initialized
read config
printf '%s\n' '{"id":2,"result":{"config":{"developer_instructions":"Existing instructions"}}}'
read end
"#,
        )
        .unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        let located = LocatedHarness {
            program,
            path: OsString::from("/usr/bin:/bin"),
        };
        assert_eq!(
            combined_instructions(&located, directory.path(), "Role instructions").unwrap(),
            "Existing instructions\n\nRole instructions"
        );
    }
}
