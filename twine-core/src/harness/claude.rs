//! Claude Code's launch-only hooks. User and project settings files are never edited.

use std::ffi::OsString;
use std::io;
use std::sync::Arc;

use serde_json::{Value, json};

use super::steps::{
    ActivityKind, ActivityPhase, HarnessActivity, HarnessStep, StepInbox, StepKind, truncate,
};
use crate::terminal::ReplayPosition;

pub(crate) fn prepare(position: Arc<ReplayPosition>) -> io::Result<(StepInbox, Vec<OsString>)> {
    let inbox = StepInbox::new(position, parse)?;
    let command = inbox.hook_command();
    let mut hooks = serde_json::Map::new();
    for event in [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
        "SubagentStart",
        "SubagentStop",
        "PermissionRequest",
        "Notification",
        "PreCompact",
        "PostCompact",
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
    value
        .as_str()
        .map_or_else(|| value.to_string(), str::to_owned)
}

#[expect(
    clippy::too_many_lines,
    reason = "one branch per verified native lifecycle event"
)]
pub(super) fn parse(bytes: &[u8]) -> Option<HarnessStep> {
    let input: Value = serde_json::from_slice(bytes).ok()?;
    let event = input["hook_event_name"].as_str()?;
    let agent_id = identifier(&input["agent_id"]);
    if input["agent_id"].is_string() && agent_id.is_none() {
        return None;
    }
    if input["prompt_id"].as_str().is_some_and(|id| id.len() > 160) {
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
    if agent_id.is_some() && matches!(event, "UserPromptSubmit" | "Stop") {
        return None;
    }
    if matches!(
        event,
        "PermissionRequest" | "Notification" | "PreCompact" | "PostCompact"
    ) {
        let turn = identifier(&input["prompt_id"]);
        let id = super::steps::observation_id(&input);
        return Some(HarnessStep {
            session_id: super::resume::session_handle(&input["session_id"]),
            kind: StepKind::Activity,
            turn_id: turn,
            tool_call_id: None,
            title: match event {
                "PreCompact" => "Compaction started",
                "PostCompact" => "Compaction finished",
                "Notification" => "Harness notification",
                _ => "Permission requested",
            }
            .into(),
            detail: input
                .get("message")
                .or_else(|| input.get("tool_input"))
                .map(preview)
                .unwrap_or_default(),
            activity: Some(HarnessActivity {
                id: format!(
                    "note:{event}:{}:{id}",
                    agent_id.as_deref().unwrap_or("root")
                ),
                parent_id: agent_id.as_ref().map(|id| format!("agent:{id}")),
                kind: ActivityKind::Note,
                phase: ActivityPhase::Finished,
                failed: false,
                detail_path: None,
                metadata: json!({"event":event,"source":"Observer","notificationType":input["notification_type"]}),
            }),
        });
    }
    let (kind, title, detail) = match event {
        "UserPromptSubmit" => {
            let prompt = input["prompt"].as_str()?;
            (StepKind::Prompt, truncate(prompt, 160), prompt.to_owned())
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
            let action = tool_action(tool, arguments);
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
        session_id: super::resume::session_handle(&input["session_id"]),
        kind: if agent_id.is_some() {
            StepKind::Activity
        } else {
            kind
        },
        turn_id: identifier(&input["prompt_id"]),
        tool_call_id: identifier(&input["tool_use_id"]),
        title,
        detail,
        activity: if matches!(kind, StepKind::ToolStarted | StepKind::ToolFinished) {
            let activity = identifier(&input["tool_use_id"]).map(|id| HarnessActivity {
                id: format!("tool:{}:{id}", agent_id.as_deref().unwrap_or("root")),
                parent_id: agent_id.as_ref().map(|id| format!("agent:{id}")),
                kind: ActivityKind::Tool,
                phase: if kind == StepKind::ToolStarted {
                    ActivityPhase::Started
                } else {
                    ActivityPhase::Finished
                },
                failed: event == "PostToolUseFailure",
                detail_path: None,
                metadata: serde_json::json!({}),
            });
            if agent_id.is_some() && activity.is_none() {
                return None;
            }
            activity
        } else {
            None
        },
    })
}

fn tool_action(tool: &str, arguments: &Value) -> String {
    match tool {
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
    }
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
        session_id: super::resume::session_handle(&input["session_id"]),
        kind: StepKind::Activity,
        // Claude's prompt_id identifies the user's prompt, including child hooks.
        // Older versions omit it; the persisted agent association handles that.
        turn_id: identifier(&input["prompt_id"]),
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
            parent_id: None,
            kind: ActivityKind::Subagent,
            phase: if started {
                ActivityPhase::Started
            } else {
                ActivityPhase::Finished
            },
            failed: false,
            detail_path: None,
            metadata: serde_json::json!({}),
        }),
    })
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
    fn tool_descriptions_remain_short_and_large_payloads_are_complete() {
        let step = parse(&serde_json::to_vec(&json!({"hook_event_name":"PreToolUse", "tool_name":"Edit", "tool_input":{"file_path":"src/main.rs", "new_string":"x".repeat(100_000)}})).unwrap()).unwrap();
        assert_eq!(step.title, "Edit src/main.rs");
        assert!(step.detail.len() > 100_000);
        assert!(step.detail.contains(&"x".repeat(100_000)));
        let step = parse(br#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make test"}}"#).unwrap();
        assert_eq!(step.title, "Run make test");
        assert!(parse(b"not json").is_none());
        assert!(parse(br#"{"hook_event_name":"Notification"}"#).is_some());
    }

    #[test]
    fn launch_settings_only_add_async_observers() {
        let (inbox, arguments) = prepare(Arc::new(ReplayPosition::default())).unwrap();
        assert_eq!(arguments[0], "--settings");
        let settings: Value = serde_json::from_slice(
            &std::fs::read(inbox.directory.path().join("settings.json")).unwrap(),
        )
        .unwrap();
        assert!(settings["hooks"]["SubagentStart"].is_array());
        assert!(settings["hooks"]["SubagentStop"].is_array());
        for group in settings["hooks"].as_object().unwrap().values() {
            let hook = &group[0]["hooks"][0];
            assert_eq!(hook["async"], true);
            assert_eq!(hook["timeout"], 1);
            assert!(hook["command"].as_str().unwrap().ends_with("|| true"));
        }
        assert_eq!(settings.as_object().unwrap().len(), 1);
    }

    #[test]
    fn child_tools_and_subagents_keep_the_user_prompt_correlation() {
        let start = parse(br#"{"hook_event_name":"SubagentStart","session_id":"session-1","prompt_id":"prompt-1","agent_id":"child-1","agent_type":"Explore"}"#).unwrap();
        let tool = parse(br#"{"hook_event_name":"PreToolUse","session_id":"session-1","prompt_id":"prompt-1","agent_id":"child-1","tool_use_id":"call-1","tool_name":"Read","tool_input":{"file_path":"src/main.rs"}}"#).unwrap();
        let stop = parse(br#"{"hook_event_name":"SubagentStop","session_id":"session-1","prompt_id":"prompt-1","agent_id":"child-1","agent_type":"Explore","last_assistant_message":"Found the entry point"}"#).unwrap();
        for step in [&start, &tool, &stop] {
            assert_eq!(step.kind, StepKind::Activity);
            assert_eq!(step.turn_id.as_deref(), Some("prompt-1"));
            assert_eq!(step.session_id.as_deref(), Some("session-1"));
        }
        let activity = start.activity.unwrap();
        let child_tool = tool.activity.unwrap();
        let finished = stop.activity.unwrap();
        assert_eq!(activity.id, "agent:child-1");
        assert_eq!(activity.kind, ActivityKind::Subagent);
        assert_eq!(activity.phase, ActivityPhase::Started);
        assert_eq!(child_tool.id, "tool:child-1:call-1");
        assert_eq!(child_tool.parent_id.as_deref(), Some(activity.id.as_str()));
        assert_eq!(activity.id, finished.id);
        assert_eq!(finished.phase, ActivityPhase::Finished);
        assert_eq!(stop.detail, "Found the entry point");
        assert!(parse(br#"{"hook_event_name":"Stop","agent_id":"child-1"}"#).is_none());
        assert!(
            parse(
                br#"{"hook_event_name":"UserPromptSubmit","agent_id":"child-1","prompt":"review"}"#
            )
            .is_none()
        );
    }

    #[test]
    fn tool_failure_closes_the_same_activity_for_root_and_child() {
        for agent in [Value::Null, json!("child-1")] {
            let mut hook = json!({"hook_event_name":"PreToolUse", "agent_id":agent, "prompt_id":"prompt-1", "tool_use_id":"call-1", "tool_name":"Bash", "tool_input":{"command":"make test"}});
            let start = parse(&serde_json::to_vec(&hook).unwrap()).unwrap();
            hook["hook_event_name"] = json!("PostToolUseFailure");
            hook["error"] = json!("Command exited with code 1");
            let stop = parse(&serde_json::to_vec(&hook).unwrap()).unwrap();
            let started = start.activity.unwrap();
            let finished = stop.activity.unwrap();
            assert_eq!(started.id, finished.id);
            assert_eq!(finished.phase, ActivityPhase::Finished);
            assert!(finished.failed);
            assert!(stop.detail.contains("Command exited with code 1"));
            assert_eq!(
                stop.kind,
                if agent.is_null() {
                    StepKind::ToolFinished
                } else {
                    StepKind::Activity
                }
            );
        }
    }

    #[test]
    fn missing_agent_or_call_identity_never_creates_unrelated_activity() {
        assert!(parse(br#"{"hook_event_name":"SubagentStart"}"#).is_none());
        assert!(parse(br#"{"hook_event_name":"SubagentStop","agent_id":""}"#).is_none());
        assert!(parse(br#"{"hook_event_name":"PreToolUse","agent_id":"child-1","tool_name":"Bash","tool_input":{"command":"true"}}"#).is_none());
        let step = parse(br#"{"hook_event_name":"SubagentStart","agent_id":"child-1"}"#).unwrap();
        assert_eq!(step.kind, StepKind::Activity);
        assert_eq!(step.title, "Subagent");
        assert!(step.turn_id.is_none());
        assert!(
            parse(
                &serde_json::to_vec(
                    &json!({"hook_event_name":"SubagentStart", "agent_id":"a".repeat(161)})
                )
                .unwrap()
            )
            .is_none()
        );
        assert!(
            parse(
                &serde_json::to_vec(
                    &json!({"hook_event_name":"Stop", "prompt_id":"p".repeat(161)})
                )
                .unwrap()
            )
            .is_none()
        );
    }
}
