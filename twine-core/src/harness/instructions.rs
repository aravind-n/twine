//! Launch-only role instructions. This channel never submits a user turn.
use std::ffi::OsString;
use std::io;

use super::{HarnessId, LocatedHarness, steps::StepInbox};
use std::path::Path;

mod codex;

pub(crate) fn append(
    harness: HarnessId,
    instructions: &str,
    arguments: &mut Vec<OsString>,
    hooks: Option<&StepInbox>,
    located: &LocatedHarness,
    folder: &Path,
) -> io::Result<()> {
    match harness {
        HarnessId::Codex => {
            arguments.extend([
                OsString::from("-c"),
                OsString::from(format!(
                    "developer_instructions={}",
                    toml::Value::String(codex::combined_instructions(
                        located,
                        folder,
                        instructions
                    )?)
                )),
            ]);
        }
        HarnessId::ClaudeCode | HarnessId::Pi | HarnessId::Omp => {
            arguments.extend([
                OsString::from("--append-system-prompt"),
                OsString::from(instructions),
            ]);
        }
        HarnessId::Opencode => {
            let inbox = hooks
                .ok_or_else(|| io::Error::other("Could not prepare OpenCode role instructions."))?;
            let path = inbox.directory.path().join("twine-observer.mjs");
            let source = std::fs::read_to_string(&path)?;
            let source = source.replace("  return {\n    \"chat.message\":", &format!(
                "  return {{\n    \"experimental.chat.system.transform\": async (input, output) => {{ if (!input.sessionID) return; let session = sessions.get(input.sessionID); if (!session && client.session?.get) {{ const result = await client.session.get({{path:{{id:input.sessionID}}}}); session = remember(result.data); }} if (session && !session.parent) output.system.push({}); }},\n    \"chat.message\":",
                serde_json::to_string(instructions)?));
            std::fs::write(path, source)?;
        }
        HarnessId::Antigravity => {
            let inbox = hooks.ok_or_else(|| {
                io::Error::other("Could not prepare Antigravity role instructions.")
            })?;
            std::fs::write(
                inbox.directory.path().join("role-context.json"),
                serde_json::to_vec(
                    &serde_json::json!({"injectSteps": [{"ephemeralMessage": instructions}]}),
                )?,
            )?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn instructions_use_native_flags_and_do_not_submit_a_prompt() {
        for harness in [HarnessId::ClaudeCode, HarnessId::Pi, HarnessId::Omp] {
            let mut arguments = Vec::new();
            append(
                harness,
                "Wait for a task.\nQuotes: \"value\"",
                &mut arguments,
                None,
                &LocatedHarness {
                    program: "/unused".into(),
                    path: OsString::new(),
                },
                Path::new("/"),
            )
            .unwrap();
            assert_eq!(arguments.len(), 2);
            assert_ne!(arguments[0], "--");
            assert_eq!(arguments[0], "--append-system-prompt");
            assert_eq!(arguments[1], "Wait for a task.\nQuotes: \"value\"");
        }
    }
    #[test]
    fn antigravity_injects_context_on_root_invocation_without_a_setup_turn() {
        use std::io::Write;
        use std::process::{Command, Stdio};
        let (inbox, _) = super::super::antigravity::prepare(std::sync::Arc::new(
            crate::terminal::ReplayPosition::default(),
        ))
        .unwrap();
        append(
            HarnessId::Antigravity,
            "Role context",
            &mut Vec::new(),
            Some(&inbox),
            &LocatedHarness {
                program: "/unused".into(),
                path: OsString::new(),
            },
            Path::new("/"),
        )
        .unwrap();
        let invoke = |conversation: &str| {
            let mut child = Command::new(inbox.directory.path().join("hook.sh"))
                .arg("PreInvocation")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap();
            child
                .stdin
                .take()
                .unwrap()
                .write_all(
                    &serde_json::to_vec(
                        &serde_json::json!({"conversationId":conversation,"invocationNum":1}),
                    )
                    .unwrap(),
                )
                .unwrap();
            let result = child.wait_with_output().unwrap();
            assert!(result.status.success());
            serde_json::from_slice::<serde_json::Value>(&result.stdout).unwrap()
        };
        assert_eq!(
            invoke("root")["injectSteps"][0]["ephemeralMessage"],
            "Role context"
        );
        assert_eq!(invoke("child"), serde_json::json!({}));
        assert_eq!(
            invoke("root")["injectSteps"][0]["ephemeralMessage"],
            "Role context"
        );
    }

    #[test]
    #[ignore = "requires Node; set TWINE_NODE to its absolute path"]
    fn opencode_context_preserves_system_text_and_excludes_children_and_unknown_sessions() {
        let node = std::env::var("TWINE_NODE").expect("set TWINE_NODE");
        let (inbox, _) = super::super::opencode::prepare(std::sync::Arc::new(
            crate::terminal::ReplayPosition::default(),
        ))
        .unwrap();
        append(
            HarnessId::Opencode,
            "Role context",
            &mut Vec::new(),
            Some(&inbox),
            &LocatedHarness {
                program: "/unused".into(),
                path: OsString::new(),
            },
            Path::new("/"),
        )
        .unwrap();
        let script = r"
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const {default: plugin} = await import(pathToFileURL(process.argv[1]));
const hooks = await plugin({client:{session:{get: async ({path}) => ({data:
  path.id === 'root' ? {id:'root'} : path.id === 'child' ? {id:'child',parentID:'root'} : null
})}}});
const system = ['Existing system text'];
await hooks['experimental.chat.system.transform']({sessionID:'root'}, {system});
assert.deepEqual(system, ['Existing system text','Role context']);
for (const sessionID of ['child','missing',undefined]) {
  const system = ['Existing system text'];
  await hooks['experimental.chat.system.transform']({sessionID}, {system});
  assert.deepEqual(system, ['Existing system text']);
}
";
        let result = std::process::Command::new(node)
            .args(["--input-type=module", "-e", script])
            .arg(inbox.directory.path().join("twine-observer.mjs"))
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
    }
}
