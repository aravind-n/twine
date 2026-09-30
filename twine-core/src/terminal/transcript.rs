use std::collections::VecDeque;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::thread::{self, JoinHandle};

use thiserror::Error;
use tracing::warn;

use super::{TerminalChunk, TerminalId};

mod storage;

use storage::Storage;

/// Maximum bytes returned by a single transcript read.
pub const MAX_TRANSCRIPT_READ_BYTES: usize = 64 * 1024;

/// A page of committed, unmodified terminal output. Offsets count bytes, not characters.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptPage {
    pub terminal_id: TerminalId,
    pub offset: u64,
    pub next_offset: u64,
    pub end_offset: u64,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TranscriptRead {
    Output(TranscriptPage),
    /// The requested history was pruned. `None` means no bytes remain for this terminal.
    Expired {
        terminal_id: TerminalId,
        requested_offset: u64,
        nearest_retained_offset: Option<u64>,
    },
}

#[derive(Debug, Error)]
pub enum TranscriptError {
    #[error("transcript storage is already owned by another application")]
    AlreadyOpen,
    #[error("transcript metadata is corrupt: {0}")]
    Corrupt(&'static str),
    #[error("transcript read limit must be between 1 and {MAX_TRANSCRIPT_READ_BYTES} bytes")]
    InvalidLimit,
    #[error("invalid transcript storage limits")]
    InvalidStorageLimits,
    #[error("transcript identifier or offset overflowed")]
    Overflow,
    #[error("terminal {terminal_id:?} has never been allocated")]
    NotFound { terminal_id: TerminalId },
    #[error("transcript offset {requested} is beyond the recorded end {end_offset}")]
    OutOfRange { requested: u64, end_offset: u64 },
    #[error("transcript operation was cancelled")]
    Cancelled,
    #[error("transcript recording is unavailable: {message}")]
    Unavailable { message: String },
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

#[derive(Clone, Copy, Debug)]
pub(super) struct Limits {
    segment_bytes: u64,
    terminal_bytes: u64,
    total_bytes: u64,
    terminal_count: usize,
    segment_count: usize,
    pending_bytes: usize,
    pending_jobs: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            segment_bytes: 1024 * 1024,
            terminal_bytes: 64 * 1024 * 1024,
            total_bytes: 512 * 1024 * 1024,
            terminal_count: 1024,
            segment_count: 512,
            pending_bytes: 4 * 1024 * 1024,
            pending_jobs: 256,
        }
    }
}

enum Job {
    Allocate(mpsc::SyncSender<Result<TerminalId, TranscriptError>>),
    Append(TerminalChunk),
    Read {
        terminal_id: TerminalId,
        offset: u64,
        limit: usize,
        reply: mpsc::SyncSender<Result<TranscriptRead, TranscriptError>>,
    },
}

impl Job {
    fn byte_count(&self) -> usize {
        match self {
            Self::Append(chunk) => chunk.bytes.len(),
            Self::Allocate(_) | Self::Read { .. } => 0,
        }
    }
}

struct Queue {
    jobs: VecDeque<Job>,
    bytes: usize,
    accepting: bool,
    failure: Option<String>,
}

struct Shared {
    queue: Mutex<Queue>,
    ready: Condvar,
    space: Condvar,
    limits: Limits,
}

pub(crate) struct TranscriptRecorder {
    shared: Arc<Shared>,
    worker: Mutex<Option<JoinHandle<()>>>,
    #[cfg(test)]
    temporary_directory: Option<tempfile::TempDir>,
}

impl TranscriptRecorder {
    pub(crate) fn open(path: &Path) -> Result<Self, TranscriptError> {
        Self::with_limits(path, Limits::default())
    }

    fn with_limits(path: &Path, limits: Limits) -> Result<Self, TranscriptError> {
        let storage = Storage::open(path, limits)?;
        let shared = Arc::new(Shared {
            queue: Mutex::new(Queue {
                jobs: VecDeque::new(),
                bytes: 0,
                accepting: true,
                failure: None,
            }),
            ready: Condvar::new(),
            space: Condvar::new(),
            limits,
        });
        let worker_shared = Arc::clone(&shared);
        let worker = thread::Builder::new()
            .name("terminal-transcripts".into())
            .spawn(move || run_worker(storage, &worker_shared))?;
        Ok(Self {
            shared,
            worker: Mutex::new(Some(worker)),
            #[cfg(test)]
            temporary_directory: None,
        })
    }

