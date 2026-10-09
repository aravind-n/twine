//! Antigravity lifecycle hooks supplied through a launch-only added directory.
//!
//! User and global customizations are never edited. Hooks bridge `agy`'s
//! customization event contracts to Twine's bounded step inbox.

use std::ffi::OsString;
use std::io;
use std::path::Path;
use std::sync::Arc;

use serde_json::{Value, json};

use super::steps::{
    ActivityKind, ActivityPhase, HarnessActivity, HarnessStep, StepInbox, StepKind, truncate,
};
use crate::terminal::ReplayPosition;

pub(crate) fn prepare(position: Arc<ReplayPosition>) -> io::Result<(StepInbox, Vec<OsString>)> {
    let inbox = StepInbox::new(position, parse)?;
    let agents_dir = inbox.directory.path().join(".agents");
    std::fs::create_dir_all(&agents_dir)?;

    let hook_script = inbox.directory.path().join("hook.sh");
    let hook_command = format!("\"{}\"", hook_script.to_string_lossy().replace('"', "\\\""));

    let script_content = format!(
        r#"#!/bin/sh
set -e
EVENT="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"
SOCKET="{}"
BODY=$(/usr/bin/mktemp "$DIR/record.XXXXXXXX")
/bin/cat > "$BODY"

if [ "$EVENT" = "PreInvocation" ]; then
  INVOCATION=$(sed -n 's/.*"invocationNum":[ ]*\([0-9]*\).*/\1/p' "$BODY")
  if [ -n "$INVOCATION" ]; then
    printf '%s' "$INVOCATION" > "$DIR/current_turn"
  fi
fi

TURN=""
if [ -f "$DIR/current_turn" ]; then
  TURN=$(/bin/cat "$DIR/current_turn" 2>/dev/null || true)
fi

printf '{{"event":"%s","turn":"%s","payload_file":"%s"}}' "$EVENT" "$TURN" "$BODY" | \
  /usr/bin/curl --silent --max-time 1 --output /dev/null --header 'Expect:' --unix-socket "$SOCKET" --data-binary @- http://localhost/ >/dev/null 2>&1 || true

if [ "$EVENT" = "PreToolUse" ]; then
  printf '{{"decision":"allow"}}'
else
  printf '{{}}'
fi
"#,
        inbox.socket_path.to_string_lossy().replace('"', "\\\"")
    );

    std::fs::write(&hook_script, script_content)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&hook_script)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&hook_script, perms)?;
    }

    let hooks = json!({
        "twine": {
            "SessionStart": [
                {
                    "type": "command",
                    "command": format!("{hook_command} SessionStart"),
                    "timeout": 5
                }
            ],
            "PreInvocation": [
                {
                    "type": "command",
                    "command": format!("{hook_command} PreInvocation"),
                    "timeout": 5
                }
            ],
            "PostInvocation": [{"type":"command","command":format!("{hook_command} PostInvocation"),"timeout":5}],
            "PreToolUse": [
                {
                    "matcher": "*",
                    "hooks": [
                        {
                            "type": "command",
                            "command": format!("{hook_command} PreToolUse"),
                            "timeout": 5
                        }
                    ]
                }
            ],
            "PostToolUse": [
                {
                    "matcher": "*",
                    "hooks": [
                        {
                            "type": "command",
                            "command": format!("{hook_command} PostToolUse"),
                            "timeout": 5
                        }
                    ]
                }
            ],
            "Stop": [
                {
                    "type": "command",
                    "command": format!("{hook_command} Stop"),
                    "timeout": 5
                }
            ]
        }
    });

    let settings = agents_dir.join("hooks.json");
    std::fs::write(&settings, serde_json::to_vec(&hooks)?)?;

    let add_dir = inbox.directory.path().as_os_str().to_owned();
    Ok((inbox, vec![OsString::from("--add-dir"), add_dir]))
}

fn preview(value: &Value) -> String {
    value
        .as_str()
        .map_or_else(|| value.to_string(), str::to_owned)
}

