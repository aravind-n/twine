//! A private, one-invocation mailbox. Only an atomic submission here can signal completion;
//! terminal bytes and process exits never enter this path.

use std::fs::{self, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

use super::CompletionSignal;

pub(crate) const MAX_SIGNAL_BYTES: usize = 64 * 1024;

pub(crate) struct CompletionInbox {
    directory: tempfile::TempDir,
}

impl CompletionInbox {
    pub(crate) fn new() -> io::Result<Self> {
        let directory = tempfile::Builder::new()
            .prefix("twine-completion-")
            .tempdir()?;
        let script = directory.path().join("complete");
        // dirname is evaluated before entering the directory; the path may contain spaces.
        // mkdir prevents overlapping submissions and receipts. The helper releases the lock
        // after reading a rejection, allowing the agent to correct it.
        fs::write(
            &script,
            concat!(
                "#!/bin/sh\nset -eu\n",
                "cd -- \"$(dirname -- \"$0\")\"\n",
                "mkdir pending\n",
                "trap 'rm -f submission.tmp; rmdir pending 2>/dev/null || true' EXIT\n",
                "rm -f response.txt response.tmp accepted acknowledged\n",
                "head -c 65537 > submission.tmp\n",
                "mv submission.tmp submission.json\n",
                // A timeout must not unlock an outstanding submission or receipt. Only a
                // consumed receipt or disposal of the stopped role releases this lock.
                "trap - EXIT\n",
                // Wait for validation before returning to the interactive harness. Twine retains
                // this mailbox until the helper acknowledges acceptance or consumes rejection.
                "attempt=0\n",
                "while [ \"$attempt\" -lt 200 ]; do\n",
                "  if [ -f response.txt ]; then\n",
                "    cat response.txt >&2\n",
                "    rmdir pending\n",
                "    exit 1\n",
                "  fi\n",
                "  if [ -f accepted ]; then\n",
                "    touch acknowledged\n",
                "    echo 'Completion accepted by Twine.'\n",
                "    exit 0\n",
                "  fi\n",
                "  sleep 0.05\n",
                "  attempt=$((attempt + 1))\n",
                "done\n",
                "echo 'Timed out waiting for Twine to accept or reject completion.' >&2\n",
                "exit 1\n",
            ),
        )?;
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700))?;
        Ok(Self { directory })
    }

    pub(crate) fn command(&self) -> String {
        let path = self.directory.path().join("complete");
        format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
    }

    pub(crate) fn take(&self) -> Option<Result<CompletionSignal, String>> {
        let path = self.directory.path().join("submission.json");
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return None,
            Err(_) => {
                let _ = fs::remove_file(&path);
                return Some(Err("Couldn't read the completion submission.".to_owned()));
            }
        };
        let result = (|| {
            if !file.metadata().map_err(|e| e.to_string())?.is_file() {
                return Err("Completion must be a regular file.".to_owned());
            }
            let mut bytes = Vec::new();
            file.take((MAX_SIGNAL_BYTES + 1) as u64)
                .read_to_end(&mut bytes)
                .map_err(|e| e.to_string())?;
            if bytes.len() > MAX_SIGNAL_BYTES {
                return Err("Completion exceeds 64 KiB.".to_owned());
            }
            serde_json::from_slice(&bytes).map_err(|_| {
                concat!(
                    "Invalid completion JSON. Submit an object with decision and summary, ",
                    "for example {\"decision\":\"done\",\"summary\":\"Finished\"}. ",
                    "Use only a decision allowed by your role's instructions. ",
                    "Omit assignments unless your role must delegate; each assignment needs ",
                    "a role ID, a positive integer instance (for example 1, not a model name), ",
                    "a task string, and a files array. Correct the submission and retry.",
                )
                .to_owned()
            })
        })();
        let _ = fs::remove_file(path);
        Some(result)
    }

    pub(crate) fn reject(&self, message: &str) {
        let temporary = self.directory.path().join("response.tmp");
        if fs::write(&temporary, message).is_ok() {
            let _ = fs::rename(temporary, self.directory.path().join("response.txt"));
        }
    }

    pub(crate) fn accept(&self) {
        if let Err(error) = fs::write(self.directory.path().join("accepted"), []) {
            tracing::warn!(%error, "couldn't acknowledge workflow completion");
        }
    }

    /// A user completion has no waiting helper; a harness completion acknowledges its receipt.
    pub(crate) fn receipt_pending(&self) -> bool {
        self.directory.path().join("pending").exists()
            && !self.directory.path().join("acknowledged").exists()
    }

    #[cfg(test)]
    pub(crate) fn response(&self) -> String {
        fs::read_to_string(self.directory.path().join("response.txt")).unwrap()
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::process::{Command, Stdio};
    use std::thread;
    use std::time::{Duration, Instant};

    use super::*;

    #[test]
    fn helper_submits_atomically_and_rejected_json_can_be_corrected() {
        let inbox = CompletionInbox::new().unwrap();
        for json in ["not json", r#"{"decision":"done","summary":"Finished"}"#] {
            let mut child = Command::new(inbox.directory.path().join("complete"))
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap();
            child
                .stdin
                .take()
                .unwrap()
                .write_all(json.as_bytes())
                .unwrap();
            let deadline = Instant::now() + Duration::from_secs(2);
            let result = loop {
                if let Some(result) = inbox.take() {
                    break result;
                }
                assert!(Instant::now() < deadline, "helper didn't submit its JSON");
                thread::sleep(Duration::from_millis(5));
            };
            assert_eq!(result.is_ok(), json.starts_with('{'));
            assert!(inbox.take().is_none());
            assert!(inbox.directory.path().join("pending").exists());
            if let Err(message) = result {
                inbox.reject(&message);
                let output = child.wait_with_output().unwrap();
                assert!(!output.status.success());
                assert_eq!(String::from_utf8_lossy(&output.stderr), message);
                assert!(!inbox.directory.path().join("pending").exists());
            } else {
                // A valid submission cannot return before acceptance is durably recorded.
                thread::sleep(Duration::from_millis(100));
                assert!(child.try_wait().unwrap().is_none());
                inbox.accept();
                let output = child.wait_with_output().unwrap();
                assert!(output.status.success());
                assert_eq!(output.stderr.len(), 0);
                assert!(!inbox.receipt_pending());
            }
        }
    }

    #[test]
    fn oversized_submissions_and_symlinks_are_rejected() {
        let inbox = CompletionInbox::new().unwrap();
        let path = inbox.directory.path().join("submission.json");
        fs::write(&path, vec![b' '; MAX_SIGNAL_BYTES + 1]).unwrap();
        assert!(inbox.take().unwrap().is_err());
        std::os::unix::fs::symlink("/dev/zero", path).unwrap();
        assert!(inbox.take().unwrap().is_err());
        assert!(inbox.take().is_none());
    }

    #[test]
    fn malformed_assignments_get_actionable_feedback_without_echoing_input() {
        let inbox = CompletionInbox::new().unwrap();
        let path = inbox.directory.path().join("submission.json");
        fs::write(
            &path,
            r#"{"decision":"done","summary":"private summary","assignments":[{"role":"reviewer","instance":"model-name","task":"Check","files":["review.json"]}]}"#,
        )
        .unwrap();
        let message = inbox.take().unwrap().unwrap_err();
        assert!(message.contains("positive integer instance"));
        assert!(message.contains("Omit assignments unless your role must delegate"));
        assert!(!message.contains("private summary"));
        assert!(!message.contains("model-name"));
        fs::write(&path, r#"{"decision":"done","summary":"Finished"}"#).unwrap();
        assert!(inbox.take().unwrap().is_ok());
    }
}