    #[cfg(test)]
    pub(crate) fn temporary() -> Result<Self, TranscriptError> {
        let directory = tempfile::tempdir()?;
        let mut recorder = Self::open(directory.path())?;
        recorder.temporary_directory = Some(directory);
        Ok(recorder)
    }

    #[cfg(test)]
    pub(crate) fn stall_worker(
        &self,
        terminal_id: TerminalId,
    ) -> mpsc::Receiver<Result<TranscriptRead, TranscriptError>> {
        // A normal read with a rendezvous reply holds the worker until the fixture receives or
        // drops its response. This exercises real queue backpressure without a fake publish path.
        let (reply, receiver) = mpsc::sync_channel(0);
        self.enqueue(
            Job::Read {
                terminal_id,
                offset: 0,
                limit: 1,
                reply,
            },
            None,
        )
        .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        // Each fixture has one stalled read for this terminal. Output may already be queued
        // behind it, so wait for this request to be taken rather than for global queue emptiness.
        while self
            .shared
            .queue
            .lock()
            .unwrap()
            .jobs
            .iter()
            .any(|job| matches!(job, Job::Read { terminal_id: id, .. } if *id == terminal_id))
        {
            assert!(
                std::time::Instant::now() < deadline,
                "worker did not reach the stalled request"
            );
            thread::yield_now();
        }
        receiver
    }

    #[cfg(test)]
    pub(crate) fn recording_queue_is_full(&self) -> bool {
        let queue = self.shared.queue.lock().unwrap();
        queue.jobs.len() >= self.shared.limits.pending_jobs
            || queue.bytes >= self.shared.limits.pending_bytes
    }

    #[cfg(test)]
    pub(crate) fn allocation_is_pending(&self) -> bool {
        self.shared
            .queue
            .lock()
            .unwrap()
            .jobs
            .iter()
            .any(|job| matches!(job, Job::Allocate(_)))
    }

    pub(crate) fn allocate(&self) -> Result<TerminalId, TranscriptError> {
        let (reply, result) = mpsc::sync_channel(1);
        self.enqueue(Job::Allocate(reply), None)?;
        result.recv().map_err(disconnected)?
    }

    pub(super) fn append(
        &self,
        chunk: TerminalChunk,
        cancelled: &AtomicBool,
    ) -> Result<(), TranscriptError> {
        self.enqueue(Job::Append(chunk), Some(cancelled))
    }

    pub(crate) fn read(
        &self,
        terminal_id: TerminalId,
        offset: u64,
        limit: usize,
    ) -> Result<TranscriptRead, TranscriptError> {
        if limit == 0 || limit > MAX_TRANSCRIPT_READ_BYTES {
            return Err(TranscriptError::InvalidLimit);
        }
        let (reply, result) = mpsc::sync_channel(1);
        self.enqueue(
            Job::Read {
                terminal_id,
                offset,
                limit,
                reply,
            },
            None,
        )?;
        // Reads share the ordered work queue: every previously accepted append is committed first.
        result.recv().map_err(disconnected)?
    }

    fn enqueue(&self, job: Job, cancelled: Option<&AtomicBool>) -> Result<(), TranscriptError> {
        let bytes = job.byte_count();
        if bytes > self.shared.limits.pending_bytes {
            return Err(TranscriptError::InvalidStorageLimits);
        }
        let mut queue = self.shared.queue.lock().map_err(poisoned)?;
        loop {
            if cancelled.is_some_and(|cancelled| cancelled.load(Ordering::Acquire)) {
                return Err(TranscriptError::Cancelled);
            }
            if let Some(message) = &queue.failure {
                return Err(TranscriptError::Unavailable {
                    message: message.clone(),
                });
            }
            if !queue.accepting {
                return Err(TranscriptError::Cancelled);
            }
            if queue.jobs.len() < self.shared.limits.pending_jobs
                && bytes <= self.shared.limits.pending_bytes - queue.bytes
            {
                queue.bytes += bytes;
                queue.jobs.push_back(job);
                self.shared.ready.notify_one();
                return Ok(());
            }
            queue = self.shared.space.wait(queue).map_err(poisoned)?;
        }
    }

    pub(super) fn wake_producers(&self) {
        // Pair with the queue lock so cancellation cannot be lost between checking and waiting.
        let _queue = self
            .shared
            .queue
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.shared.space.notify_all();
    }

    pub(crate) fn shutdown(&self) {
        {
            let mut queue = self
                .shared
                .queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            queue.accepting = false;
            self.shared.space.notify_all();
            self.shared.ready.notify_all();
        }
        if let Some(worker) = self
            .worker
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
            && worker.join().is_err()
        {
            warn!("terminal transcript worker panicked during shutdown");
        }
    }
}