fn clean_prompt(content: &str) -> String {
    if let Some(start) = content.find("<USER_REQUEST>\n") {
        let rest = &content[start + "<USER_REQUEST>\n".len()..];
        if let Some(end) = rest.find("\n</USER_REQUEST>") {
            return rest[..end].trim().to_owned();
        }
    }
    content.trim().to_owned()
}

fn read_latest_user_prompt(path: &Path) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let reader = std::io::BufReader::new(file);
    let mut last_prompt = None;
    for line in std::io::BufRead::lines(reader) {
        let line = line.ok()?;
        if !line.contains(r#""type":"USER_INPUT""#) {
            continue;
        }
        if let Ok(entry) = serde_json::from_str::<Value>(&line)
            && entry["type"] == "USER_INPUT"
            && let Some(content) = entry["content"].as_str()
        {
            last_prompt = Some(clean_prompt(content));
        }
    }
    last_prompt
}

fn latest_user_identity(path: &Path) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let mut identity = None;
    for (index, line) in std::io::BufRead::lines(std::io::BufReader::new(file)).enumerate() {
        let line = line.ok()?;
        let entry: Value = serde_json::from_str(&line).ok()?;
        if entry["type"] == "USER_INPUT" {
            identity = Some(
                entry["id"]
                    .as_str()
                    .map_or_else(|| format!("entry-{index}"), str::to_owned),
            );
        }
    }
    identity
}

fn tool_action(tool: &str, arguments: &Value) -> String {
    if let Some(action) = arguments["toolAction"].as_str() {
        return action.to_owned();
    }
    if let Some(summary) = arguments["toolSummary"].as_str() {
        return summary.to_owned();
    }
    match tool {
        "run_command" => arguments["CommandLine"]
            .as_str()
            .map_or_else(|| "Run command".into(), |cmd| format!("$ {cmd}")),
        "view_file" => format!(
            "Read {}",
            arguments["AbsolutePath"].as_str().unwrap_or("file")
        ),
        "replace_file_content" | "write_to_file" => format!(
            "Edit {}",
            arguments["TargetFile"].as_str().unwrap_or("file")
        ),
        "search_web" => format!("Search {}", arguments["query"].as_str().unwrap_or("web")),
        "read_url_content" => format!("Read {}", arguments["Url"].as_str().unwrap_or("URL")),
        "ask_question" => "Ask question".into(),
        _ => format!("Call {tool}"),
    }
}

fn parse_tool_step(
    payload: &Value,
    session_id: Option<String>,
    turn: Option<String>,
    started: bool,
) -> Option<HarnessStep> {
    let tool_call = &payload["toolCall"];
    let tool = tool_call["name"].as_str()?;
    let arguments = &tool_call["args"];
    let step_idx = payload["stepIdx"].as_u64()?;
    let action = tool_action(tool, arguments);
    let activity_id = format!("tool:{step_idx}");
    let error = payload["error"].as_str().unwrap_or_default();
    let failed = !started && !error.is_empty();

    let (kind, title, detail, phase) = if started {
        (
            StepKind::ToolStarted,
            truncate(&action, 160),
            format!("Input: {}", preview(arguments)),
            ActivityPhase::Started,
        )
    } else {
        let prefix = if failed { "Failed" } else { "Finished" };
        let detail = if failed {
            format!("Error: {error}")
        } else {
            format!("Finished: {action}")
        };
        (
            StepKind::ToolFinished,
            truncate(&format!("{prefix}: {action}"), 160),
            detail,
            ActivityPhase::Finished,
        )
    };

    Some(HarnessStep {
        activity: Some(HarnessActivity {
            id: activity_id.clone(),
            parent_id: None,
            kind: ActivityKind::Tool,
            phase,
            failed,
            detail_path: None,
            metadata: serde_json::json!({}),
        }),
        session_id,
        kind,
        turn_id: turn,
        tool_call_id: Some(activity_id),
        title,
        detail,
    })
}

