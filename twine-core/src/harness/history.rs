//! Read-only reconciliation of exact harness conversations. Native IDs, not terminal text,
//! identify calls and their owning turns. Discovery and parsing run outside the terminal worker.

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::io::BufRead;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::JoinHandle;

use serde_json::{Value, json};

use super::steps::ActivityKind;
use crate::{HarnessId, WorkflowId};

#[derive(Clone)]
pub(crate) struct HistoryRequest {
    pub database: PathBuf,
    pub workflow: WorkflowId,
    pub session: String,
    pub harness: HarnessId,
}

#[derive(Clone, Debug)]
pub(crate) struct NativeActivity {
    pub id: String,
    pub parent: Option<String>,
    pub turn: Option<String>,
    pub kind: ActivityKind,
    pub title: String,
    pub input: Option<String>,
    pub output: Option<String>,
    pub started: Option<u64>,
    pub ended: Option<u64>,
    pub failed: bool,
    pub metadata: Value,
}

pub(crate) struct HistoryWorkers {
    sender: Option<mpsc::SyncSender<HistoryRequest>>,
    changed: mpsc::Receiver<WorkflowId>,
    pending: Arc<Mutex<HashSet<(PathBuf, u64, String)>>>,
    worker: Option<JoinHandle<()>>,
    cancelled: Arc<AtomicBool>,
}

impl HistoryWorkers {
    pub(crate) fn new() -> std::io::Result<Self> {
        let (sender, requests) = mpsc::sync_channel::<HistoryRequest>(16);
        let (finished, changed) = mpsc::sync_channel(16);
        let cancelled = Arc::new(AtomicBool::new(false));
        let stop = Arc::clone(&cancelled);
        let pending = Arc::new(Mutex::new(HashSet::new()));
        let running = Arc::clone(&pending);
        let worker = crate::blocking_worker::spawn("harness-history".into(), move || {
            while let Ok(request) = requests.recv() {
                if stop.load(Ordering::Acquire) {
                    break;
                }
                let key = (
                    request.database.clone(),
                    request.workflow.0,
                    request.session.clone(),
                );
                match reconcile(&request, &stop) {
                    Err(error) => {
                        tracing::warn!(%error,"couldn't reconcile recorded harness history");
                    }
                    Ok(true) => {
                        let _ = finished.try_send(request.workflow);
                    }
                    Ok(false) => {}
                }
                running
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .remove(&key);
            }
        })?;
        Ok(Self {
            sender: Some(sender),
            changed,
            pending,
            worker: Some(worker),
            cancelled,
        })
    }

    pub(crate) fn request(&self, request: HistoryRequest) {
        let key = (
            request.database.clone(),
            request.workflow.0,
            request.session.clone(),
        );
        let mut pending = self
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !pending.insert(key.clone()) {
            return;
        }
        if self
            .sender
            .as_ref()
            .is_none_or(|s| s.try_send(request).is_err())
        {
            pending.remove(&key);
        }
    }

    pub(crate) fn take_changed(&self) -> Vec<WorkflowId> {
        self.changed.try_iter().collect()
    }
}

impl Drop for HistoryWorkers {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
        self.sender.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn files(directory: &Path, name: &str, result: &mut Vec<PathBuf>, cancelled: &AtomicBool) {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        if cancelled.load(Ordering::Acquire) {
            return;
        }
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_dir() {
            files(&entry.path(), name, result, cancelled);
        } else if kind.is_file()
            && entry
                .file_name()
                .to_string_lossy()
                .ends_with(&format!("{name}.jsonl"))
        {
            result.push(entry.path());
        }
    }
}

struct SourceFile {
    path: PathBuf,
    session: String,
    agent: Option<String>,
    parent: Option<String>,
}

