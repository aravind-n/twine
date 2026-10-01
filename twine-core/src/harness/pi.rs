//! Pi and OMP's launch-only observer extension, sharing the bounded step inbox and trace recorder.

use std::ffi::OsString;
use std::io;
use std::sync::Arc;

use serde_json::Value;

use super::steps::{HarnessStep, MAX_DETAIL_BYTES, StepInbox, StepKind, truncate};
use crate::HarnessId;
use crate::terminal::ReplayPosition;

pub(crate) fn prepare(
    position: Arc<ReplayPosition>,
    harness: HarnessId,
) -> io::Result<(StepInbox, Vec<OsString>)> {
    let inbox = StepInbox::new(position, parse)?;
    let extension = inbox.directory.path().join("twine.js");
    let source = include_str!("pi-extension.js")
        .replace(
            "__TWINE_OMP__",
            if harness == HarnessId::Omp {
                "true"
            } else {
                "false"
            },
        )
        .replace(
            "__TWINE_SOCKET__",
            &serde_json::to_string(&inbox.socket_path)?,
        );
    std::fs::write(&extension, source)?;
    Ok((
        inbox,
        vec![OsString::from("--extension"), extension.into_os_string()],
    ))
}

fn parse(bytes: &[u8]) -> Option<HarnessStep> {
    let input: Value = serde_json::from_slice(bytes).ok()?;
    if input["type"] == "session" {
        return HarnessStep::session_started(&input["session_id"]);
    }
    let turn_id = input["turn_id"].as_str().filter(|id| !id.is_empty())?;
    let detail = truncate(
        input["detail"].as_str().unwrap_or_default(),
        MAX_DETAIL_BYTES,
    );
    let (kind, title) = match input["type"].as_str()? {
        "prompt" => (StepKind::Prompt, truncate(&detail, 160)),
        "response" => (
            StepKind::Responded,
            if input["stop_reason"] == "length" {
                "Output limit reached"
            } else {
                "Finished responding"
            }
            .into(),
        ),
        event @ ("tool_start" | "tool_end") => {
            let tool = input["tool_name"].as_str()?;
            let target = input["target"].as_str().unwrap_or_default();
            let action = match tool {
                "bash" => format!("Run {target}"),
                "read" => format!("Read {target}"),
                "edit" => format!("Edit {target}"),
                "write" => format!("Write {target}"),
                _ => format!("Call {tool}"),
            };
            if event == "tool_start" {
                (StepKind::ToolStarted, truncate(&action, 160))
            } else {
                let prefix = if input["is_error"].as_bool() == Some(true) {
                    "Failed"
                } else {
                    "Finished"
                };
                (
                    StepKind::ToolFinished,
                    truncate(&format!("{prefix}: {action}"), 160),
                )
            }
        }
        _ => return None,
    };
    Some(HarnessStep {
        session_id: super::resume::session_handle(&input["session_id"]),
        kind,
        turn_id: Some(truncate(turn_id, 160)),
        tool_call_id: input["tool_call_id"].as_str().map(|id| truncate(id, 160)),
        title,
        detail,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn captures_session_identity_before_any_prompt() {
        let step = parse(br#"{"type":"session","session_id":"/tmp/pi session.jsonl"}"#).unwrap();
        assert_eq!(step.kind, StepKind::SessionStarted);
        assert_eq!(step.session_id.as_deref(), Some("/tmp/pi session.jsonl"));
        assert!(step.turn_id.is_none());
    }

    #[test]
    fn pi_steps_preserve_prompt_and_call_identity_and_bound_text() {
        let step = parse(
            &serde_json::to_vec(&json!({
                "type": "tool_start", "turn_id": "prompt-1", "tool_call_id": "call-1",
                "tool_name": "bash", "target": "make test", "detail": "☃".repeat(5000),
            }))
            .unwrap(),
        )
        .unwrap();
        assert_eq!(step.kind, StepKind::ToolStarted);
        assert_eq!(step.turn_id.as_deref(), Some("prompt-1"));
        assert_eq!(step.tool_call_id.as_deref(), Some("call-1"));
        assert_eq!(step.title, "Run make test");
        assert!(step.detail.len() <= MAX_DETAIL_BYTES);
        assert!(step.detail.ends_with("[truncated]"));
        assert!(parse(b"invalid").is_none());
        assert!(parse(br#"{"type":"prompt","detail":"missing id"}"#).is_none());
        assert!(parse(br#"{"type":"response","turn_id":""}"#).is_none());
        assert!(parse(br#"{"type":"other","turn_id":"1"}"#).is_none());
    }

    #[test]
    fn pi_tools_have_readable_descriptions_and_failures() {
        for (tool, expected) in [("read", "Read"), ("write", "Write"), ("edit", "Edit")] {
            let step = parse(
                &serde_json::to_vec(&json!({
                    "type":"tool_end", "turn_id":"1", "tool_name":tool,
                    "target":"src/main.rs", "is_error":true, "detail":"permission denied",
                }))
                .unwrap(),
            )
            .unwrap();
            assert_eq!(step.kind, StepKind::ToolFinished);
            assert_eq!(step.title, format!("Failed: {expected} src/main.rs"));
        }
        let step = parse(br#"{"type":"tool_start","turn_id":"1","tool_name":"custom"}"#).unwrap();
        assert_eq!(step.title, "Call custom");
    }

    #[test]
    fn pi_truncated_responses_report_the_output_limit() {
        let step = parse(
            br#"{"type":"response","turn_id":"1","stop_reason":"length","detail":"Partial response"}"#,
        )
        .unwrap();
        assert_eq!(step.kind, StepKind::Responded);
        assert_eq!(step.title, "Output limit reached");
        assert_eq!(step.detail, "Partial response");
        assert_eq!(
            parse(br#"{"type":"response","turn_id":"1"}"#)
                .unwrap()
                .title,
            "Finished responding"
        );
    }

    #[test]
    #[ignore = "requires Node; set TWINE_NODE to its absolute path"]
    fn omp_extension_preserves_continuations_and_ignores_child_sessions() {
        let node = std::env::var("TWINE_NODE").expect("set TWINE_NODE");
        let (inbox, arguments) =
            prepare(Arc::new(ReplayPosition::default()), HarnessId::Omp).unwrap();
        let script = r"
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
const { default: extension } = await import(pathToFileURL(process.argv[1]));
const handlers = new Map();
extension({ on: (name, handler) => handlers.set(name, handler) });
assert.equal(handlers.has('agent_settled'), false);
const emit = (name, event, kind = 'main') => {
  assert.ok(handlers.has(name));
  assert.equal(handlers.get(name)(Object.freeze(event), {agent:{kind}}), undefined);
};
const prompt = (text, kind) => emit('message_start', {message:{role:'user',content:[{type:'text',text}]}}, kind);
const response = (text, stopReason = 'stop', kind) => emit('message_end', {
  message:{role:'assistant',stopReason,content:[{type:'text',text}]}
}, kind);
prompt('child prompt', 'sub');
response('child response', 'stop', 'sub');
emit('agent_end', {willContinue:false}, 'sub');
prompt('first');
emit('tool_execution_start', {toolCallId:'a',toolName:'bash',args:{command:'printf marker'}});
response('continuing');
emit('agent_end', {willContinue:true});
// A child shutdown must not close the root's transport or lose the pending call.
emit('session_shutdown', {}, 'sub');
emit('tool_execution_end', {toolCallId:'a',toolName:'bash',result:{content:[{type:'text',text:'marker'}]},isError:false});
response('Done');
emit('agent_end', {willContinue:false});
prompt('aborted');
response('', 'aborted');
emit('agent_end', {willContinue:false});
prompt('answered');
response('A');
prompt('queued');
response('B');
emit('agent_end', {});
await delay(500);
emit('session_shutdown', {});
";
        let output = std::process::Command::new(node)
            .args(["--input-type=module", "-e", script])
            .arg(&arguments[1])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let events = inbox.take(20);
        let steps: Vec<_> = events.iter().map(|event| &event.step).collect();
        assert_eq!(steps.len(), 9);
        assert_eq!(steps[0].title, "first");
        assert_eq!(steps[1].title, "Run printf marker");
        assert_eq!(steps[2].title, "Finished: Run printf marker");
        assert_eq!(steps[2].tool_call_id, steps[1].tool_call_id);
        assert_eq!(steps[3].kind, StepKind::Responded);
        assert_eq!(steps[3].detail, "Done");
        assert_eq!(steps[3].turn_id, steps[0].turn_id);
        assert_eq!(steps[4].title, "aborted");
        assert_eq!(steps[5].title, "answered");
        assert_eq!(steps[6].kind, StepKind::Responded);
        assert_eq!(steps[6].turn_id, steps[5].turn_id);
        assert_eq!(steps[7].title, "queued");
        assert_eq!(steps[8].kind, StepKind::Responded);
        assert_eq!(steps[8].turn_id, steps[7].turn_id);
    }

    #[test]
    #[ignore = "requires Node; set TWINE_NODE to its absolute path"]
    fn pi_extension_preserves_queued_prompts_and_tool_identity() {
        let node = std::env::var("TWINE_NODE").expect("set TWINE_NODE");
        let (inbox, arguments) =
            prepare(Arc::new(ReplayPosition::default()), HarnessId::Pi).unwrap();
        let script = r"
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
const { default: extension } = await import(pathToFileURL(process.argv[1]));
const handlers = new Map();
extension({ on: (name, handler) => handlers.set(name, handler) });
const emit = (name, event) => assert.equal(handlers.get(name)?.(event), undefined);
const prompt = text => emit('message_start', { message: { role: 'user', content: [{type:'text', text}] } });
const result = (id, text, isError = false) => emit('tool_execution_end', {
  toolCallId:id, toolName:'bash', result:{content:[{type:'text', text}]}, isError
});
prompt('first');
emit('tool_execution_start', Object.freeze({toolCallId:'a', toolName:'bash', args:Object.freeze({command:'sleep 1'})}));
// Steering is observed only when the queued user message enters the loop.
prompt('second');
emit('tool_execution_start', {toolCallId:'b', toolName:'edit', args:{path:'src/main.rs', oldText:'x'.repeat(1000000)}});
result('b', 'failed', true);
result('a', 'older result');
// agent_end during retry is deliberately not a final response signal.
emit('agent_end', {messages:[]});
emit('message_end', {message:{role:'assistant', stopReason:'stop', content:[{type:'text', text:'Done'}]}});
emit('agent_settled', {});
// Aborted model responses must not manufacture a successful completion.
prompt('aborted');
emit('message_end', {message:{role:'assistant', stopReason:'aborted', content:[]}});
emit('agent_settled', {});
// A completed response followed by queued input must complete both prompts.
prompt('answered');
emit('message_end', {message:{role:'assistant', stopReason:'stop', content:[{type:'text', text:'A'}]}});
prompt('queued');
emit('message_end', {message:{role:'assistant', stopReason:'stop', content:[{type:'text', text:'B'}]}});
emit('agent_settled', {});
// Truncation at a UTF-16 surrogate boundary must still produce valid Rust JSON input.
prompt('x'.repeat(2033) + '😀' + 'x'.repeat(100));
emit('tool_execution_start', {toolCallId:'emoji', toolName:'bash', args:{command:'x'.repeat(145) + '😀' + 'x'.repeat(100)}});
result('emoji', 'x'.repeat(2033) + '😀' + 'x'.repeat(100));
emit('message_end', {message:{role:'assistant', stopReason:'length', content:[{type:'text', text:'Partial response'}]}});
emit('agent_settled', {});
// Delivery is asynchronous; allow the bounded queue to drain before shutdown.
await delay(500);
emit('session_shutdown', {});
";
        let output = std::process::Command::new(&node)
            .args(["--input-type=module", "-e", script])
            .arg(&arguments[1])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let events = inbox.take(20);
        assert_eq!(events.len(), 16);
        let steps: Vec<_> = events.iter().map(|event| &event.step).collect();
        assert_eq!(steps[0].title, "first");
        assert_eq!(steps[2].title, "second");
        assert_eq!(steps[4].title, "Failed: Edit src/main.rs");
        assert_eq!(steps[5].title, "Finished: Run sleep 1");
        assert_eq!(steps[5].turn_id, steps[0].turn_id);
        assert_eq!(steps[4].turn_id, steps[2].turn_id);
        assert_ne!(steps[0].turn_id, steps[2].turn_id);
        assert_eq!(steps[6].kind, StepKind::Responded);
        assert_eq!(steps[6].turn_id, steps[2].turn_id);
        assert_eq!(steps[7].title, "aborted");
        assert_eq!(steps[8].title, "answered");
        assert_eq!(steps[9].kind, StepKind::Responded);
        assert_eq!(steps[9].turn_id, steps[8].turn_id);
        assert_eq!(steps[10].title, "queued");
        assert_eq!(steps[11].kind, StepKind::Responded);
        assert_eq!(steps[11].turn_id, steps[10].turn_id);
        assert!(steps[12].detail.ends_with("[truncated]"));
        assert_eq!(steps[13].kind, StepKind::ToolStarted);
        assert_eq!(steps[14].kind, StepKind::ToolFinished);
        assert_eq!(steps[15].kind, StepKind::Responded);
        assert_eq!(steps[15].title, "Output limit reached");
        assert!(
            steps
                .iter()
                .all(|step| step.detail.len() <= MAX_DETAIL_BYTES)
        );
        // An unavailable endpoint must not delay, reject, or mutate any handler.
        std::fs::remove_file(&inbox.socket_path).unwrap();
        let output = std::process::Command::new(node)
            .args(["--input-type=module", "-e", script])
            .arg(&arguments[1])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(inbox.take(20).is_empty());
    }
}
