//! Bounded, owned cleanup for terminals replaced by a newly started agent.

use std::sync::{Mutex, PoisonError, mpsc};
use std::thread::JoinHandle;

use tracing::warn;

use super::{TerminalId, TerminalSession, stop_session};
use crate::terminal::shell::ShellIntegration;

const MAX_CLEANUP_WORKERS: usize = 8;

#[derive(Default)]
pub(super) struct TerminalCleanup {
    workers: Mutex<Vec<JoinHandle<()>>>,
}

struct ClosingTerminal {
    id: TerminalId,
    session: TerminalSession,
    _integration: Option<ShellIntegration>,
}

impl ClosingTerminal {
    fn stop(self) {
        stop_session(self.id, self.session);
    }
}

impl TerminalCleanup {
    pub(super) fn close(
        &self,
        id: TerminalId,
        session: TerminalSession,
        integration: Option<ShellIntegration>,
    ) {
        let terminal = ClosingTerminal {
            id,
            session,
            _integration: integration,
        };
        let mut workers = self.workers.lock().unwrap_or_else(PoisonError::into_inner);
        let mut index = 0;
        while index < workers.len() {
            if workers[index].is_finished() {
                join_worker(workers.swap_remove(index));
            } else {
                index += 1;
            }
        }
        // Backpressure keeps process cleanup bounded even if terminals are replaced rapidly.
        if workers.len() == MAX_CLEANUP_WORKERS {
            join_worker(workers.remove(0));
        }
        // Transfer ownership only after spawning, so a thread-creation failure cannot drop a
        // live session without terminating its process and joining its readers/supervisor.
        let (sender, receiver) = mpsc::sync_channel::<ClosingTerminal>(1);
        match crate::blocking_worker::spawn(format!("terminal-{}-cleanup", id.value()), move || {
            if let Ok(terminal) = receiver.recv() {
                terminal.stop();
            }
        }) {
            Ok(worker) => {
                if let Err(error) = sender.send(terminal) {
                    error.0.stop();
                }
                workers.push(worker);
            }
            Err(error) => {
                warn!(%error, "could not start terminal cleanup worker; stopping synchronously");
                terminal.stop();
            }
        }
    }

    pub(super) fn shutdown(&self) {
        let mut workers = self.workers.lock().unwrap_or_else(PoisonError::into_inner);
        for worker in workers.drain(..) {
            join_worker(worker);
        }
    }
}

fn join_worker(worker: JoinHandle<()>) {
    if worker.join().is_err() {
        warn!("terminal cleanup worker panicked");
    }
}
