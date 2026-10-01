//! Exact harness conversation handles. Never use a folder's most recent session: several
//! terminals can run the same harness in that folder concurrently.

use std::ffi::OsString;

use super::HarnessId;

pub(crate) fn session_handle(value: &serde_json::Value) -> Option<String> {
    let value = value.as_str()?;
    (!value.is_empty() && value.len() <= 4096 && !value.chars().any(char::is_control))
        .then(|| value.to_owned())
}

pub(crate) fn arguments(harness: HarnessId, session: &str) -> Option<Vec<OsString>> {
    if session.is_empty() || session.len() > 4096 || session.chars().any(char::is_control) {
        return None;
    }
    let flags = match harness {
        HarnessId::Codex | HarnessId::ClaudeCode | HarnessId::Antigravity | HarnessId::Opencode => {
            if !session
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
                || session.starts_with('-')
            {
                return None;
            }
            let flag = match harness {
                HarnessId::Codex => "resume",
                HarnessId::ClaudeCode => "--resume",
                HarnessId::Antigravity => "--conversation",
                HarnessId::Opencode => "--session",
                _ => unreachable!("matched session ID harness"),
            };
            vec![flag, session]
        }
        HarnessId::Pi | HarnessId::Omp => {
            if !std::path::Path::new(session).is_absolute() {
                return None;
            }
            vec!["--session", session]
        }
    };
    Some(flags.into_iter().map(OsString::from).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resumes_exact_sessions_without_replaying_the_prompt() {
        assert_eq!(
            arguments(HarnessId::Codex, "session-1").unwrap(),
            ["resume", "session-1"]
        );
        assert_eq!(
            arguments(HarnessId::ClaudeCode, "session-2").unwrap(),
            ["--resume", "session-2"]
        );
        assert_eq!(
            arguments(HarnessId::Pi, "/a path/session.jsonl").unwrap(),
            ["--session", "/a path/session.jsonl"]
        );
        for harness in [HarnessId::Codex, HarnessId::ClaudeCode, HarnessId::Pi] {
            for bad in ["", "--last", "x\ny", "../session"] {
                assert!(arguments(harness, bad).is_none());
            }
        }
    }
}
