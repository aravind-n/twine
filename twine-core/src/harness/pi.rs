//! Pi and OMP's launch-only observer extension, sharing the bounded step inbox and trace recorder.

use std::ffi::OsString;
use std::io;
use std::sync::Arc;

use serde_json::Value;

use super::steps::{
    ActivityKind, ActivityPhase, HarnessActivity, HarnessStep, MAX_DETAIL_BYTES, StepInbox,
    StepKind, truncate,
};
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
    let agent_id = identifier(&input["agent_id"]);
    let turn_id = identifier(&input["turn_id"]);
    let tool_call_id = identifier(&input["tool_call_id"]);
    // Never truncate identity: distinct long IDs must not collapse onto one activity.
    for key in [
        "agent_id",
        "turn_id",
        "tool_call_id",
        "parent_agent_id",
        "parent_tool_call_id",
    ] {
        if input[key].is_string() && identifier(&input[key]).is_none() {
            return None;
        }
    }
    // Child events carry the known root turn, never the child's independent prompt ID.
    if agent_id.is_none() && turn_id.is_none() {
        return None;
    }
    let failed = input["is_error"].as_bool() == Some(true);
    let event = input["type"].as_str()?;
    let mut activity = None;
    let detail = truncate(
        input["detail"].as_str().unwrap_or_default(),
        MAX_DETAIL_BYTES,
    );
    let (kind, title) = match event {
        event @ ("agent_start" | "agent_end") => {
            let id = agent_id?;
            activity = Some(HarnessActivity {
                id: format!("agent:{id}"),
                parent_id: identifier(&input["parent_agent_id"]).map(|id| format!("agent:{id}")),
                kind: ActivityKind::Subagent,
                phase: if event == "agent_start" {
                    ActivityPhase::Started
                } else {
                    ActivityPhase::Finished
                },
                failed,
            });
            let name = input["agent_name"].as_str().unwrap_or("Subagent");
            (StepKind::Activity, truncate(name, 160))
        }
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
            if agent_id.is_some() && tool_call_id.is_none() {
                return None;
            }
            activity = tool_call_id.as_ref().map(|id| HarnessActivity {
                id: format!("tool:{}:{id}", agent_id.unwrap_or("root")),
                parent_id: identifier(&input["parent_tool_call_id"])
                    .map(|id| format!("tool:{}:{id}", agent_id.unwrap_or("root")))
                    .or_else(|| agent_id.map(|id| format!("agent:{id}"))),
                kind: ActivityKind::Tool,
                phase: if event == "tool_start" {
                    ActivityPhase::Started
                } else {
                    ActivityPhase::Finished
                },
                failed,
            });
            tool_step_title(&input, event == "tool_start")?
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
        turn_id: turn_id.map(str::to_owned),
        tool_call_id: tool_call_id.map(str::to_owned),
        activity,
        title,
        detail,
    })
}

fn tool_step_title(input: &Value, started: bool) -> Option<(StepKind, String)> {
    let tool = input["tool_name"].as_str()?;
    let target = input["target"].as_str().unwrap_or_default();
    let action = match tool {
        "bash" => format!("Run {target}"),
        "read" => format!("Read {target}"),
        "edit" => format!("Edit {target}"),
        "write" => format!("Write {target}"),
        _ => format!("Call {tool}"),
    };
    Some(if started {
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
    })
}