fn parse(bytes: &[u8]) -> Option<HarnessStep> {
    let input: Value = serde_json::from_slice(bytes).ok()?;
    let event = input["event"].as_str()?;
    let payload = if input["payload"].is_object() {
        &input["payload"]
    } else {
        &input
    };

    let session_id = super::resume::session_handle(&payload["conversationId"]);
    let turn = payload["transcriptPath"]
        .as_str()
        .and_then(|path| latest_user_identity(Path::new(path)))
        .map(|id| format!("user:{id}"))
        .or_else(|| {
            input["turn"]
                .as_str()
                .filter(|t| !t.is_empty())
                .map(|t| format!("turn:{t}"))
        });

    match event {
        "SessionStart" => Some(HarnessStep {
            activity: None,
            session_id,
            kind: StepKind::SessionStarted,
            turn_id: None,
            tool_call_id: None,
            title: String::new(),
            detail: String::new(),
        }),
        "PreInvocation" => {
            let prompt_text = input["prompt"]
                .as_str()
                .map(str::to_owned)
                .or_else(|| {
                    payload["transcriptPath"]
                        .as_str()
                        .and_then(|path| read_latest_user_prompt(Path::new(path)))
                })
                .unwrap_or_else(|| "Prompt".into());
            Some(HarnessStep {
                activity: Some(HarnessActivity {
                    id: format!(
                        "model:{}:{}",
                        turn.as_deref().unwrap_or("unknown"),
                        payload["invocationNum"]
                    ),
                    parent_id: None,
                    kind: ActivityKind::Model,
                    phase: ActivityPhase::Started,
                    failed: false,
                    detail_path: None,
                    metadata: json!({"source":"Observer","model":payload["modelName"],"inputKind":"USER REQUEST","invocation":payload["invocationNum"]}),
                }),
                session_id,
                kind: StepKind::Prompt,
                turn_id: turn,
                tool_call_id: None,
                title: truncate(&prompt_text, 160),
                detail: prompt_text,
            })
        }
        "PostInvocation" => Some(HarnessStep {
            session_id,
            kind: StepKind::Activity,
            turn_id: turn.clone(),
            tool_call_id: None,
            title: "LLM call".into(),
            detail: payload
                .get("response")
                .or_else(|| payload.get("summary"))
                .map(preview)
                .unwrap_or_default(),
            activity: Some(HarnessActivity {
                id: format!(
                    "model:{}:{}",
                    turn.as_deref().unwrap_or("unknown"),
                    payload["invocationNum"]
                ),
                parent_id: None,
                kind: ActivityKind::Model,
                phase: ActivityPhase::Finished,
                failed: payload["error"].as_str().is_some_and(|s| !s.is_empty()),
                detail_path: None,
                metadata: json!({"source":"Observer","model":payload["modelName"],"inputKind":"USER REQUEST","invocation":payload["invocationNum"]}),
            }),
        }),
        "PreToolUse" => parse_tool_step(payload, session_id, turn, true),
        "PostToolUse" => parse_tool_step(payload, session_id, turn, false),
        "Stop" => Some(HarnessStep {
            activity: None,
            session_id,
            kind: StepKind::Responded,
            turn_id: turn,
            tool_call_id: None,
            title: "Finished responding".into(),
            detail: String::new(),
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_session_start_with_conversation_id() {
        let payload = json!({
            "event": "SessionStart",
            "payload": {
                "conversationId": "conv-12345",
                "modelName": "gemini-3.8-flash-medium"
            }
        });
        let step = parse(payload.to_string().as_bytes()).unwrap();
        assert_eq!(step.kind, StepKind::SessionStarted);
        assert_eq!(step.session_id.as_deref(), Some("conv-12345"));
        assert!(step.turn_id.is_none());
    }

    #[test]
    fn parses_pre_invocation_prompt() {
        let payload = json!({
            "event": "PreInvocation",
            "turn": "0",
            "prompt": "Fix the bug in main.rs",
            "payload": {
                "conversationId": "conv-12345"
            }
        });
        let step = parse(payload.to_string().as_bytes()).unwrap();
        assert_eq!(step.kind, StepKind::Prompt);
        assert_eq!(step.session_id.as_deref(), Some("conv-12345"));
        assert_eq!(step.turn_id.as_deref(), Some("turn:0"));
        assert_eq!(step.title, "Fix the bug in main.rs");
    }

    #[test]
    fn parses_pre_tool_use_lifecycle() {
        let payload = json!({
            "event": "PreToolUse",
            "turn": "1",
            "payload": {
                "conversationId": "conv-12345",
                "stepIdx": 4,
                "toolCall": {
                    "name": "run_command",
                    "args": {
                        "CommandLine": "cargo test",
                        "toolAction": "Running cargo test"
                    }
                }
            }
        });
        let step = parse(payload.to_string().as_bytes()).unwrap();
        assert_eq!(step.kind, StepKind::ToolStarted);
        assert_eq!(step.session_id.as_deref(), Some("conv-12345"));
        assert_eq!(step.turn_id.as_deref(), Some("turn:1"));
        assert_eq!(step.tool_call_id.as_deref(), Some("tool:4"));
        assert_eq!(step.title, "Running cargo test");
        let activity = step.activity.unwrap();
        assert_eq!(activity.id, "tool:4");
        assert_eq!(activity.phase, ActivityPhase::Started);
        assert!(!activity.failed);
    }

    #[test]
    fn parses_post_tool_use_success_and_failure() {
        let success = json!({
            "event": "PostToolUse",
            "turn": "1",
            "payload": {
                "conversationId": "conv-12345",
                "stepIdx": 4,
                "error": "",
                "toolCall": {
                    "name": "run_command",
                    "args": {
                        "CommandLine": "cargo test",
                        "toolAction": "Running cargo test"
                    }
                }
            }
        });
        let step = parse(success.to_string().as_bytes()).unwrap();
        assert_eq!(step.kind, StepKind::ToolFinished);
        assert_eq!(step.title, "Finished: Running cargo test");
        let activity = step.activity.unwrap();
        assert_eq!(activity.phase, ActivityPhase::Finished);
        assert!(!activity.failed);

        let failure = json!({
            "event": "PostToolUse",
            "turn": "1",
            "payload": {
                "conversationId": "conv-12345",
                "stepIdx": 5,
                "error": "command exited with code 1",
                "toolCall": {
                    "name": "run_command",
                    "args": {
                        "CommandLine": "cargo test",
                        "toolAction": "Running cargo test"
                    }
                }
            }
        });
        let step = parse(failure.to_string().as_bytes()).unwrap();
        assert_eq!(step.kind, StepKind::ToolFinished);
        assert_eq!(step.title, "Failed: Running cargo test");
        let activity = step.activity.unwrap();
        assert_eq!(activity.phase, ActivityPhase::Finished);
        assert!(activity.failed);
    }

    #[test]
    fn parses_stop_event() {
        let payload = json!({
            "event": "Stop",
            "turn": "0",
            "payload": {
                "conversationId": "conv-12345",
                "terminationReason": "NO_TOOL_CALL"
            }
        });
        let step = parse(payload.to_string().as_bytes()).unwrap();
        assert_eq!(step.kind, StepKind::Responded);
        assert_eq!(step.session_id.as_deref(), Some("conv-12345"));
        assert_eq!(step.turn_id.as_deref(), Some("turn:0"));
        assert_eq!(step.title, "Finished responding");
    }

    #[test]
    fn extracts_user_prompt_from_transcript_file() {
        let dir = tempfile::tempdir().unwrap();
        let transcript = dir.path().join("transcript.jsonl");
        let raw = concat!(
            r#"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"<USER_REQUEST>\nImplement feature XYZ\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\n..."}"#,
            "\n",
            r#"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","content":"OK"}"#,
            "\n"
        );
        std::fs::write(&transcript, raw).unwrap();

        let payload = json!({
            "event": "PreInvocation",
            "turn": "0",
            "payload": {
                "conversationId": "conv-abc",
                "transcriptPath": transcript.to_str().unwrap()
            }
        });
        let step = parse(payload.to_string().as_bytes()).unwrap();
        assert_eq!(step.kind, StepKind::Prompt);
        assert_eq!(step.title, "Implement feature XYZ");
    }
}