impl Drop for TranscriptRecorder {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn run_worker(mut storage: Storage, shared: &Shared) {
    loop {
        let (job, failure) = {
            let mut queue = shared
                .queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            while queue.jobs.is_empty() && queue.accepting {
                queue = shared
                    .ready
                    .wait(queue)
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
            }
            let Some(job) = queue.jobs.pop_front() else {
                return;
            };
            queue.bytes -= job.byte_count();
            shared.space.notify_all();
            (job, queue.failure.clone())
        };
        match job {
            Job::Allocate(reply) => {
                let result = failure.map_or_else(|| storage.allocate(), unavailable);
                if let Err(error) = &result {
                    record_failure(shared, error);
                }
                let _ = reply.send(result);
            }
            Job::Append(chunk) => {
                if failure.is_none()
                    && let Err(error) = storage.append(&chunk)
                {
                    record_failure(shared, &error);
                }
            }
            Job::Read {
                terminal_id,
                offset,
                limit,
                reply,
            } => {
                let result =
                    failure.map_or_else(|| storage.read(terminal_id, offset, limit), unavailable);
                if let Err(error @ (TranscriptError::Io(_) | TranscriptError::Corrupt(_))) = &result
                {
                    record_failure(shared, error);
                }
                let _ = reply.send(result);
            }
        }
    }
}

fn record_failure(shared: &Shared, error: &TranscriptError) {
    let mut queue = shared
        .queue
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if queue.failure.is_none() {
        warn!(%error, "terminal transcript recording failed; live output remains available");
        queue.failure = Some(error.to_string());
    }
    shared.space.notify_all();
}

fn unavailable<T>(message: String) -> Result<T, TranscriptError> {
    Err(TranscriptError::Unavailable { message })
}

fn disconnected(error: mpsc::RecvError) -> TranscriptError {
    TranscriptError::Unavailable {
        message: error.to_string(),
    }
}

fn poisoned<T>(_: std::sync::PoisonError<T>) -> TranscriptError {
    TranscriptError::Unavailable {
        message: "transcript queue lock poisoned".into(),
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    fn output(
        recorder: &TranscriptRecorder,
        id: TerminalId,
        offset: u64,
        limit: usize,
    ) -> TranscriptPage {
        let TranscriptRead::Output(page) = recorder.read(id, offset, limit).unwrap() else {
            panic!("output should be retained");
        };
        page
    }

    fn append(recorder: &TranscriptRecorder, id: TerminalId, offset: u64, bytes: &[u8]) {
        recorder
            .append(
                TerminalChunk {
                    terminal_id: id,
                    offset,
                    bytes: bytes.to_vec(),
                },
                &AtomicBool::new(false),
            )
            .unwrap();
    }

    #[test]
    fn ordered_reads_flush_accepted_output_and_validate_page_limits() {
        let recorder = TranscriptRecorder::temporary().unwrap();
        let id = recorder.allocate().unwrap();
        append(&recorder, id, 0, &[0xff, 0, 0x1b]);
        append(&recorder, id, 3, b"[H");
        assert_eq!(output(&recorder, id, 1, 3).bytes, [0, 0x1b, b'[']);
        assert_eq!(output(&recorder, id, 4, 3).bytes, b"H");
        assert!(matches!(
            recorder.read(id, 0, 0),
            Err(TranscriptError::InvalidLimit)
        ));
        assert!(matches!(
            recorder.read(id, 0, MAX_TRANSCRIPT_READ_BYTES + 1),
            Err(TranscriptError::InvalidLimit)
        ));
        assert!(matches!(
            recorder.read(TerminalId::from_value(0), 0, 1),
            Err(TranscriptError::NotFound { .. })
        ));
        assert_eq!(
            output(&recorder, id, 0, 8).bytes,
            [0xff, 0, 0x1b, b'[', b'H']
        );
    }

    #[test]
    fn recording_queue_backpressure_is_released_by_processing_work() {
        let directory = tempfile::tempdir().unwrap();
        let limits = Limits {
            pending_bytes: 2,
            pending_jobs: 1,
            ..Limits::default()
        };
        let recorder = Arc::new(TranscriptRecorder::with_limits(directory.path(), limits).unwrap());
        let id = recorder.allocate().unwrap();
        let stalled = recorder.stall_worker(id);
        append(&recorder, id, 0, b"ab");
        let (sent, received) = mpsc::sync_channel(1);
        let recording = Arc::clone(&recorder);
        let publisher = thread::spawn(move || {
            let result = recording.append(
                TerminalChunk {
                    terminal_id: id,
                    offset: 2,
                    bytes: b"c".to_vec(),
                },
                &AtomicBool::new(false),
            );
            sent.send(result).unwrap();
        });
        assert!(matches!(
            received.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        stalled
            .recv_timeout(Duration::from_secs(2))
            .unwrap()
            .unwrap();
        received
            .recv_timeout(Duration::from_secs(2))
            .unwrap()
            .unwrap();
        publisher.join().unwrap();
        assert_eq!(output(&recorder, id, 0, 8).bytes, b"abc");
    }

    #[test]
    fn cancellation_wakes_a_recording_producer_without_discarding_accepted_output() {
        let directory = tempfile::tempdir().unwrap();
        let recorder = Arc::new(
            TranscriptRecorder::with_limits(
                directory.path(),
                Limits {
                    pending_bytes: 2,
                    pending_jobs: 1,
                    ..Limits::default()
                },
            )
            .unwrap(),
        );
        let id = recorder.allocate().unwrap();
        let stalled = recorder.stall_worker(id);
        append(&recorder, id, 0, b"ab");
        let cancelled = Arc::new(AtomicBool::new(false));
        let cancellation = Arc::clone(&cancelled);
        let recording = Arc::clone(&recorder);
        let (sent, received) = mpsc::sync_channel(1);
        let publisher = thread::spawn(move || {
            sent.send(recording.append(
                TerminalChunk {
                    terminal_id: id,
                    offset: 2,
                    bytes: b"c".to_vec(),
                },
                &cancellation,
            ))
            .unwrap();
        });
        assert!(matches!(
            received.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        cancelled.store(true, Ordering::Release);
        recorder.wake_producers();
        assert!(matches!(
            received.recv_timeout(Duration::from_secs(2)).unwrap(),
            Err(TranscriptError::Cancelled)
        ));
        publisher.join().unwrap();
        drop(stalled);
        assert_eq!(output(&recorder, id, 0, 8).bytes, b"ab");
    }

    #[test]
    fn orderly_shutdown_flushes_the_queue_and_releases_the_directory() {
        let directory = tempfile::tempdir().unwrap();
        let recorder = TranscriptRecorder::open(directory.path()).unwrap();
        let id = recorder.allocate().unwrap();
        append(&recorder, id, 0, b"pending");
        recorder.shutdown();
        let reopened = TranscriptRecorder::open(directory.path()).unwrap();
        assert_eq!(output(&reopened, id, 0, 8).bytes, b"pending");
        assert!(reopened.allocate().unwrap().value() > id.value());
        assert!(matches!(
            recorder.read(id, 0, 1),
            Err(TranscriptError::Cancelled)
        ));
    }

    #[test]
    fn storage_failures_are_explicit_and_release_waiting_producers() {
        let directory = tempfile::tempdir().unwrap();
        let recorder = Arc::new(
            TranscriptRecorder::with_limits(
                directory.path(),
                Limits {
                    pending_bytes: 2,
                    pending_jobs: 1,
                    ..Limits::default()
                },
            )
            .unwrap(),
        );
        let id = recorder.allocate().unwrap();
        let stalled = recorder.stall_worker(id);
        std::fs::create_dir(directory.path().join("metadata.next")).unwrap();
        append(&recorder, id, 0, b"ab");
        let (sent, received) = mpsc::sync_channel(1);
        let recording = Arc::clone(&recorder);
        let publisher = thread::spawn(move || {
            let result = recording.append(
                TerminalChunk {
                    terminal_id: id,
                    offset: 2,
                    bytes: b"cd".to_vec(),
                },
                &AtomicBool::new(false),
            );
            // It may be admitted just before the worker reports failure; its ordered read must
            // still report failure instead of claiming those bytes were recorded.
            sent.send(result.and_then(|()| recording.read(id, 0, 8)))
                .unwrap();
        });
        assert!(matches!(
            received.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        drop(stalled);
        assert!(matches!(
            received.recv_timeout(Duration::from_secs(2)).unwrap(),
            Err(TranscriptError::Unavailable { .. })
        ));
        publisher.join().unwrap();
        assert!(matches!(
            recorder.read(id, 0, 8),
            Err(TranscriptError::Unavailable { .. })
        ));
        assert!(matches!(
            recorder.allocate(),
            Err(TranscriptError::Unavailable { .. })
        ));
    }
}
