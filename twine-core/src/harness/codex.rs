//! Codex lifecycle hooks supplied only through invocation config, never user settings.
//!
//! Wire schema: <https://learn.chatgpt.com/docs/hooks>
//! Scoped trust identity follows Codex 0.159's hooks/engine/discovery.rs and config/fingerprint.rs.
//! Only our session-flag handlers are trusted; user hooks and policy remain unchanged.

use std::ffi::OsString;
use std::io;
use std::sync::Arc;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::steps::{HarnessStep, MAX_DETAIL_BYTES, StepInbox, StepKind, truncate};
use crate::terminal::ReplayPosition;

const EVENTS: [(&str, &str); 5] = [
    ("SessionStart", "session_start"),
    ("UserPromptSubmit", "user_prompt_submit"),
    ("PreToolUse", "pre_tool_use"),
    ("PostToolUse", "post_tool_use"),
    ("Stop", "stop"),
];

pub(crate) fn prepare(position: Arc<ReplayPosition>) -> io::Result<(StepInbox, Vec<OsString>)> {
    let inbox = StepInbox::new(position, parse)?;
    let arguments = hook_arguments(&inbox.hook_command());
    Ok((inbox, arguments))
}

fn hook_arguments(command: &str) -> Vec<OsString> {
    let handler = json!({"type": "command", "command": command, "async": true, "timeout": 1});
    let group = json!({"hooks": [handler.clone()]});
    let mut hooks = serde_json::Map::new();
    let mut states = serde_json::Map::new();
    for (event, key) in EVENTS {
        // Codex fingerprints normalized TOML as JSON with recursively sorted object keys.
        // serde_json's default Map is sorted. Absent optional TOML fields are omitted.
        let identity = json!({"event_name": key, "hooks": [handler.clone()]});
        let hash = format!(
            "sha256:{:x}",
            Sha256::digest(identity.to_string().as_bytes())
        );
        let state_key = format!("/<session-flags>/config.toml:{key}:0:0");
        hooks.insert(event.into(), json!([group.clone()]));
        states.insert(state_key, json!({"trusted_hash": hash}));
    }
    hooks.insert("state".into(), Value::Object(states));
    // Pass the table as one value: Codex splits dotted override keys on every dot,
    // including the dot in the state key's synthetic config.toml source path.
    vec![
        OsString::from("-c"),
        OsString::from(format!("hooks={}", toml_literal(&Value::Object(hooks)))),
    ]
}

fn toml_literal(value: &Value) -> String {
    toml::Value::try_from(value)
        .expect("hook config contains only TOML-compatible values")
        .to_string()
}

fn preview(value: &Value) -> String {
    truncate(
        &value
            .as_str()
            .map_or_else(|| value.to_string(), str::to_owned),
        MAX_DETAIL_BYTES,
    )
}

fn parse(bytes: &[u8]) -> Option<HarnessStep> {
    let input: Value = serde_json::from_slice(bytes).ok()?;
    // Native Codex subagents have separate turns and SubagentStop lifecycles. Their
    // parent tool call is recorded, but a child prompt must not replace this role's span.
    if input["agent_id"].is_string() {
        return None;
    }
    if input["hook_event_name"] == "SessionStart" {
        return HarnessStep::session_started(&input["session_id"]);
    }
    // Require a turn id so a delayed hook can never finish a different prompt.
    let turn_id = input["turn_id"].as_str().filter(|id| !id.is_empty())?;
    let (kind, title, detail) = match input["hook_event_name"].as_str()? {
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
                .filter(|v| !v.is_null())
                .map(preview)
                .unwrap_or_default(),
        ),
        event @ ("PreToolUse" | "PostToolUse") => {
            let tool = input["tool_name"].as_str()?;
            let arguments = &input["tool_input"];
            let action = tool_action(tool, arguments);
            if event == "PreToolUse" {
                (
                    StepKind::ToolStarted,
                    action,
                    format!("Input: {}", preview(arguments)),
                )
            } else {
                (
                    StepKind::ToolFinished,
                    truncate(&format!("Finished: {action}"), 160),
                    input
                        .get("tool_response")
                        .map(|v| format!("Output: {}", preview(v)))
                        .unwrap_or_default(),
                )
            }
        }
        _ => return None,
    };
    Some(HarnessStep {
        session_id: super::resume::session_handle(&input["session_id"]),
        kind,
        turn_id: Some(truncate(turn_id, 160)),
        tool_call_id: input["tool_use_id"].as_str().map(|id| truncate(id, 160)),
        title,
        detail,
    })
}

