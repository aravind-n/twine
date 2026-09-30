//! Process-level crash tests host the real application core, database, harnesses, and PTYs.

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::process::ExitStatusExt;
    use std::path::Path;
    use std::process::{Child, Command as ProcessCommand};
    use std::thread;
    use std::time::{Duration, Instant};

    use serde::{Deserialize, Serialize};

    use crate::config::Config;
    use crate::{
        Application, ApplicationError, BuiltinType, Command, CommandDisposition, CompletionSignal,
        Decision, HarnessId, RequestId, RoleLaunch, RunAgentStatus, RunStatus, TerminalId,
        TerminalSize, TraceSpanStatus, TranscriptError, TranscriptRead, Workflow, WorkflowId,
        WorkflowKind, WorkflowRun, WorkflowStatus, WorkflowTypeRef,
    };

    const PROCESS_TEST: &str = "application::recovery::tests::crash_recovery_process";
    const SIZE: TerminalSize = TerminalSize {
        rows: 24,
        columns: 80,
        pixel_width: 800,
        pixel_height: 480,
    };

    #[derive(Deserialize, Serialize)]
    struct Proof {
        active: u64,
        single: u64,
        hidden: u64,
        ended: Vec<(u64, WorkflowRun)>,
        ended_history: Vec<(u64, serde_json::Value)>,
        history: Vec<(u64, u64, Vec<u8>, serde_json::Value)>,
    }

    struct KillOnDrop(Child);
    impl Drop for KillOnDrop {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    fn command(app: &Application, command: Command) {
        assert_eq!(
            app.handle_command(RequestId(1), command)
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
    }

    fn workflow(app: &Application, id: WorkflowId) -> Workflow {
        app.snapshot()
            .unwrap()
            .workflows
            .workflows
            .into_iter()
            .find(|w| w.workflow_id == id)
            .unwrap()
    }

    fn draft(app: &Application, folder: &Path) -> WorkflowId {
        command(
            app,
            Command::CreateWorkflow {
                folder: folder.into(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
            },
        );
        app.snapshot()
            .unwrap()
            .workflows
            .workflows
            .last()
            .unwrap()
            .workflow_id
    }

    fn launch(app: &Application, folder: &Path) -> WorkflowId {
        let id = draft(app, folder);
        command(
            app,
            Command::StartWorkflowRun {
                workflow_id: id,
                workflow_type: WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
                prompt: "Crash fixture".into(),
                roles: ["implementer", "reviewer"]
                    .map(|role| RoleLaunch {
                        role: role.into(),
                        harness: HarnessId::Pi,
                    })
                    .into(),
                size: SIZE,
            },
        );
        id
    }

    fn complete(app: &Application, id: WorkflowId, decision: Decision) {
        let run = workflow(app, id).run.unwrap();
        command(
            app,
            Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: crate::AgentId(run.active_agents()[0].agent_id),
                generation: run.generation,
                signal: CompletionSignal {
                    task: String::new(),
                    decision,
                    summary: "Explicit completion".into(),
                    assignments: vec![],
                },
            },
        );
    }

    fn output(app: &Application, terminal: TerminalId) -> Vec<u8> {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let TranscriptRead::Output(page) =
                app.read_terminal_transcript(terminal, 0, 65536).unwrap()
            else {
                panic!("fixture transcript must remain available")
            };
            if page
                .bytes
                .windows(b"recovery-history".len())
                .any(|w| w == b"recovery-history")
            {
                return page.bytes;
            }
            assert!(
                Instant::now() < deadline,
                "fixture harness produced no output"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn history(app: &Application, id: WorkflowId) -> serde_json::Value {
        let page = app.workflow_trace(id, None, 200).unwrap();
        serde_json::json!({
            "lanes": page.lanes.iter().map(|l| serde_json::json!({"id": l.lane_id.0, "name": l.name, "role": l.role, "harness": l.harness})).collect::<Vec<_>>(),
            "spans": page.spans.iter().map(|s| serde_json::json!({"id": s.span_id.0, "lane": s.lane_id.0, "title": s.title, "start": s.started_at, "terminal": s.terminal_id.map(TerminalId::value),
                "events": app.trace_events(s.span_id, None, 200).unwrap().events.iter().map(|e| serde_json::json!({"id": e.event_id.0, "kind": format!("{:?}", e.kind), "time": e.timestamp, "message": e.message,
                    "anchor": e.anchor.as_ref().map(|a| serde_json::json!({"terminal": a.terminal_id.value(), "offset": a.byte_offset, "sizes": format!("{:?}", a.boundary_sizes)}))})).collect::<Vec<_>>()
            })).collect::<Vec<_>>()
        })
    }

    fn seed(data: &Path) {
        let folder = data.join("folder");
        let hidden_folder = data.join("hidden-folder");
        let bin = data.join("bin");
        for path in [&folder, &hidden_folder, &bin] {
            std::fs::create_dir_all(path).unwrap();
        }
        let harness = bin.join("pi");
        // exec keeps no shell descendants alive after the PTY's owning process is killed.
        std::fs::write(
            &harness,
            "#!/bin/sh\nprintf recovery-history\nexec /bin/sleep 300\n",
        )
        .unwrap();
        std::fs::set_permissions(harness, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut app = Application::with_config(data, Config::default()).unwrap();
        app.harness_path = Some(bin.into_os_string());
        command(
            &app,
            Command::OpenFolder {
                path: hidden_folder,
            },
        );
        let hidden = launch(&app, &data.join("hidden-folder"));
        command(
            &app,
            Command::OpenFolder {
                path: folder.clone(),
            },
        );
        let completed = launch(&app, &folder);
        complete(&app, completed, Decision::Done);
        complete(&app, completed, Decision::Approve);
        let cancelled = launch(&app, &folder);
        command(
            &app,
            Command::CancelWorkflowRun {
                workflow_id: cancelled,
            },
        );
        let active = launch(&app, &folder);
        let single = draft(&app, &folder);
        command(
            &app,
            Command::StartAgent {
                workflow_id: single,
                harness: HarnessId::Pi,
                prompt: "Crash fixture".into(),
                size: SIZE,
            },
        );
        let mut proof = Proof {
            active: active.0,
            single: single.0,
            hidden: hidden.0,
            ended: [completed, cancelled]
                .into_iter()
                .map(|id| (id.0, *workflow(&app, id).run.unwrap()))
                .collect(),
            ended_history: [completed, cancelled]
                .into_iter()
                .map(|id| (id.0, history(&app, id)))
                .collect(),
            history: Vec::new(),
        };
        for id in [active, single] {
            let state = workflow(&app, id);
            let terminal = if id == single {
                state.terminal_id
            } else {
                state.agents[0].terminal_id
            };
            proof.history.push((
                id.0,
                terminal.value(),
                output(&app, terminal),
                history(&app, id),
            ));
        }
        std::fs::write(data.join("ready.json"), serde_json::to_vec(&proof).unwrap()).unwrap();
        loop {
            thread::park();
        }
    }

    fn verify(data: &Path) {
        let proof: Proof =
            serde_json::from_slice(&std::fs::read(data.join("ready.json")).unwrap()).unwrap();
        let app = Application::with_config(data, Config::default()).unwrap();
        // The first published snapshot must already contain recovered lifecycle state.
        assert_eq!(
            workflow(&app, WorkflowId(proof.single)).status,
            WorkflowStatus::Interrupted
        );
        let active = workflow(&app, WorkflowId(proof.active));
        assert_eq!(active.status, WorkflowStatus::Interrupted);
        assert!(active.agents.iter().all(|a| a.terminal_id.value() == 0));
        let run = active.run.unwrap();
        assert_eq!(run.status, RunStatus::Interrupted);
        assert_eq!(run.agents[0].status, RunAgentStatus::Interrupted);
        assert_eq!(run.agents[1].status, RunAgentStatus::Waiting);
        for (id, previous) in &proof.ended {
            assert_eq!(
                workflow(&app, WorkflowId(*id)).run.as_deref(),
                Some(previous)
            );
        }
        for (id, previous) in &proof.ended_history {
            assert_eq!(&history(&app, WorkflowId(*id)), previous);
        }
        for (id, terminal, bytes, previous) in &proof.history {
            let TranscriptRead::Output(page) = app
                .read_terminal_transcript(TerminalId::from_value(*terminal), 0, 65536)
                .unwrap()
            else {
                panic!("crash lost the terminal transcript")
            };
            assert_eq!(&page.bytes, bytes);
            let recovered = history(&app, WorkflowId(*id));
            assert_eq!(recovered["lanes"], previous["lanes"]);
            let spans = recovered["spans"].as_array().unwrap();
            for old in previous["spans"].as_array().unwrap() {
                let new = spans.iter().find(|s| s["id"] == old["id"]).unwrap();
                for key in ["lane", "title", "start", "terminal"] {
                    assert_eq!(new[key], old[key]);
                }
                let events = new["events"].as_array().unwrap();
                for event in old["events"].as_array().unwrap() {
                    assert!(events.contains(event));
                }
            }
            assert!(
                app.workflow_trace(WorkflowId(*id), None, 200)
                    .unwrap()
                    .spans
                    .iter()
                    .all(|s| s.status != TraceSpanStatus::Running
                        && !s.is_live
                        && s.ended_at.is_some())
            );
        }
        // Recovery also persisted the hidden folder's run before it was opened again.
        let mut inner = app.lock_inner().unwrap();
        let hidden = inner
            .folders
            .store()
            .workflows(&data.join("hidden-folder"))
            .unwrap();
        assert_eq!(
            hidden
                .iter()
                .find(|w| w.workflow_id.0 == proof.hidden)
                .unwrap()
                .run
                .as_ref()
                .unwrap()
                .status,
            RunStatus::Interrupted
        );
        drop(inner);
        let revisions = app.snapshot().unwrap().traces;
        drop(app);
        let reopened = Application::with_config(data, Config::default()).unwrap();
        assert_eq!(
            reopened.snapshot().unwrap().traces,
            revisions,
            "recovery must be idempotent"
        );
    }

    /// Invoked in separate processes by the parent test; never kills the test runner itself.
    #[test]
    fn crash_recovery_process() {
        let Some(data) = std::env::var_os("TWINE_CRASH_TEST_DATA") else {
            return;
        };
        let data = Path::new(&data);
        match std::env::var("TWINE_CRASH_TEST_MODE").unwrap().as_str() {
            "seed" => seed(data),
            "verify" => verify(data),
            "contend" => {
                assert!(matches!(
                    Application::with_config(data, Config::default()),
                    Err(ApplicationError::Transcript(TranscriptError::AlreadyOpen))
                ));
                let store = crate::store::Store::open(&data.join("twine.db")).unwrap();
                let runs = store.workflows(&data.join("folder")).unwrap();
                let proof: Proof =
                    serde_json::from_slice(&std::fs::read(data.join("ready.json")).unwrap())
                        .unwrap();
                assert_eq!(
                    runs.iter()
                        .find(|w| w.workflow_id.0 == proof.active)
                        .unwrap()
                        .run
                        .as_ref()
                        .unwrap()
                        .status,
                    RunStatus::Running
                );
                assert_eq!(
                    runs.iter()
                        .find(|w| w.workflow_id.0 == proof.single)
                        .unwrap()
                        .agent_status,
                    Some(WorkflowStatus::Running)
                );
            }
            _ => panic!("unknown subprocess mode"),
        }
    }

    fn spawn(data: &Path, mode: &str) -> KillOnDrop {
        KillOnDrop(
            ProcessCommand::new(std::env::current_exe().unwrap())
                .args(["--exact", PROCESS_TEST, "--nocapture"])
                .env("TWINE_CRASH_TEST_DATA", data)
                .env("TWINE_CRASH_TEST_MODE", mode)
                .spawn()
                .unwrap(),
        )
    }

    fn wait_success(child: &mut Child) {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success(), "subprocess failed: {status}");
                return;
            }
            assert!(Instant::now() < deadline, "recovery subprocess timed out");
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn force_kill_and_relaunch_recovers_work_without_losing_history_or_touching_live_owners() {
        let data = tempfile::tempdir().unwrap();
        let mut owner = spawn(data.path(), "seed");
        let deadline = Instant::now() + Duration::from_secs(30);
        while !data.path().join("ready.json").exists() {
            assert!(
                owner.0.try_wait().unwrap().is_none(),
                "fixture owner exited before readiness"
            );
            assert!(Instant::now() < deadline, "fixture owner timed out");
            thread::sleep(Duration::from_millis(10));
        }
        let mut contender = spawn(data.path(), "contend");
        wait_success(&mut contender.0);
        owner.0.kill().unwrap();
        assert_eq!(owner.0.wait().unwrap().signal(), Some(libc::SIGKILL));
        let mut relaunched = spawn(data.path(), "verify");
        wait_success(&mut relaunched.0);
    }
}
