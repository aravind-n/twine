//! Review notifications share a writer with user input, without submitting an unfinished draft.

use std::collections::VecDeque;

use crate::terminal::{TerminalError, TerminalId, TerminalManager};

#[derive(Clone, Default)]
struct Draft {
    pending: bool,
    pasting: bool,
    escape_pending: bool,
    marker: Vec<u8>,
}

impl Draft {
    fn observe(&mut self, bytes: &[u8]) -> Option<usize> {
        let mut submission = None;
        for (index, &byte) in bytes.iter().enumerate() {
            if byte == 27 {
                self.escape_pending = self.pending;
            }
            self.marker.push(byte);
            if self.marker.len() > 64 {
                self.marker.remove(0);
            }
            if self.marker.ends_with(b"\x1b[200~") {
                self.pasting = true;
            } else if self.marker.ends_with(b"\x1b[201~") {
                self.pasting = false;
            }
            self.pending = self.pasting || !matches!(byte, b'\r' | b'\n' | 3);
            submission = if self.pasting {
                None
            } else if matches!(byte, b'\r' | b'\n') {
                Some(index)
            } else if let Some((length, release)) = keyboard_enter(&self.marker) {
                self.pending = if release { self.escape_pending } else { false };
                if release || length > index + 1 {
                    None
                } else {
                    Some(index + 1 - length)
                }
            } else {
                None
            };
        }
        submission
    }
}

/// Kitty encodes Enter as CSI 13;modifiers:event u. Shift/other modifiers can mean
/// multiline editing, and key releases must never submit a deferred notification.
fn keyboard_enter(bytes: &[u8]) -> Option<(usize, bool)> {
    if !bytes.ends_with(b"u") {
        return None;
    }
    let start = bytes.windows(2).rposition(|part| part == b"\x1b[")?;
    let body = std::str::from_utf8(&bytes[start + 2..bytes.len() - 1]).ok()?;
    let mut fields = body.split(';');
    if fields.next()?.split(':').next()? != "13" {
        return None;
    }
    let mut modifiers = fields.next().unwrap_or("1").split(':');
    let modifier: u16 = modifiers.next()?.parse().ok()?;
    let event: u8 = modifiers.next().unwrap_or("1").parse().ok()?;
    (event == 3 || (modifier.checked_sub(1)?.trailing_zeros() >= 6 && matches!(event, 1 | 2)))
        .then_some((bytes.len() - start, event == 3))
}

#[derive(Default)]
pub(super) struct AgentInput {
    draft: Draft,
    feedback: VecDeque<String>,
}

impl AgentInput {
    pub(super) fn clear_feedback(&mut self) {
        self.feedback.clear();
    }

    pub(super) fn write(
        &mut self,
        terminals: &TerminalManager,
        terminal: TerminalId,
        bytes: &[u8],
    ) -> Result<bool, TerminalError> {
        let mut draft = self.draft.clone();
        let boundary = draft.observe(bytes);
        let submits = boundary.is_some();
        let payload = if !self.feedback.is_empty() && submits {
            let feedback = self
                .feedback
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>()
                .join("\n\n");
            let boundary = boundary.expect("submission has a boundary")
                - usize::from(bytes.ends_with(b"\r\n"));
            let mut payload = bytes[..boundary].to_vec();
            payload.extend_from_slice(
                format!(
                    "\x1b[200~\n\nReview feedback received while you were typing:\n{feedback}\n\n\
                     Continue with the user's message above.\x1b[201~"
                )
                .as_bytes(),
            );
            payload.extend_from_slice(&bytes[boundary..]);
            payload
        } else {
            bytes.to_vec()
        };
        terminals.write_input(terminal, &payload)?;
        self.draft = draft;
        if submits {
            self.feedback.clear();
        }
        Ok(submits)
    }

    pub(super) fn notify(
        &mut self,
        terminals: &TerminalManager,
        terminal: TerminalId,
        message: &str,
    ) -> Result<bool, TerminalError> {
        let message: String = message
            .chars()
            .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'))
            .collect();
        if self.draft.pending {
            // Retain feedback when a subsequent assignment's command update is also deferred.
            if self.feedback.len() == 16 {
                self.feedback.pop_front();
            }
            self.feedback.push_back(message);
            Ok(false)
        } else {
            terminals.write_input(
                terminal,
                format!("\x1b[200~{message}\x1b[201~\r").as_bytes(),
            )?;
            self.feedback.clear();
            Ok(true)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn individual_mode_clears_feedback_without_discarding_the_user_draft() {
        let mut input = AgentInput::default();
        input.draft.observe(b"My unfinished draft");
        input.feedback.push_back("Review feedback".into());
        input.clear_feedback();
        assert!(input.feedback.is_empty());
        assert!(input.draft.pending);
        assert_eq!(input.draft.observe(b"\r"), Some(0));
    }

    #[test]
    fn multiline_paste_and_split_markers_keep_the_draft_pending() {
        let mut draft = Draft::default();
        draft.observe(b"\x1b[20");
        draft.observe(b"0~first\nsecond\n");
        assert!(draft.pending && draft.pasting);
        draft.observe(b"\x1b[201");
        draft.observe(b"~");
        assert!(draft.pending && !draft.pasting);
        draft.observe(b"\r");
        assert!(!draft.pending);
        draft.observe(b"next draft");
        assert!(draft.pending);
        draft.observe(&[3]);
        assert!(!draft.pending);
    }

    #[test]
    fn enhanced_enter_submits_only_unmodified_press_or_repeat() {
        for encoded in [
            b"\x1b[13u".as_slice(),
            b"\x1b[13;1u",
            b"\x1b[13;1:2u",
            b"\x1b[13;65u",
        ] {
            let mut draft = Draft::default();
            draft.observe(b"User draft");
            assert_eq!(draft.observe(encoded), Some(0));
            assert!(!draft.pending);
        }
        for encoded in [b"\x1b[13;2u".as_slice(), b"\x1b[13;1:3u", b"\x1b[13;5u"] {
            let mut draft = Draft::default();
            draft.observe(b"User draft");
            assert_eq!(draft.observe(encoded), None);
            assert!(draft.pending);
        }
        let mut draft = Draft::default();
        draft.observe(b"\x1b[200~");
        assert_eq!(draft.observe(b"\x1b[13u"), None);
        assert!(draft.pending);
    }
}