#[expect(
    clippy::too_many_lines,
    reason = "verified native lineage discovery differs by harness"
)]
fn source_files(request: &HistoryRequest, cancelled: &AtomicBool) -> Vec<SourceFile> {
    if matches!(request.harness, HarnessId::Pi | HarnessId::Omp) {
        let path = PathBuf::from(&request.session);
        let mut sources = Vec::new();
        if path.is_absolute() && path.is_file() {
            sources.push(SourceFile {
                path,
                session: request.session.clone(),
                agent: None,
                parent: None,
            });
        }
        if let Ok(connection) = rusqlite::Connection::open_with_flags(&request.database,rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            && let Ok(mut statement) = connection.prepare("SELECT a.source_id,a.parent_source_id,json_extract(a.metadata,'$.nativeSessionPath') FROM trace_activities a JOIN trace_spans s ON s.id=a.span_id JOIN trace_lanes l ON l.id=s.lane_id WHERE l.workflow_id=?1 AND a.kind='subagent' AND json_extract(a.metadata,'$.nativeSessionPath') IS NOT NULL")
            && let Ok(rows) = statement.query_map([i64::try_from(request.workflow.0).unwrap_or(-1)],|r|Ok((r.get::<_,String>(0)?,r.get::<_,Option<String>>(1)?,r.get::<_,String>(2)?))) {
            for (agent,parent,path) in rows.flatten() {
                let path = PathBuf::from(path);
                if path.is_absolute() && path.is_file() {
                    sources.push(SourceFile {path,session:request.session.clone(),agent:agent.strip_prefix("agent:").map(str::to_owned),parent:parent.and_then(|p|p.strip_prefix("agent:").map(str::to_owned))});
                }
            }
        }
        return sources;
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return Vec::new();
    };
    let root = match request.harness {
        HarnessId::Codex => std::env::var_os("CODEX_HOME")
            .map_or_else(|| home.join(".codex"), PathBuf::from)
            .join("sessions"),
        HarnessId::ClaudeCode => std::env::var_os("CLAUDE_CONFIG_DIR")
            .map_or_else(|| home.join(".claude"), PathBuf::from)
            .join("projects"),
        _ => return Vec::new(),
    };
    let mut result = Vec::new();
    files(&root, &request.session, &mut result, cancelled);
    if request.harness == HarnessId::ClaudeCode {
        let parents = result.clone();
        for path in parents {
            let subagents = path.with_extension("").join("subagents");
            if let Ok(entries) = std::fs::read_dir(subagents) {
                result.extend(
                    entries
                        .flatten()
                        .map(|e| e.path())
                        .filter(|p| p.extension().is_some_and(|s| s == "jsonl")),
                );
            }
        }
    }
    let mut sources: Vec<_> = result
        .into_iter()
        .map(|path| SourceFile {
            agent: path
                .file_stem()
                .and_then(|s| s.to_str())
                .and_then(|s| s.strip_prefix("agent-"))
                .map(str::to_owned),
            path,
            session: request.session.clone(),
            parent: None,
        })
        .collect();
    if request.harness == HarnessId::Codex {
        let codex = root.parent().unwrap_or(&root);
        let database = codex.join("state_5.sqlite");
        if let Ok(connection) = rusqlite::Connection::open_with_flags(
            database,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        ) {
            if let Ok(path) = connection.query_row(
                "SELECT rollout_path FROM threads WHERE id=?1",
                [&request.session],
                |row| row.get::<_, String>(0),
            ) && !sources.iter().any(|source| source.path == Path::new(&path))
            {
                sources.insert(
                    0,
                    SourceFile {
                        path: PathBuf::from(path),
                        session: request.session.clone(),
                        agent: None,
                        parent: None,
                    },
                );
            }
            let mut pending = vec![request.session.clone()];
            let mut seen = HashSet::new();
            while let Some(parent) = pending.pop() {
                if cancelled.load(Ordering::Acquire) {
                    break;
                }
                if !seen.insert(parent.clone()) {
                    continue;
                }
                if let Ok(mut statement)=connection.prepare("SELECT t.id,t.rollout_path FROM thread_spawn_edges e JOIN threads t ON t.id=e.child_thread_id WHERE e.parent_thread_id=?1")
                    && let Ok(rows)=statement.query_map([&parent],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?))) {
                        for (id,path) in rows.flatten() {
                            sources.push(SourceFile {path:PathBuf::from(path),session:id.clone(),agent:Some(id.clone()),
                                parent:(parent!=request.session).then(||parent.clone())});pending.push(id);
                        }
                }
            }
        }
    }
    sources
}

fn reconcile(request: &HistoryRequest, cancelled: &AtomicBool) -> Result<bool, crate::StoreError> {
    if request.workflow.0 == 0 {
        let mut store = crate::store::Store::open(&request.database)?;
        store.maintain_trace_storage(request.session.starts_with("@clear:"))?;
        return Ok(false);
    }
    let sources = source_files(request, cancelled);
    if sources.is_empty() {
        return Ok(false);
    }
    let mut store = crate::store::Store::open(&request.database)?;
    let mut changed = false;
    for source in sources {
        if cancelled.load(Ordering::Acquire) {
            break;
        }
        let file = std::fs::File::open(&source.path).map_err(crate::StoreError::TracePayload)?;
        let mut parser = Parser::new(request.harness, source.session, &source.path);
        parser.agent = source.agent;
        parser.owner_parent = source.parent;
        let mut model_calls = std::collections::BTreeMap::new();
        for line in std::io::BufReader::new(super::steps::CancellableReader {
            reader: file,
            cancelled,
        })
        .lines()
        {
            if cancelled.load(Ordering::Acquire) {
                break;
            }
            let line = line.map_err(crate::StoreError::TracePayload)?;
            let Ok(value) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            let observations = parser.read(&value);
            for activity in observations {
                if activity.kind == ActivityKind::Model {
                    model_calls.insert(activity.id.clone(), activity);
                    continue;
                }
                changed |= store.reconcile_native_activity(
                    request.workflow,
                    &request.session,
                    &activity,
                )?;
            }
        }
        for activity in model_calls.into_values() {
            if cancelled.load(Ordering::Acquire) {
                break;
            }
            changed |=
                store.reconcile_native_activity(request.workflow, &request.session, &activity)?;
        }
    }
    store.maintain_trace_storage(false)?;
    Ok(changed)
}