fn tool_action(tool: &str, input: &Value) -> String {
    let action = match tool {
        "Bash" | "exec_command" | "shell_command" => format!(
            "Run {}",
            input["command"]
                .as_str()
                .or_else(|| input["cmd"].as_str())
                .unwrap_or("command")
        ),
        "apply_patch" => {
            let patch = input["command"]
                .as_str()
                .or_else(|| input["patch"].as_str())
                .unwrap_or("");
            let file = patch.lines().find_map(|line| {
                ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
                    .iter()
                    .find_map(|prefix| line.strip_prefix(prefix))
            });
            file.map_or_else(|| "Apply patch".into(), |file| format!("Edit {file}"))
        }
        _ => format!("Call {tool}"),
    };
    truncate(&action, 160)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn captures_session_identity_before_any_prompt() {
        let step =
            parse(br#"{"hook_event_name":"SessionStart","session_id":"session-1"}"#).unwrap();
        assert_eq!(step.kind, StepKind::SessionStarted);
        assert_eq!(step.session_id.as_deref(), Some("session-1"));
        assert!(step.turn_id.is_none());
    }

    #[test]
    fn codex_hooks_preserve_turns_calls_and_bounded_details() {
        let step = parse(&serde_json::to_vec(&json!({"hook_event_name":"PreToolUse", "turn_id":"turn-1", "tool_use_id":"call-1", "tool_name":"Bash", "tool_input":{"command":"make test", "extra":"☃".repeat(20_000)}})).unwrap()).unwrap();
        assert_eq!(step.kind, StepKind::ToolStarted);
        assert_eq!(step.turn_id.as_deref(), Some("turn-1"));
        assert_eq!(step.tool_call_id.as_deref(), Some("call-1"));
        assert_eq!(step.title, "Run make test");
        assert!(step.detail.len() <= MAX_DETAIL_BYTES + 7);
        assert!(step.detail.ends_with("[truncated]"));
        let step = parse(br#"{"hook_event_name":"PostToolUse","turn_id":"turn-1","tool_use_id":"call-1","tool_name":"Bash","tool_input":{"command":"false"},"tool_response":{"exit_code":1}}"#).unwrap();
        assert_eq!(step.kind, StepKind::ToolFinished);
        assert!(step.detail.contains("exit_code"));
        assert!(parse(b"invalid").is_none());
        assert!(parse(br#"{"hook_event_name":"Stop"}"#).is_none());
        assert!(parse(br#"{"hook_event_name":"Stop","turn_id":""}"#).is_none());
        assert!(parse(br#"{"hook_event_name":"Interrupt","turn_id":"turn-1"}"#).is_none());
    }

    #[test]
    fn patch_and_other_tools_have_short_descriptions() {
        assert_eq!(
            tool_action(
                "apply_patch",
                &json!({"command":"*** Begin Patch\n*** Update File: src/main.rs\n@@\n-old\n+new\n*** End Patch"})
            ),
            "Edit src/main.rs"
        );
        assert_eq!(
            tool_action("mcp__files__read", &json!({"path":"a"})),
            "Call mcp__files__read"
        );
        assert_eq!(
            tool_action("exec_command", &json!({"cmd":"make check"})),
            "Run make check"
        );
    }

    #[test]
    fn launch_flags_scope_trust_to_our_async_handlers() {
        let command = "printf 'a\\b\"☃' >/dev/null || true";
        let arguments = hook_arguments(command);
        assert_eq!(arguments.len(), 2);
        assert_eq!(arguments[0], "-c");
        let config: toml::Value = toml::from_str(arguments[1].to_str().unwrap()).unwrap();
        let entries = config["hooks"]["state"].as_table().unwrap();
        assert_eq!(entries.len(), 5);
        for (event, key) in EVENTS {
            let handler = &config["hooks"][event][0]["hooks"][0];
            assert_eq!(handler["command"].as_str(), Some(command));
            assert_eq!(handler["async"].as_bool(), Some(true));
            assert_eq!(handler["timeout"].as_integer(), Some(1));
            assert!(entries.contains_key(&format!("/<session-flags>/config.toml:{key}:0:0")));
        }
        // Fingerprint independently verified with Codex 0.159's hooks/list API.
        let arguments = hook_arguments("true");
        let config: toml::Value = toml::from_str(arguments[1].to_str().unwrap()).unwrap();
        assert_eq!(config["hooks"]["state"]["/<session-flags>/config.toml:pre_tool_use:0:0"]["trusted_hash"].as_str(),
            Some("sha256:060ef244f257c209a7aa74eab75f277d43410283f549cbacd7cba0cd0f044ef9"));
    }
}
