//! Bounded structured activity from harness adapters, independent of terminal text.

use std::io::{self, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, sync_channel};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::terminal::{ReplayPosition, TerminalObservation};

pub(crate) const MAX_DETAIL_BYTES: usize = 2048;
const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;
const MAX_HEADER_BYTES: usize = 4096;
const REQUEST_TIMEOUT: Duration = Duration::from_millis(200);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum StepKind {
    Prompt,
    ToolStarted,
    ToolFinished,
    Responded,
}

#[derive(Clone, Debug)]
pub(crate) struct HarnessStep {
    pub kind: StepKind,
    pub turn_id: Option<String>,
    pub tool_call_id: Option<String>,
    pub title: String,
    pub detail: String,
}

impl HarnessStep {
    pub(crate) fn message(&self) -> String {
        if self.detail.is_empty() {
            self.title.clone()
        } else {
            format!("{}\n{}", self.title, self.detail)
        }
    }
}

pub(crate) fn truncate(value: &str, limit: usize) -> String {
    if value.len() <= limit {
        return value.to_owned();
    }
    let mut end = limit.saturating_sub("… [truncated]".len());
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}… [truncated]", &value[..end])
}

pub(crate) struct ObservedStep {
    pub step: HarnessStep,
    pub observation: TerminalObservation,
    pub received_at: Instant,
}

/// A private local HTTP endpoint. Hooks never wait on application state or SQLite. If its bounded
/// queue is full, recording is best effort and the harness continues without backpressure.
pub(crate) struct StepInbox {
    pub directory: tempfile::TempDir,
    pub socket_path: std::path::PathBuf,
    received: Receiver<ObservedStep>,
    cancelled: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl StepInbox {
    pub(crate) fn new(
        position: Arc<ReplayPosition>,
        adapter: fn(&[u8]) -> Option<HarnessStep>,
    ) -> io::Result<Self> {
        // macOS limits Unix socket paths to 104 bytes; its usual temporary directory is too long.
        let directory = tempfile::Builder::new()
            .prefix("twine-steps-")
            .tempdir_in("/tmp")?;
        let socket_path = directory.path().join("events.sock");
        let listener = UnixListener::bind(&socket_path)?;
        listener.set_nonblocking(true)?;
        let (sent, received) = sync_channel(256);
        let cancelled = Arc::new(AtomicBool::new(false));
        let stop = Arc::clone(&cancelled);
        let worker = crate::blocking_worker::spawn("harness-steps".into(), move || {
            while !stop.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        if let Some(body) = read_request(&mut stream)
                            && let Some(step) = adapter(&body)
                            && let Ok(observation) = position.observe()
                        {
                            let _ = sent.try_send(ObservedStep {
                                step,
                                observation,
                                received_at: Instant::now(),
                            });
                        }
                        // Empty output cannot inject context or control a harness decision.
                        let _ = stream.write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        })?;
        Ok(Self {
            directory,
            socket_path,
            received,
            cancelled,
            worker: Some(worker),
        })
    }

    pub(crate) fn take(&self, limit: usize) -> Vec<ObservedStep> {
        self.received.try_iter().take(limit).collect()
    }
}

impl Drop for StepInbox {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn read_request(stream: &mut UnixStream) -> Option<Vec<u8>> {
    stream.set_nonblocking(true).ok()?;
    let deadline = Instant::now() + REQUEST_TIMEOUT;
    let mut bytes = Vec::new();
    let mut body = None;
    let mut buffer = [0; 8192];
    while Instant::now() < deadline {
        match stream.read(&mut buffer) {
            Ok(0) => return None,
            Ok(count) => bytes.extend_from_slice(&buffer[..count]),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(1));
                continue;
            }
            Err(_) => return None,
        }
        if body.is_none() {
            if let Some(end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                if end > MAX_HEADER_BYTES {
                    return None;
                }
                let headers = std::str::from_utf8(&bytes[..end]).ok()?;
                let length = headers.lines().find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })?;
                if length > MAX_REQUEST_BYTES {
                    return None;
                }
                body = Some((end + 4, length));
            } else if bytes.len() > MAX_HEADER_BYTES {
                return None;
            }
        }
        if let Some((start, length)) = body
            && bytes.len() >= start + length
        {
            return Some(bytes[start..start + length].to_vec());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncation_preserves_utf8_and_marks_omitted_details() {
        let text = "☃".repeat(3000);
        let clipped = truncate(&text, MAX_DETAIL_BYTES);
        assert!(clipped.len() <= MAX_DETAIL_BYTES);
        assert!(clipped.ends_with("… [truncated]"));
        assert_eq!(truncate("small", MAX_DETAIL_BYTES), "small");
    }

    #[test]
    fn a_stalled_or_oversized_sender_cannot_hold_the_receiver() {
        let (mut client, mut server) = UnixStream::pair().unwrap();
        client
            .write_all(b"POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n")
            .unwrap();
        assert!(read_request(&mut server).is_none());
        let (mut client, mut server) = UnixStream::pair().unwrap();
        client
            .write_all(b"POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\nx")
            .unwrap();
        let started = Instant::now();
        assert!(read_request(&mut server).is_none());
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