struct Parser {
    harness: HarnessId,
    session: String,
    agent: Option<String>,
    verified: bool,
    turn: Option<String>,
    model: Option<String>,
    response: Vec<String>,
    tools: Vec<String>,
    parents: std::collections::HashMap<String, String>,
    prompt_title: Option<String>,
    prompt_time: Option<u64>,
    owner_parent: Option<String>,
    claude_calls: HashMap<String, (Vec<(String, String)>, Value)>,
    assignments: HashMap<String, (String, Option<u64>)>,
    calls: HashSet<String>,
    assignment_recorded: bool,
}

impl Parser {
    fn new(harness: HarnessId, session: String, path: &Path) -> Self {
        let agent = path
            .file_stem()
            .and_then(|s| s.to_str())
            .and_then(|s| s.strip_prefix("agent-"))
            .map(str::to_owned);
        Self {
            harness,
            session,
            agent,
            verified: false,
            turn: None,
            model: None,
            response: Vec::new(),
            tools: Vec::new(),
            parents: HashMap::default(),
            prompt_title: None,
            prompt_time: None,
            owner_parent: None,
            claude_calls: HashMap::new(),
            assignments: HashMap::new(),
            calls: HashSet::new(),
            assignment_recorded: false,
        }
    }

    fn activity(
        &self,
        id: String,
        kind: ActivityKind,
        title: String,
        time: Option<u64>,
    ) -> NativeActivity {
        NativeActivity {
            id,
            parent: self.agent.as_ref().map(|id| format!("agent:{id}")),
            turn: self.turn.clone(),
            kind,
            title,
            input: None,
            output: None,
            started: None,
            ended: time,
            failed: false,
            metadata: json!({"source":"Harness history","model":self.model,"promptTitle":self.prompt_title,"promptTime":self.prompt_time}),
        }
    }

    fn read(&mut self, value: &Value) -> Vec<NativeActivity> {
        match self.harness {
            HarnessId::Codex => self.codex(value),
            HarnessId::ClaudeCode => self.claude(value),
            HarnessId::Pi | HarnessId::Omp => self.pi(value),
            _ => Vec::new(),
        }
    }

