//! Claude Code's launch-only hooks. User and project settings files are never edited.

use std::ffi::OsString;
use std::io;
use std::sync::Arc;

use serde_json::{Value, json};

use super::steps::{HarnessStep, MAX_DETAIL_BYTES, StepInbox, StepKind, truncate};
use crate::terminal::ReplayPosition;

pub(crate) fn prepare(position: Arc<ReplayPosition>) -> io::Result<(StepInbox, Vec<OsString>)> {
    let inbox = StepInbox::new(position, parse)?;
    let command = inbox.hook_command();
    let mut hooks = serde_json::Map::new();
    for event in [
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
    ] {
        hooks.insert(event.into(), json!([{"hooks": [{"type": "command", "command": command, "async": true, "timeout": 1}]}]));
    }
    let settings = inbox.directory.path().join("settings.json");
    std::fs::write(&settings, serde_json::to_vec(&json!({"hooks": hooks}))?)?;
    Ok((
        inbox,
        vec![OsString::from("--settings"), settings.into_os_string()],
    ))
}

fn preview(value: &Value) -> String {
    let text = value
        .as_str()
        .map_or_else(|| value.to_string(), str::to_owned);
    truncate(&text, MAX_DETAIL_BYTES)
}

fn parse(bytes: &[u8]) -> Option<HarnessStep> {
    let input: Value = serde_json::from_slice(bytes).ok()?;
    let event = input["hook_event_name"].as_str()?;
    let (kind, title, detail) = match event {
        "UserPromptSubmit" => {
            let prompt = input["prompt"].as_str()?;
            (
                StepKind::Prompt,
                truncate(prompt, 160),
                truncate(prompt, MAX_DETAIL_BYTES),
            )
        }
        "Stop" => (
            StepKind::Responded,
            "Finished responding".into(),
            input
                .get("last_assistant_message")
                .map(preview)
                .unwrap_or_default(),
        ),
        "PreToolUse" | "PostToolUse" | "PostToolUseFailure" => {
            let tool = input["tool_name"].as_str()?;
            let arguments = &input["tool_input"];
            let action = match tool {
                "Bash" => format!("Run {}", arguments["command"].as_str().unwrap_or("command")),
                "Read" => format!("Read {}", arguments["file_path"].as_str().unwrap_or("file")),
                "Edit" | "MultiEdit" => {
                    format!("Edit {}", arguments["file_path"].as_str().unwrap_or("file"))
                }
                "Write" => format!(
                    "Write {}",
                    arguments["file_path"].as_str().unwrap_or("file")
                ),
                _ => format!("Call {tool}"),
            };
            if event == "PreToolUse" {
                (
                    StepKind::ToolStarted,
                    truncate(&action, 160),
                    format!("Input: {}", preview(arguments)),
                )
            } else {
                let output = input.get("tool_response").or_else(|| input.get("error"));
                let prefix = if event == "PostToolUseFailure" {
                    "Failed"
                } else {
                    "Finished"
                };
                (
                    StepKind::ToolFinished,
                    truncate(&format!("{prefix}: {action}"), 160),
                    output
                        .map(|value| format!("Output: {}", preview(value)))
                        .unwrap_or_default(),
                )
            }
        }
        _ => return None,
    };
    Some(HarnessStep {
        kind,
        turn_id: input["prompt_id"].as_str().map(|id| truncate(id, 160)),
        tool_call_id: input["tool_use_id"].as_str().map(|id| truncate(id, 160)),
        title,
        detail,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_descriptions_and_large_payloads_are_bounded() {
        let step = parse(&serde_json::to_vec(&json!({"hook_event_name":"PreToolUse", "tool_name":"Edit", "tool_input":{"file_path":"src/main.rs", "new_string":"x".repeat(100_000)}})).unwrap()).unwrap();
        assert_eq!(step.title, "Edit src/main.rs");
        assert!(step.detail.len() < MAX_DETAIL_BYTES + 16);
        assert!(step.detail.contains("[truncated]"));
        let step = parse(br#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make test"}}"#).unwrap();
        assert_eq!(step.title, "Run make test");
        assert!(parse(b"not json").is_none());
        assert!(parse(br#"{"hook_event_name":"Notification"}"#).is_none());
    }

    #[test]
    fn launch_settings_only_add_async_observers() {
        let (inbox, arguments) = prepare(Arc::new(ReplayPosition::default())).unwrap();
        assert_eq!(arguments[0], "--settings");
        let settings: Value = serde_json::from_slice(
            &std::fs::read(inbox.directory.path().join("settings.json")).unwrap(),
        )
        .unwrap();
        for group in settings["hooks"].as_object().unwrap().values() {
            let hook = &group[0]["hooks"][0];
            assert_eq!(hook["async"], true);
            assert_eq!(hook["timeout"], 1);
            assert!(hook["command"].as_str().unwrap().ends_with("|| true"));
        }
        assert_eq!(settings.as_object().unwrap().len(), 1);
    }
}
