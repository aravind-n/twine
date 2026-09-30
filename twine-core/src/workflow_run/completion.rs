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
        // mkdir prevents two submissions from overwriting one another. Twine removes the lock
        // after consuming a rejected submission, allowing the agent to correct it.
        fs::write(
            &script,
            concat!(
                "#!/bin/sh\nset -eu\n",
                "cd -- \"$(dirname -- \"$0\")\"\n",
                "mkdir pending\n",
                "trap 'rm -f submission.tmp; rmdir pending 2>/dev/null || true' EXIT\n",
                "head -c 65537 > submission.tmp\n",
                "mv submission.tmp submission.json\n",
                "trap - EXIT\n",
                "echo 'Completion submitted to Twine. Check response.txt if it is rejected.'\n",
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
                let _ = fs::remove_dir(self.directory.path().join("pending"));
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
            serde_json::from_slice(&bytes)
                .map_err(|_| "Use the completion JSON format from your instructions.".to_owned())
        })();
        let _ = fs::remove_file(path);
        let _ = fs::remove_dir(self.directory.path().join("pending"));
        Some(result)
    }

    pub(crate) fn reject(&self, message: &str) {
        let _ = fs::write(self.directory.path().join("response.txt"), message);
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

    use super::*;

    #[test]
    fn helper_submits_atomically_and_rejected_json_can_be_corrected() {
        let inbox = CompletionInbox::new().unwrap();
        for json in ["not json", r#"{"decision":"done","summary":"Finished"}"#] {
            let mut child = Command::new(inbox.directory.path().join("complete"))
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .spawn()
                .unwrap();
            child
                .stdin
                .take()
                .unwrap()
                .write_all(json.as_bytes())
                .unwrap();
            assert!(child.wait().unwrap().success());
            let result = inbox.take().unwrap();
            assert_eq!(result.is_ok(), json.starts_with('{'));
            assert!(inbox.take().is_none());
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
}