    #[expect(
        clippy::too_many_lines,
        reason = "one branch per Codex archive record type"
    )]
    fn codex(&mut self, v: &Value) -> Vec<NativeActivity> {
        let p = &v["payload"];
        let time = timestamp(&v["timestamp"]);
        if v["type"] == "session_meta" {
            self.verified = p["id"] == self.session || p["session_id"] == self.session;
            return Vec::new();
        }
        if !self.verified {
            return Vec::new();
        }
        if v["type"] == "turn_context" {
            self.turn = string(&p["turn_id"]);
            self.model = string(&p["model"]);
        } else if v["type"] == "event_msg" && p["type"] == "item_completed" {
            let item = &p["item"];
            self.turn = string(&p["turn_id"]).or_else(|| self.turn.clone());
            let started = p["started_at_ms"].as_u64();
            let ended = p["completed_at_ms"].as_u64().or(time);
            match item["type"].as_str() {
                Some("SubAgentActivity") => {
                    if let Some(id) = string(&item["agent_thread_id"]) {
                        let mut a = self.activity(
                            format!("agent:{id}"),
                            ActivityKind::Subagent,
                            item["agent_path"].as_str().unwrap_or("Subagent").into(),
                            None,
                        );
                        a.parent = self.agent.as_ref().map(|id| format!("agent:{id}"));
                        if item["kind"] == "started" {
                            a.started = started.or(time);
                        } else {
                            a.ended = ended;
                        }
                        return vec![a];
                    }
                }
                Some("CommandExecution") => {
                    if let Some(id) = string(&item["id"]) {
                        let mut a = self.activity(
                            format!("tool:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                            ActivityKind::Tool,
                            format!("Run {}", item["command"].as_str().unwrap_or("command")),
                            ended,
                        );
                        a.started = started;
                        a.input = item.get("command").map(detail);
                        a.output = item
                            .get("aggregated_output")
                            .or_else(|| item.get("stdout"))
                            .map(detail);
                        a.failed = item["exit_code"].as_i64().is_some_and(|code| code != 0);
                        return vec![a];
                    }
                }
                Some("FileChange") => {
                    if let Some(id) = string(&item["id"]) {
                        let mut a = self.activity(
                            format!("tool:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                            ActivityKind::Tool,
                            "Change files".into(),
                            ended,
                        );
                        a.started = started;
                        a.failed = matches!(item["status"].as_str(), Some("failed" | "declined"));
                        a.input = Some(file_changes(&item["changes"]));
                        a.output = Some(
                            [item["stdout"].as_str(), item["stderr"].as_str()]
                                .into_iter()
                                .flatten()
                                .filter(|text| !text.is_empty())
                                .collect::<Vec<_>>()
                                .join("\n"),
                        );
                        return vec![a];
                    }
                }
                Some(
                    kind @ ("Extension" | "ImageView" | "McpToolCall" | "CollabAgentToolCall"),
                ) => {
                    if let Some(id) = string(&item["id"]) {
                        // A matching provider call already has its own activity. Keep this
                        // richer native observation beneath it without counting another call.
                        let supplemental = self.calls.contains(&id);
                        let source =
                            format!("tool:{}:{id}", self.agent.as_deref().unwrap_or("root"));
                        let title = item["tool"].as_str().map_or_else(
                            || match kind {
                                "Extension" => "Extension activity".into(),
                                "ImageView" => "View image".into(),
                                _ => "Native tool activity".into(),
                            },
                            |tool| format!("Call {tool}"),
                        );
                        let mut a = self.activity(
                            if supplemental {
                                format!("native:{source}")
                            } else {
                                source.clone()
                            },
                            if supplemental {
                                ActivityKind::Note
                            } else {
                                ActivityKind::Tool
                            },
                            title,
                            ended,
                        );
                        if supplemental {
                            a.parent = Some(source);
                        }
                        a.started = started;
                        a.failed = matches!(
                            item["status"].as_str(),
                            Some("failed" | "declined" | "errored")
                        ) || item["result"]["isError"] == true
                            || item["result"]["is_error"] == true;
                        a.input = item
                            .get("arguments")
                            .or_else(|| item.get("query"))
                            .or_else(|| item.get("path"))
                            .map(detail);
                        // Preserve result blocks and every emitted field, including collaboration
                        // states/search results, rather than selecting only a text preview.
                        a.output = Some(
                            serde_json::to_string_pretty(item).unwrap_or_else(|_| item.to_string()),
                        );
                        a.metadata["recordFormat"] = "Native JSON record".into();
                        return vec![a];
                    }
                }
                Some("ContextCompaction") => {
                    if let Some(id) = string(&item["id"]) {
                        return vec![self.activity(
                            format!(
                                "note:compaction:{}:{id}",
                                self.agent.as_deref().unwrap_or("root")
                            ),
                            ActivityKind::Note,
                            "Context compacted".into(),
                            ended,
                        )];
                    }
                }
                Some("Reasoning") => {
                    let summary = item["summary_text"].as_str().map_or_else(
                        || {
                            item["summary_text"]
                                .as_array()
                                .into_iter()
                                .flatten()
                                .filter_map(Value::as_str)
                                .filter(|text| !text.trim().is_empty())
                                .collect::<Vec<_>>()
                                .join("\n\n")
                        },
                        str::to_owned,
                    );
                    if let Some(id) = string(&item["id"])
                        && !summary.trim().is_empty()
                    {
                        let mut a = self.activity(
                            format!("summary:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                            ActivityKind::Note,
                            "Reasoning summary".into(),
                            ended,
                        );
                        a.output = Some(summary);
                        return vec![a];
                    }
                    // Raw reasoning is not an exposed summary and is never imported.
                }
                Some(kind @ ("UserMessage" | "AgentMessage")) => {
                    if let Some(id) = string(&item["id"]) {
                        let text = content(&item["content"]);
                        if text.is_empty() || item["phase"] == "analysis" {
                            return Vec::new();
                        }
                        let mut a = self.activity(
                            format!("message:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                            ActivityKind::Note,
                            if kind == "UserMessage" {
                                "User message"
                            } else {
                                "Assistant message"
                            }
                            .into(),
                            ended,
                        );
                        if kind == "UserMessage" {
                            a.input = Some(text.clone());
                        } else {
                            a.output = Some(text.clone());
                        }
                        let mut records = vec![a];
                        if kind == "AgentMessage"
                            && item["phase"] == "final"
                            && let Some(agent) = &self.agent
                        {
                            let mut child = self.activity(
                                format!("agent:{agent}"),
                                ActivityKind::Subagent,
                                "Subagent".into(),
                                None,
                            );
                            child.parent =
                                self.owner_parent.as_ref().map(|id| format!("agent:{id}"));
                            child.output = Some(text);
                            records.push(child);
                        }
                        return records;
                    }
                }
                _ => {}
            }
        } else if v["type"] == "response_item" {
            if p["type"] == "message" && p["role"] == "user" {
                let text = content(&p["content"]);
                if !text.is_empty() && !text.starts_with("<environment_context>") {
                    self.prompt_title = Some(super::steps::truncate(&text, 160));
                    self.prompt_time = time;
                }
                self.turn = string(&p["internal_chat_message_metadata_passthrough"]["turn_id"])
                    .or_else(|| self.turn.clone());
                if let Some(agent) = &self.agent
                    && !self.assignment_recorded
                    && !text.is_empty()
                    && !text.starts_with("<environment_context>")
                {
                    let mut a = self.activity(
                        format!("agent:{agent}"),
                        ActivityKind::Subagent,
                        "Subagent".into(),
                        None,
                    );
                    a.parent = self.owner_parent.as_ref().map(|id| format!("agent:{id}"));
                    a.input = Some(text);
                    a.started = time;
                    self.assignment_recorded = true;
                    return vec![a];
                }
            }
            if p["type"] == "message" && p["role"] == "assistant" && p["channel"] != "analysis" {
                self.response.push(content(&p["content"]));
            } else if p["type"] == "reasoning" {
                let summary = content(&p["summary"]);
                if !summary.is_empty() {
                    self.response.push(format!("Reasoning summary: {summary}"));
                }
            } else if matches!(
                p["type"].as_str(),
                Some("function_call" | "custom_tool_call")
            ) {
                self.tools.push(p["name"].as_str().unwrap_or("Tool").into());
                if let Some(id) = string(&p["call_id"]) {
                    self.calls.insert(id.clone());
                    let mut a = self.activity(
                        format!("tool:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                        ActivityKind::Tool,
                        format!("Call {}", p["name"].as_str().unwrap_or("tool")),
                        None,
                    );
                    a.started = time;
                    a.input = p.get("arguments").or_else(|| p.get("input")).map(detail);
                    return vec![a];
                }
            } else if matches!(
                p["type"].as_str(),
                Some("function_call_output" | "custom_tool_call_output")
            ) && let Some(id) = string(&p["call_id"])
            {
                let mut a = self.activity(
                    format!("tool:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                    ActivityKind::Tool,
                    "Tool result".into(),
                    time,
                );
                a.output = p.get("output").map(detail);
                return vec![a];
            }
        } else if v["type"] == "token_usage_record" {
            let Some(id) = string(&p["response_id"]) else {
                return Vec::new();
            };
            let mut a = self.activity(
                format!("model:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                ActivityKind::Model,
                "LLM call".into(),
                time,
            );
            a.turn = string(&p["turn_id"]).or_else(|| self.turn.clone());
            let mut output = std::mem::take(&mut self.response).join("\n\n");
            if !self.tools.is_empty() {
                let _ = write!(
                    output,
                    "\nTool calls: {}",
                    std::mem::take(&mut self.tools).join(", ")
                );
            }
            a.output = Some(output);
            let u = &p["usage"];
            a.metadata = json!({"source":"Harness history","model":self.model,"responseId":id,"promptTitle":self.prompt_title,"promptTime":self.prompt_time,
                "inputTokens":u["input_tokens"],"outputTokens":u["output_tokens"],
                "reasoningTokens":u["reasoning_output_tokens"],"cacheReadTokens":u["cached_input_tokens"],"cacheWriteTokens":u["cache_write_input_tokens"],"totalTokens":u["total_tokens"]});
            return vec![a];
        } else if v["type"] == "event_msg"
            && matches!(p["type"].as_str(), Some("context_compacted" | "compaction"))
        {
            let mut a = self.activity(
                format!("note:compaction:{}", time.unwrap_or(0)),
                ActivityKind::Note,
                "Context compacted".into(),
                time,
            );
            a.output = p.get("summary").map(detail);
            return vec![a];
        }
        Vec::new()
    }

    #[expect(
        clippy::too_many_lines,
        reason = "one branch per Claude archive record type"
    )]
    fn claude(&mut self, v: &Value) -> Vec<NativeActivity> {
        if v["sessionId"] == self.session || v["session_id"] == self.session {
            self.verified = true;
        }
        if !self.verified {
            return Vec::new();
        }
        let time = timestamp(&v["timestamp"]);
        let m = &v["message"];
        if let Some(turn) = string(&v["promptId"]) {
            self.turn = Some(turn);
        }
        if let Some(parent) = v["parentUuid"].as_str().and_then(|id| self.parents.get(id)) {
            self.turn = Some(parent.clone());
        }
        if let (Some(id), Some(turn)) = (string(&v["uuid"]), self.turn.clone()) {
            self.parents.insert(id, turn);
        }
        let mut result = Vec::new();
        if v["type"] == "assistant" {
            self.model = string(&m["model"]);
            if let Some(id) = string(&v["requestId"]).or_else(|| string(&m["id"])) {
                let mut a = self.activity(
                    format!("model:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                    ActivityKind::Model,
                    "LLM call".into(),
                    time,
                );
                let mut text = content(&m["content"]);
                for block in m["content"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|b| b["type"] == "tool_use")
                {
                    let _ = write!(
                        text,
                        "\nTool call: {}",
                        block["name"].as_str().unwrap_or("tool")
                    );
                }
                let block_id = string(&v["uuid"]).unwrap_or_else(|| text.clone());
                let (blocks, usage) = self
                    .claude_calls
                    .entry(id.clone())
                    .or_insert_with(|| (Vec::new(), json!({})));
                if let Some((_, previous)) = blocks.iter_mut().find(|(key, _)| key == &block_id) {
                    *previous = text;
                } else {
                    blocks.push((block_id, text));
                }
                if let Some(fields) = m["usage"].as_object() {
                    for (key, value) in fields {
                        if !value.is_null() {
                            usage[key] = value.clone();
                        }
                    }
                }
                a.output = Some(
                    blocks
                        .iter()
                        .map(|(_, text)| text.as_str())
                        .filter(|text| !text.is_empty())
                        .collect::<Vec<_>>()
                        .join("\n\n"),
                );
                a.metadata = json!({"source":"Harness history","model":self.model,"responseId":id,"promptTitle":self.prompt_title,"promptTime":self.prompt_time,
                    "inputTokens":usage["input_tokens"],"outputTokens":usage["output_tokens"],
                    "cacheReadTokens":usage["cache_read_input_tokens"],"cacheWriteTokens":usage["cache_creation_input_tokens"]});
                result.push(a);
            }
            for block in m["content"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|b| b["type"] == "tool_use")
            {
                if let Some(id) = string(&block["id"]) {
                    let mut a = self.activity(
                        format!("tool:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                        ActivityKind::Tool,
                        format!("Call {}", block["name"].as_str().unwrap_or("tool")),
                        None,
                    );
                    a.input = block.get("input").map(detail);
                    if let Some(prompt) = block["input"]["prompt"].as_str() {
                        self.assignments.insert(id.clone(), (prompt.into(), time));
                    }
                    a.started = time;
                    result.push(a);
                }
            }
        } else if v["type"] == "user" {
            let text = content(&m["content"]);
            if !text.is_empty() {
                self.prompt_title = Some(super::steps::truncate(&text, 160));
                self.prompt_time = time;
            }
            if let Some(agent) = &self.agent {
                let mut a = self.activity(
                    format!("agent:{agent}"),
                    ActivityKind::Subagent,
                    "Subagent".into(),
                    None,
                );
                a.parent = None;
                a.input = Some(content(&m["content"]));
                a.started = time;
                result.push(a);
            }
            for block in m["content"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|b| b["type"] == "tool_result")
            {
                if let Some(id) = string(&block["tool_use_id"]) {
                    let mut a = self.activity(
                        format!("tool:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                        ActivityKind::Tool,
                        "Tool result".into(),
                        time,
                    );
                    a.output = Some(content(&block["content"]));
                    a.failed = block["is_error"] == true;
                    if let Some(agent) = string(&v["toolUseResult"]["agentId"]) {
                        let mut child = self.activity(
                            format!("agent:{agent}"),
                            ActivityKind::Subagent,
                            "Subagent".into(),
                            time,
                        );
                        if v["toolUseResult"]["isAsync"] == true
                            || v["toolUseResult"]["status"] == "async_launched"
                        {
                            child.ended = None;
                            child.metadata["event"] = "Background agent launched".into();
                        } else {
                            child.output.clone_from(&a.output);
                            child.failed = a.failed;
                        }
                        if let Some((prompt, start)) = self.assignments.get(&id) {
                            child.input = Some(prompt.clone());
                            child.started = *start;
                        }
                        result.push(child);
                    }
                    result.push(a);
                }
            }
        } else if v["type"] == "system" && v["subtype"] == "compact_boundary" {
            let mut a = self.activity(
                format!("note:compact:{}", v["uuid"].as_str().unwrap_or("unknown")),
                ActivityKind::Note,
                "Context compacted".into(),
                time,
            );
            a.output = Some(detail(&v["compactMetadata"]));
            result.push(a);
        }
        result
    }

    fn pi(&mut self, v: &Value) -> Vec<NativeActivity> {
        if v["type"] == "session" {
            self.verified = true;
            return Vec::new();
        }
        if !self.verified {
            return Vec::new();
        }
        let m = &v["message"];
        if v["type"] == "model_change" {
            self.model = string(&v["modelId"]);
        }
        if v["type"] != "message" {
            return Vec::new();
        }
        if m["role"] == "user" {
            self.turn = string(&v["id"]);
            self.prompt_title = Some(super::steps::truncate(&content(&m["content"]), 160));
            self.prompt_time = timestamp(&v["timestamp"]);
            return Vec::new();
        }
        let time = timestamp(&v["timestamp"]);
        let mut result = Vec::new();
        if m["role"] == "assistant" {
            let Some(id) = string(&m["responseId"]).or_else(|| string(&v["id"])) else {
                return result;
            };
            let mut a = self.activity(
                format!("model:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                ActivityKind::Model,
                "LLM call".into(),
                time,
            );
            a.output = Some(content(&m["content"]));
            a.failed = matches!(m["stopReason"].as_str(), Some("error" | "aborted"));
            let u = &m["usage"];
            a.metadata = json!({"source":"Harness history","model":m["model"],"responseId":string(&m["responseId"]),"nativeMessageTimestamp":m["timestamp"],"promptTitle":self.prompt_title,"promptTime":self.prompt_time,
                "inputTokens":u["input"],"outputTokens":u["output"],"cacheReadTokens":u["cacheRead"],"cacheWriteTokens":u["cacheWrite"],
                "totalTokens":u["totalTokens"],"cost":u["cost"]["total"],"stopReason":m["stopReason"]});
            result.push(a);
            for b in m["content"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|b| b["type"] == "toolCall")
            {
                if let Some(id) = string(&b["id"]) {
                    let mut a = self.activity(
                        format!("tool:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                        ActivityKind::Tool,
                        format!("Call {}", b["name"].as_str().unwrap_or("tool")),
                        None,
                    );
                    a.input = b.get("arguments").map(detail);
                    a.started = time;
                    result.push(a);
                }
            }
        } else if m["role"] == "toolResult"
            && let Some(id) = string(&m["toolCallId"])
        {
            let mut a = self.activity(
                format!("tool:{}:{id}", self.agent.as_deref().unwrap_or("root")),
                ActivityKind::Tool,
                "Tool result".into(),
                time,
            );
            a.output = Some(content(&m["content"]));
            a.failed = m["isError"] == true;
            result.push(a);
        }
        result
    }
}

fn string(value: &Value) -> Option<String> {
    value.as_str().filter(|s| !s.is_empty()).map(str::to_owned)
}

fn file_changes(value: &Value) -> String {
    let Some(changes) = value.as_object() else {
        return detail(value);
    };
    let mut text = String::new();
    for (path, change) in changes {
        let _ = writeln!(
            text,
            "{} {path}",
            change["type"].as_str().unwrap_or("Change")
        );
        if let Some(moved) = change["move_path"].as_str() {
            let _ = writeln!(text, "Move to: {moved}");
        }
        if let Some(diff) = change["unified_diff"].as_str() {
            text.push_str(diff);
            text.push('\n');
        } else {
            let _ = writeln!(text, "{}", detail(change));
        }
    }
    text
}
fn detail(value: &Value) -> String {
    value
        .as_str()
        .map_or_else(|| value.to_string(), str::to_owned)
}
fn content(value: &Value) -> String {
    if let Some(s) = value.as_str() {
        return s.into();
    }
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter(|b| {
            matches!(
                b["type"].as_str(),
                Some("Text" | "text" | "output_text" | "input_text" | "summary_text")
            )
        })
        .filter_map(|b| b["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

fn timestamp(value: &Value) -> Option<u64> {
    if let Some(n) = value.as_u64() {
        return Some(n);
    }
    let s = value.as_str()?;
    if !s.ends_with('Z') {
        return None;
    }
    let number = |a, b| s.get(a..b)?.parse::<i32>().ok();
    // SAFETY: tm contains only scalar fields and nullable pointers; zero initialization is valid.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = number(0, 4)? - 1900;
    tm.tm_mon = number(5, 7)? - 1;
    tm.tm_mday = number(8, 10)?;
    tm.tm_hour = number(11, 13)?;
    tm.tm_min = number(14, 16)?;
    tm.tm_sec = number(17, 19)?;
    // SAFETY: timegm receives a valid, exclusively borrowed tm and does not alter timezone state.
    let seconds = unsafe { libc::timegm(&raw mut tm) };
    let millis = s
        .get(20..23)
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    u64::try_from(seconds)
        .ok()?
        .checked_mul(1000)?
        .checked_add(millis)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_public_messages_preserve_child_results_without_importing_context_as_assignment_or_raw_reasoning()
     {
        let mut parser = Parser::new(
            HarnessId::Codex,
            "session".into(),
            Path::new("agent-child.jsonl"),
        );
        parser.owner_parent = Some("planner".into());
        parser.read(&json!({"type":"session_meta","payload":{"id":"session"}}));
        assert_eq!(parser.read(&json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>Context</environment_context>"}]}})).len(),0);
        let assignment=parser.read(&json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Review implementation"}]}}));
        assert_eq!(
            assignment[0].input.as_deref(),
            Some("Review implementation")
        );
        let text = "Complete public response ☃".repeat(1000);
        let rows=parser.read(&json!({"type":"event_msg","payload":{"type":"item_completed","completed_at_ms":2000,"item":{"type":"AgentMessage","id":"final","phase":"final","content":[{"type":"Text","text":text}]}}}));
        assert_eq!(rows[0].output.as_deref(), Some(text.as_str()));
        assert_eq!(rows[1].id, "agent:child");
        assert_eq!(rows[1].output.as_deref(), Some(text.as_str()));
        assert_eq!(rows[1].parent.as_deref(), Some("agent:planner"));
        assert_eq!(rows[1].ended, None);
        let summaries=parser.read(&json!({"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"summary","summary_text":["Exposed summary"],"raw_content":"private data"}}}));
        assert_eq!(summaries[0].output.as_deref(), Some("Exposed summary"));
        assert_eq!(parser.read(&json!({"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"hidden","summary_text":[],"raw_content":"private data"}}})).len(),0);
    }

    #[test]
    fn codex_file_change_records_keep_every_diff_move_output_and_failure() {
        let mut parser = Parser::new(
            HarnessId::Codex,
            "session".into(),
            Path::new("source.jsonl"),
        );
        parser.read(&json!({"type":"session_meta","payload":{"id":"session"}}));
        let diff = "@@ -1 +1 @@\n-old\n+new ☃\n".repeat(1000);
        let rows=parser.read(&json!({"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn","started_at_ms":1000,"completed_at_ms":2000,
            "item":{"type":"FileChange","id":"file-change-native-id","changes":{"src/a.rs":{"type":"update","unified_diff":diff,"move_path":"src/moved.rs"},"src/b.rs":{"type":"add","unified_diff":"+second file\n","move_path":null}},"status":"failed","stdout":"First file saved","stderr":"Second file failed"}}}));
        let row = &rows[0];
        assert_eq!(row.id, "tool:root:file-change-native-id");
        assert_eq!(row.turn.as_deref(), Some("turn"));
        assert_eq!(row.started, Some(1000));
        assert_eq!(row.ended, Some(2000));
        assert!(row.failed);
        let input = row.input.as_ref().unwrap();
        assert!(input.contains(&diff));
        assert!(input.contains("Move to: src/moved.rs"));
        assert!(input.contains("+second file\n"));
        assert_eq!(
            row.output.as_deref(),
            Some("First file saved\nSecond file failed")
        );
    }

    #[test]
    fn claude_background_launch_acknowledges_assignment_without_inventing_child_completion() {
        let mut parser = Parser::new(
            HarnessId::ClaudeCode,
            "session".into(),
            Path::new("session.jsonl"),
        );
        parser.read(&json!({"type":"assistant","sessionId":"session","promptId":"turn","requestId":"response","message":{"content":[{"type":"tool_use","id":"spawn","name":"Agent","input":{"prompt":"Review implementation","run_in_background":true}}]}}));
        let rows=parser.read(&json!({"type":"user","sessionId":"session","timestamp":"2026-10-08T10:00:00Z","toolUseResult":{"status":"async_launched","isAsync":true,"agentId":"child"},"message":{"content":[{"type":"tool_result","tool_use_id":"spawn","content":"Agent launched successfully"}]}}));
        let child = rows
            .iter()
            .find(|row| row.kind == ActivityKind::Subagent)
            .unwrap();
        assert_eq!(child.id, "agent:child");
        assert_eq!(child.input.as_deref(), Some("Review implementation"));
        assert_eq!(child.ended, None);
        assert_eq!(child.output, None);
    }

    #[test]
    fn claude_streamed_blocks_share_one_response_and_keep_final_usage_without_private_thinking() {
        let mut parser = Parser::new(
            HarnessId::ClaudeCode,
            "session".into(),
            Path::new("session.jsonl"),
        );
        let first=parser.read(&json!({"type":"assistant","sessionId":"session","promptId":"turn","uuid":"one","requestId":"response","message":{"model":"model","content":[{"type":"text","text":"First"},{"type":"thinking","thinking":"private"}],"usage":{"input_tokens":120,"output_tokens":1}}}));
        assert_eq!(first[0].output.as_deref(), Some("First"));
        let second=parser.read(&json!({"type":"assistant","sessionId":"session","promptId":"turn","uuid":"two","requestId":"response","message":{"model":"model","content":[{"type":"text","text":"Second"}],"usage":{"output_tokens":2}}}));
        assert_eq!(first[0].id, second[0].id);
        assert_eq!(second[0].output.as_deref(), Some("First\n\nSecond"));
        assert_eq!(second[0].metadata["inputTokens"], 120);
        assert_eq!(second[0].metadata["outputTokens"], 2);
    }

    #[test]
    fn codex_native_response_ids_retain_usage_and_only_exposed_summaries() {
        let mut p = Parser::new(
            HarnessId::Codex,
            "session".into(),
            Path::new("source.jsonl"),
        );
        p.read(&json!({"type":"session_meta","payload":{"id":"session"}}));
        p.read(&json!({"type":"turn_context","payload":{"turn_id":"turn","model":"native-model"}}));
        p.read(&json!({"type":"response_item","payload":{"type":"reasoning","encrypted_content":"not exposed","summary":[{"type":"summary_text","text":"Checked the implementation"}]}}));
        let rows=p.read(&json!({"type":"token_usage_record","timestamp":"2026-10-01T00:00:00.123Z","payload":{"response_id":"response","turn_id":"turn","usage":{"input_tokens":20,"output_tokens":5}}}));
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].started, None);
        assert_eq!(rows[0].metadata["inputTokens"], 20);
        assert_eq!(
            rows[0].output.as_deref(),
            Some("Reasoning summary: Checked the implementation")
        );
        assert_eq!(rows[0].ended, Some(1_790_812_800_123));
    }
}
#[test]
fn codex_native_public_tools_keep_complete_records_and_only_count_unpaired_calls() {
    let mut parser = Parser::new(
        HarnessId::Codex,
        "session".into(),
        Path::new("source.jsonl"),
    );
    parser.read(&json!({"type":"session_meta","payload":{"id":"session"}}));
    parser.read(&json!({"type":"turn_context","payload":{"turn_id":"turn"}}));
    for (kind, id) in [
        ("Extension", "search"),
        ("ImageView", "image"),
        ("McpToolCall", "mcp"),
        ("CollabAgentToolCall", "wait"),
    ] {
        if id == "wait" {
            parser.read(&json!({"type":"response_item","payload":{"type":"function_call","call_id":"wait","name":"wait","arguments":"{}"}}));
        }
        let item = json!({"type":kind,"id":id,"tool":"actual-tool","arguments":{"path":"image.png"},"status":"completed","result":{"content":[{"type":"text","text":"Complete result ☃".repeat(1000)}]},"receiver_agents":["child"],"query":{"q":"recorded query"}});
        let rows=parser.read(&json!({"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn","started_at_ms":1000,"completed_at_ms":2000,"item":item}}));
        let row = &rows[0];
        assert_eq!(
            row.kind,
            if id == "wait" {
                ActivityKind::Note
            } else {
                ActivityKind::Tool
            }
        );
        assert_eq!(
            row.parent.as_deref(),
            if id == "wait" {
                Some("tool:root:wait")
            } else {
                None
            }
        );
        assert_eq!(
            serde_json::from_str::<Value>(row.output.as_ref().unwrap()).unwrap(),
            item
        );
        assert_eq!(row.started, Some(1000));
        assert_eq!(row.ended, Some(2000));
    }
    let rows=parser.read(&json!({"type":"event_msg","payload":{"type":"item_completed","item":{"type":"ContextCompaction","id":"compact"},"completed_at_ms":3000}}));
    assert_eq!(rows[0].kind, ActivityKind::Note);
    assert_eq!(rows[0].output, None);
}
