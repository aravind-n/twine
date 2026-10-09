//! A passive per-launch `OpenCode` plugin, injected through inline configuration.

use std::ffi::OsString;
use std::io;
use std::sync::Arc;

use super::steps::StepInbox;
use crate::terminal::ReplayPosition;

pub(crate) fn prepare(position: Arc<ReplayPosition>) -> io::Result<(StepInbox, Vec<OsString>)> {
    prepare_with_config(
        position,
        std::env::var("OPENCODE_CONFIG_CONTENT").ok().as_deref(),
    )
}

fn prepare_with_config(
    position: Arc<ReplayPosition>,
    config: Option<&str>,
) -> io::Result<(StepInbox, Vec<OsString>)> {
    // Preserve all existing inline settings and plugins. Invalid/JSONC overrides are left alone;
    // observation failure must never replace user configuration or prevent an agent launch.
    let mut config: serde_json::Value = config
        .map_or_else(|| Ok(serde_json::json!({})), serde_json::from_str)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if !config.is_object() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "inline config is not an object",
        ));
    }
    let mut inbox = StepInbox::new(position, super::pi::parse)?;
    let plugin = inbox.directory.path().join("twine-observer.mjs");
    let source = include_str!("opencode-plugin.js").replace(
        "__TWINE_SOCKET__",
        &serde_json::to_string(&inbox.socket_path)?,
    );
    std::fs::write(&plugin, source)?;
    if config.get("plugin").is_none() {
        config["plugin"] = serde_json::json!([]);
    }
    let plugins = config["plugin"].as_array_mut().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "inline plugins are not an array",
        )
    })?;
    plugins.push(format!("file://{}", plugin.display()).into());
    inbox
        .environment
        .push(("OPENCODE_CONFIG_CONTENT".into(), config.to_string()));
    Ok((inbox, Vec::new()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observer_preserves_inline_policy_and_existing_plugins_without_writing_project_config() {
        let (inbox, arguments) = prepare_with_config(
            Arc::new(ReplayPosition::default()),
            Some(r#"{"permission":{"bash":"ask"},"plugin":["existing"],"model":"provider/model"}"#),
        )
        .unwrap();
        assert_eq!(arguments, Vec::<OsString>::new());
        let config: serde_json::Value = serde_json::from_str(&inbox.environment[0].1).unwrap();
        assert_eq!(config["permission"]["bash"], "ask");
        assert_eq!(config["model"], "provider/model");
        assert_eq!(config["plugin"][0], "existing");
        assert_eq!(config["plugin"].as_array().unwrap().len(), 2);
        assert!(prepare_with_config(Arc::new(ReplayPosition::default()), Some("invalid")).is_err());
    }

    #[test]
    #[ignore = "requires Node; set TWINE_NODE to its absolute path"]
    fn plugin_records_model_usage_full_tools_child_lineage_and_drains_without_mutation() {
        let node = std::env::var("TWINE_NODE").expect("set TWINE_NODE");
        let (inbox, _) = prepare_with_config(Arc::new(ReplayPosition::default()), None).unwrap();
        let source = inbox.directory.path().join("twine-observer.mjs");
        let script = r"
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const {default: plugin} = await import(pathToFileURL(process.argv[1]));
const hooks = await plugin({client:{}});
const event = async (type, properties) => hooks.event({event:{type,properties}});
await event('session.created',{info:{id:'root'}});
const output={message:{id:'turn'},parts:[{type:'text',text:'Inspect'}]};
await hooks['chat.message']({sessionID:'root'},output);
assert.deepEqual(output.parts,[{type:'text',text:'Inspect'}]);
await event('message.part.updated',{part:{id:'start',type:'step-start',sessionID:'root',messageID:'response'}});
await event('message.part.updated',{part:{id:'text',type:'text',sessionID:'root',messageID:'response',text:'Public summary'}});
await event('message.part.updated',{part:{id:'finish',type:'step-finish',sessionID:'root',messageID:'response',reason:'tool-calls',tokens:{input:12,output:4,cache:{read:2,write:0}},cost:0.00001}});
await event('session.created',{info:{id:'child',parentID:'root',title:'Review'}});
await hooks['chat.message']({sessionID:'child'},{message:{id:'child-turn'},parts:[{type:'text',text:'Review implementation'}]});
const args={command:'x'.repeat(30000)};
await hooks['tool.execute.before']({sessionID:'child',callID:'call',tool:'bash'},{args});
assert.equal(args.command.length,30000);
await hooks['tool.execute.after']({sessionID:'child',callID:'call',tool:'bash'},{output:'result',metadata:{}});
await event('session.status',{sessionID:'root',status:{type:'retry',attempt:1,message:'retry'}});
await event('session.idle',{sessionID:'child'});
await event('message.updated',{info:{sessionID:'root',role:'assistant',time:{completed:1},finish:'stop',modelID:'model'}});
await event('session.idle',{sessionID:'root'});
await hooks['chat.message']({sessionID:'root'},{message:{id:'failed'},parts:[{type:'text',text:'Will fail'}]});
await event('session.error',{sessionID:'root',error:{message:'failed'}});
await event('session.idle',{sessionID:'root'});
await event('message.updated',{info:{sessionID:'root',role:'assistant',time:{completed:3},finish:'stop'}});
await event('session.idle',{sessionID:'root'});
await hooks['chat.message']({sessionID:'root'},{message:{id:'abort'},parts:[{type:'text',text:'Will abort'}]});
await event('message.updated',{info:{sessionID:'root',role:'assistant',time:{completed:2},error:{name:'MessageAbortedError'}}});
await event('session.idle',{sessionID:'root'});
await hooks.dispose();
";
        let output = std::process::Command::new(node)
            .args(["--input-type=module", "-e", script])
            .arg(source)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let events = inbox.take(256);
        assert_eq!(events.len(), 14);
        let model = events
            .iter()
            .find(|e| {
                e.step.activity.as_ref().is_some_and(|a| {
                    a.kind == super::super::steps::ActivityKind::Model
                        && a.phase == super::super::steps::ActivityPhase::Finished
                })
            })
            .unwrap();
        assert_eq!(model.step.detail, "Public summary");
        assert_eq!(
            model.step.activity.as_ref().unwrap().metadata["inputTokens"],
            12
        );
        let tool = events
            .iter()
            .find(|e| e.step.tool_call_id.as_deref() == Some("call") && e.step.detail.len() > 1000)
            .unwrap();
        let activity = tool.step.activity.as_ref().unwrap();
        assert_eq!(activity.parent_id.as_deref(), Some("agent:child"));
        assert!(
            std::fs::read_to_string(activity.detail_path.as_ref().unwrap())
                .unwrap()
                .contains(&"x".repeat(30000))
        );
        assert_eq!(
            events
                .iter()
                .filter(|event| event.step.kind == super::super::steps::StepKind::Responded)
                .count(),
            2
        );
    }
}