fn identifier(value: &Value) -> Option<&str> {
    value
        .as_str()
        .filter(|id| !id.is_empty() && id.len() <= 160)
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
    fn child_activity_preserves_parent_and_failure_without_finishing_root() {
        let child = parse(br#"{"type":"agent_start","agent_id":"worker","parent_agent_id":"planner","turn_id":"root-turn","agent_name":"Explore","detail":"Find tests"}"#).unwrap();
        assert_eq!(child.kind, StepKind::Activity);
        assert_eq!(child.turn_id.as_deref(), Some("root-turn"));
        let activity = child.activity.unwrap();
        assert_eq!(activity.id, "agent:worker");
        assert_eq!(activity.parent_id.as_deref(), Some("agent:planner"));
        assert_eq!(activity.kind, ActivityKind::Subagent);
        assert_eq!(activity.phase, ActivityPhase::Started);
        let tool = parse(br#"{"type":"tool_end","agent_id":"worker","tool_call_id":"same","tool_name":"bash","is_error":true}"#).unwrap();
        assert_eq!(tool.kind, StepKind::Activity);
        assert!(tool.turn_id.is_none());
        let activity = tool.activity.unwrap();
        assert_eq!(activity.id, "tool:worker:same");
        assert_eq!(activity.parent_id.as_deref(), Some("agent:worker"));
        assert!(activity.failed);
        assert_eq!(activity.phase, ActivityPhase::Finished);
        // No native call identity means no invented start/end pairing.
        assert!(
            parse(br#"{"type":"tool_start","turn_id":"root","tool_name":"bash"}"#)
                .unwrap()
                .activity
                .is_none()
        );
    }

    #[test]
    #[ignore = "requires Node; set TWINE_NODE to its absolute path"]
    fn omp_extension_records_parallel_nested_children_under_original_root_turn() {
        let node = std::env::var("TWINE_NODE").expect("set TWINE_NODE");
        let (inbox, arguments) =
            prepare(Arc::new(ReplayPosition::default()), HarnessId::Omp).unwrap();
        let script = r"
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
const { default: extension } = await import(pathToFileURL(process.argv[1]));
const bind = agent => {
  const handlers = new Map();
  extension({ on: (name, handler) => handlers.set(name, handler) });
  return (name, event) => assert.equal(handlers.get(name)(Object.freeze(event), {agent}), undefined);
};
const root = bind({kind:'main',id:'Main'});
const first = bind({kind:'sub',id:'worker-a',name:'explore',parentId:'Main'});
const second = bind({kind:'sub',id:'worker-b',name:'review',parentId:'Main'});
const nested = bind({kind:'sub',id:'nested',name:'explore',parentId:'worker-a'});
const prompt = text => ({message:{role:'user',content:[{type:'text',text}]}});
const call = {toolCallId:'same',toolName:'bash',args:{command:'make test'}};
root('message_start', prompt('root prompt'));
first('message_start', prompt('first child'));
second('message_start', prompt('second child'));
nested('message_start', prompt('nested child'));
first('tool_execution_start', call);
second('tool_execution_start', call);
// A later parent prompt must not move already-running child tools to the new turn.
root('message_start', prompt('next root prompt'));
second('tool_execution_end', {...call,isError:true,result:{content:[{type:'text',text:'failed'}]}});
first('tool_execution_end', {...call,isError:false,result:{content:[{type:'text',text:'passed'}]}});
first('message_end', {message:{role:'assistant',stopReason:'stop',content:[{type:'text',text:'Done'}]}});
first('agent_end', {willContinue:true});
first('agent_end', {willContinue:false});
second('message_end', {message:{role:'assistant',stopReason:'error',content:[]}});
second('agent_end', {willContinue:false});
await delay(500);
first('session_shutdown', {});
second('session_shutdown', {});
nested('session_shutdown', {});
root('session_shutdown', {});
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
        let events = inbox.take(32);
        assert_eq!(events.len(), 11);
        let steps: Vec<_> = events.iter().map(|event| &event.step).collect();
        let first_turn = steps[0].turn_id.as_ref().unwrap();
        assert_eq!(
            steps
                .iter()
                .filter(|step| step.kind == StepKind::Prompt)
                .count(),
            2
        );
        assert!(!steps.iter().any(|step| step.kind == StepKind::Responded));
        for step in steps.iter().filter(|step| step.kind == StepKind::Activity) {
            assert_eq!(step.turn_id.as_ref(), Some(first_turn));
        }
        assert!(
            steps.iter().any(
                |step| step
                    .activity
                    .as_ref()
                    .is_some_and(|activity| activity.parent_id.as_deref()
                        == Some("agent:worker-a")
                        && activity.kind == ActivityKind::Subagent)
            )
        );
        assert!(steps.iter().any(|step| {
            step.activity
                .as_ref()
                .is_some_and(|activity| activity.id == "tool:worker-b:same" && activity.failed)
        }));
        assert!(steps.iter().any(|step| {
            step.activity
                .as_ref()
                .is_some_and(|activity| activity.id == "agent:worker-b" && activity.failed)
        }));
    }

    #[test]
    fn pi_nested_tool_events_keep_the_native_parent_call() {
        let step = parse(br#"{"type":"tool_start","turn_id":"root-turn","tool_call_id":"inner","parent_tool_call_id":"outer","tool_name":"read"}"#).unwrap();
        let activity = step.activity.unwrap();
        assert_eq!(activity.id, "tool:root:inner");
        assert_eq!(activity.parent_id.as_deref(), Some("tool:root:outer"));
    }

    #[test]
    #[ignore = "requires Node and installed Pi SDK; set TWINE_NODE and TWINE_PI_PACKAGE"]
    fn pi_installed_extension_runner_delivers_nested_tool_activity() {
        let node = std::env::var("TWINE_NODE").expect("set TWINE_NODE");
        let package = std::env::var("TWINE_PI_PACKAGE").expect("set TWINE_PI_PACKAGE");
        let (inbox, arguments) =
            prepare(Arc::new(ReplayPosition::default()), HarnessId::Pi).unwrap();
        let script = r"
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
const sdk = part => import(pathToFileURL(process.argv[2] + '/dist/core/' + part + '.js'));
const { loadExtensions } = await sdk('extensions/loader');
const { ExtensionRunner } = await sdk('extensions/runner');
const { SessionManager } = await sdk('session-manager');
const loaded = await loadExtensions([process.argv[1]], process.cwd());
assert.deepEqual(loaded.errors, []);
const runner = new ExtensionRunner(loaded.extensions, loaded.runtime, process.cwd(), SessionManager.inMemory(), {});
const emit = async event => assert.equal(await runner.emit(Object.freeze(event)), undefined);
await emit({type:'message_start',message:{role:'user',content:[{type:'text',text:'Native runner'}]}});
await emit({type:'tool_execution_start',toolCallId:'outer',toolName:'custom',args:{}});
await emit({type:'tool_execution_start',toolCallId:'inner',parentToolCallId:'outer',toolName:'read',args:{path:'src/main.rs'}});
await emit({type:'tool_execution_end',toolCallId:'inner',parentToolCallId:'outer',toolName:'read',result:{content:[{type:'text',text:'unavailable'}]},isError:true});
await emit({type:'tool_execution_end',toolCallId:'outer',toolName:'custom',result:{content:[{type:'text',text:'Done'}]},isError:false});
await emit({type:'message_end',message:{role:'assistant',stopReason:'stop',content:[{type:'text',text:'Finished'}]}});
await emit({type:'agent_settled'});
await delay(500);
await emit({type:'session_shutdown'});
";
        let output = std::process::Command::new(node)
            .args(["--input-type=module", "-e", script])
            .arg(&arguments[1])
            .arg(package)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let events = inbox.take(16);
        assert_eq!(events.len(), 6);
        let nested = events[2].step.activity.as_ref().unwrap();
        assert_eq!(nested.id, "tool:root:inner");
        assert_eq!(nested.parent_id.as_deref(), Some("tool:root:outer"));
        assert!(events[3].step.activity.as_ref().unwrap().failed);
        assert_eq!(events[5].step.kind, StepKind::Responded);
    }

    #[test]
    fn oversized_native_identity_is_rejected_without_collision() {
        for key in [
            "agent_id",
            "turn_id",
            "tool_call_id",
            "parent_agent_id",
            "parent_tool_call_id",
        ] {
            let mut input = json!({"type":"tool_start", "turn_id":"root", "tool_call_id":"call", "tool_name":"bash"});
            input[key] = json!("x".repeat(161));
            assert!(
                parse(&serde_json::to_vec(&input).unwrap()).is_none(),
                "{key}"
            );
        }
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
