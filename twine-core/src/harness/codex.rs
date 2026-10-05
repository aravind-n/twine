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

use super::steps::{
    ActivityKind, ActivityPhase, HarnessActivity, HarnessStep, MAX_DETAIL_BYTES, StepInbox,
    StepKind, truncate,
};
use crate::terminal::ReplayPosition;

const EVENTS: [(&str, &str); 7] = [
    ("SessionStart", "session_start"),
    ("UserPromptSubmit", "user_prompt_submit"),
    ("PreToolUse", "pre_tool_use"),
    ("PostToolUse", "post_tool_use"),
    ("Stop", "stop"),
    ("SubagentStart", "subagent_start"),
    ("SubagentStop", "subagent_stop"),
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
    let event = input["hook_event_name"].as_str()?;
    let agent_id = identifier(&input["agent_id"]);
    if input["agent_id"].is_string() && agent_id.is_none() {
        return None;
    }
    if event == "SubagentStart" || event == "SubagentStop" {
        return subagent_step(&input, event == "SubagentStart");
    }
    if event == "SessionStart" {
        return agent_id
            .is_none()
            .then(|| HarnessStep::session_started(&input["session_id"]))?;
    }
    // Child turns are independent of the user's turn. Their prompt/Stop hooks must
    // never change a workflow assignment or complete the parent's prompt span.
    if agent_id.is_some() && matches!(event, "UserPromptSubmit" | "Stop") {
        return None;
    }
    let turn_id = if agent_id.is_some() {
        // Codex uses the child's turn_context.sub_id in child hook payloads, not
        // the spawning turn. Persisted agent identity supplies the association.
        None
    } else {
        Some(identifier(&input["turn_id"])?)
    };
    let (kind, title, detail, activity) = match event {
        "UserPromptSubmit" => {
            let prompt = input["prompt"].as_str()?;
            (
                StepKind::Prompt,
                truncate(prompt, 160),
                truncate(prompt, MAX_DETAIL_BYTES),
                None,
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
            None,
        ),
        "PreToolUse" | "PostToolUse" => {
            let tool = input["tool_name"].as_str()?;
            let arguments = &input["tool_input"];
            let action = tool_action(tool, arguments);
            let started = event == "PreToolUse";
            let failed = !started && tool_failed(&input["tool_response"]);
            let activity = identifier(&input["tool_use_id"]).map(|id| HarnessActivity {
                id: format!("tool:{}:{id}", agent_id.as_deref().unwrap_or("root")),
                parent_id: agent_id.as_ref().map(|id| format!("agent:{id}")),
                kind: ActivityKind::Tool,
                phase: if started {
                    ActivityPhase::Started
                } else {
                    ActivityPhase::Finished
                },
                failed,
            });
            if agent_id.is_some() && activity.is_none() {
                return None;
            }
            let kind = if agent_id.is_some() {
                StepKind::Activity
            } else if started {
                StepKind::ToolStarted
            } else {
                StepKind::ToolFinished
            };
            let title = if started {
                action
            } else {
                let prefix = if failed { "Failed" } else { "Finished" };
                truncate(&format!("{prefix}: {action}"), 160)
            };
            let detail = if started {
                format!("Input: {}", preview(arguments))
            } else {
                input
                    .get("tool_response")
                    .map(|v| format!("Output: {}", preview(v)))
                    .unwrap_or_default()
            };
            (kind, title, detail, activity)
        }
        _ => return None,
    };
    Some(HarnessStep {
        session_id: if agent_id.is_some() {
            None
        } else {
            super::resume::session_handle(&input["session_id"])
        },
        kind,
        turn_id,
        tool_call_id: identifier(&input["tool_use_id"]),
        title,
        detail,
        activity,
    })
}

fn identifier(value: &Value) -> Option<String> {
    value
        .as_str()
        .filter(|id| !id.is_empty() && id.len() <= 160)
        .map(str::to_owned)
}

fn subagent_step(input: &Value, started: bool) -> Option<HarnessStep> {
    let agent_id = identifier(&input["agent_id"])?;
    let name = input["agent_type"]
        .as_str()
        .filter(|name| !name.is_empty())
        .unwrap_or("Subagent");
    Some(HarnessStep {
        // Subagent hook session/turn IDs belong to its own thread. Neither can
        // replace the root session's resume identity or prompt correlation.
        session_id: None,
        kind: StepKind::Activity,
        turn_id: None,
        tool_call_id: None,
        title: truncate(name, 160),
        detail: if started {
            String::new()
        } else {
            input
                .get("last_assistant_message")
                .filter(|v| !v.is_null())
                .map(preview)
                .unwrap_or_default()
        },
        activity: Some(HarnessActivity {
            id: format!("agent:{agent_id}"),
            // The hook schema has no parent-agent field. Keep agents as siblings
            // rather than infer a relationship from whichever hook arrives first.
            parent_id: None,
            kind: ActivityKind::Subagent,
            phase: if started {
                ActivityPhase::Started
            } else {
                ActivityPhase::Finished
            },
            failed: false,
        }),
    })
}

fn tool_failed(response: &Value) -> bool {
    response["exit_code"].as_i64().is_some_and(|code| code != 0)
        || response["isError"] == true
        || response["is_error"] == true
        || response["success"] == false
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
    fn pairs_tool_activity_and_records_structured_failures() {
        let start = parse(br#"{"hook_event_name":"PreToolUse","turn_id":"turn-1","tool_use_id":"call-1","tool_name":"Bash","tool_input":{"command":"false"}}"#).unwrap();
        let end = parse(br#"{"hook_event_name":"PostToolUse","turn_id":"turn-1","tool_use_id":"call-1","tool_name":"Bash","tool_input":{"command":"false"},"tool_response":{"exit_code":1}}"#).unwrap();
        let activity = start.activity.unwrap();
        let finished = end.activity.unwrap();
        assert_eq!(activity.id, "tool:root:call-1");
        assert_eq!(activity.id, finished.id);
        assert_eq!(activity.kind, ActivityKind::Tool);
        assert_eq!(activity.phase, ActivityPhase::Started);
        assert_eq!(finished.phase, ActivityPhase::Finished);
        assert!(finished.failed);
        assert_eq!(end.title, "Failed: Run false");
        assert!(tool_failed(&json!({"isError": true})));
        assert!(tool_failed(&json!({"success": false})));
        assert!(!tool_failed(
            &json!({"exit_code": 0, "output": "error text is not a status"})
        ));
    }

    #[test]
    fn child_hooks_preserve_agent_identity_without_using_child_turns() {
        let start = parse(br#"{"hook_event_name":"SubagentStart","session_id":"child-session","turn_id":"child-turn","agent_id":"agent-1","agent_type":"reviewer"}"#).unwrap();
        let tool = parse(br#"{"hook_event_name":"PreToolUse","turn_id":"child-turn","agent_id":"agent-1","tool_use_id":"call-1","tool_name":"Bash","tool_input":{"command":"make test"}}"#).unwrap();
        let stop = parse(br#"{"hook_event_name":"SubagentStop","turn_id":"child-turn","agent_id":"agent-1","agent_type":"reviewer","last_assistant_message":"All tests passed"}"#).unwrap();
        for step in [&start, &tool, &stop] {
            assert_eq!(step.kind, StepKind::Activity);
            assert!(step.turn_id.is_none());
            assert!(step.session_id.is_none());
        }
        let activity = start.activity.unwrap();
        let child_tool = tool.activity.unwrap();
        let finished = stop.activity.unwrap();
        assert_eq!(activity.id, "agent:agent-1");
        assert_eq!(child_tool.id, "tool:agent-1:call-1");
        assert_eq!(child_tool.parent_id.as_deref(), Some(activity.id.as_str()));
        assert_eq!(activity.id, finished.id);
        assert_eq!(finished.phase, ActivityPhase::Finished);
        assert_eq!(stop.detail, "All tests passed");
        assert!(parse(br#"{"hook_event_name":"UserPromptSubmit","turn_id":"child-turn","agent_id":"agent-1","prompt":"review"}"#).is_none());
        assert!(
            parse(br#"{"hook_event_name":"Stop","turn_id":"child-turn","agent_id":"agent-1"}"#)
                .is_none()
        );
        assert!(parse(br#"{"hook_event_name":"SubagentStart","agent_id":""}"#).is_none());
        assert!(
            parse(
                &serde_json::to_vec(
                    &json!({"hook_event_name":"SubagentStart", "agent_id":"a".repeat(161)})
                )
                .unwrap()
            )
            .is_none()
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
        assert_eq!(entries.len(), EVENTS.len());
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
