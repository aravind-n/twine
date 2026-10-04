//! Owns model-discovery workers and their bounded helper processes.

use std::ffi::OsString;
use std::io::{Read, Seek};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use tracing::warn;

use super::{HarnessModels, ModelListError, help_levels};
use crate::harness::{HarnessError, HarnessId, LocatedHarness};
use crate::process::CommandChild;

const LIST_TIMEOUT: Duration = Duration::from_secs(20);
const OPENCODE_CATALOG_GRACE: Duration = Duration::from_secs(2);
/// Codex's catalog carries each model's instructions, so it runs to hundreds of KiB.
const MAX_LIST_OUTPUT: u64 = 4 * 1024 * 1024;

impl HarnessId {
    /// The arguments that make the harness print its models.
    fn model_list_arguments(self) -> &'static [&'static str] {
        match self {
            Self::Codex => &["debug", "models"],
            Self::ClaudeCode => &["--help"],
            Self::Pi => &["--list-models"],
            Self::Antigravity => &["models"],
            Self::Omp => &["models", "--json"],
            Self::Opencode => &["api", "model.list"],
        }
    }
}

/// Discovery workers owned by one application runtime, even when requests outlive that runtime.
#[derive(Default)]
pub(crate) struct ModelListWorkers {
    workers: Mutex<Vec<Weak<ModelListWorker>>>,
}

impl ModelListWorkers {
    pub(crate) fn request(
        &self,
        harness: HarnessId,
        folder: Option<std::path::PathBuf>,
        locate: impl FnOnce() -> Result<LocatedHarness, HarnessError> + Send + 'static,
    ) -> ModelListRequest {
        let request = ModelListRequest::spawn(harness, folder, locate);
        let mut workers = self.workers.lock().unwrap_or_else(PoisonError::into_inner);
        workers.retain(|worker| worker.strong_count() > 0);
        workers.push(Arc::downgrade(&request.worker));
        request
    }

    pub(crate) fn shutdown(&self) {
        let workers =
            std::mem::take(&mut *self.workers.lock().unwrap_or_else(PoisonError::into_inner))
                .into_iter()
                .filter_map(|worker| worker.upgrade())
                .collect::<Vec<_>>();
        // Cancel every listing before joining any, so independent helpers stop together.
        for worker in &workers {
            worker.cancelled.store(true, Ordering::Relaxed);
        }
        for worker in workers {
            worker.join();
        }
    }
}

struct ModelListWorker {
    cancelled: Arc<AtomicBool>,
    thread: Mutex<Option<thread::JoinHandle<()>>>,
}

impl ModelListWorker {
    fn join(&self) {
        // Keep the lock until the join finishes: a concurrent shutdown must also wait for cleanup.
        let mut thread = self.thread.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(thread) = thread.take()
            && thread.join().is_err()
        {
            warn!("model discovery worker panicked");
        }
    }
}

/// A model list running on its own thread, so a slow harness never holds up the caller. Dropping
/// it stops the harness and waits for its worker to clean up.
pub struct ModelListRequest {
    receiver: mpsc::Receiver<Result<HarnessModels, ModelListError>>,
    worker: Arc<ModelListWorker>,
}

impl ModelListRequest {
    /// Finds the harness with `locate`, then lists its models, all on a new thread.
    pub(crate) fn spawn(
        harness: HarnessId,
        folder: Option<std::path::PathBuf>,
        locate: impl FnOnce() -> Result<LocatedHarness, HarnessError> + Send + 'static,
    ) -> Self {
        let (sender, receiver) = mpsc::sync_channel(1);
        let cancelled = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&cancelled);
        let spawned = crate::blocking_worker::spawn("harness-models".into(), move || {
            let located = locate();
            let result = if flag.load(Ordering::Relaxed) {
                Err(ModelListError::Cancelled)
            } else {
                located.map_err(ModelListError::from).and_then(|located| {
                    list_models(
                        harness,
                        &located.program,
                        &located.path,
                        folder.as_deref(),
                        &flag,
                    )
                })
            };
            let _ = sender.send(result);
        });
        let thread = spawned
            .map_err(|error| warn!(%error, "couldn't start listing harness models"))
            .ok();
        Self {
            receiver,
            worker: Arc::new(ModelListWorker {
                cancelled,
                thread: Mutex::new(thread),
            }),
        }
    }

    /// The models once the harness has answered, without waiting for it.
    #[must_use]
    pub fn poll(&self) -> Option<Result<HarnessModels, ModelListError>> {
        match self.receiver.try_recv() {
            Ok(result) => Some(result),
            Err(mpsc::TryRecvError::Empty) => None,
            Err(mpsc::TryRecvError::Disconnected) => Some(Err(ModelListError::Cancelled)),
        }
    }
}

impl Drop for ModelListRequest {
    fn drop(&mut self) {
        self.worker.cancelled.store(true, Ordering::Relaxed);
        self.worker.join();
    }
}

/// Runs `program` to list the harness's models, with `path` as its `PATH`.
fn list_models(
    harness: HarnessId,
    program: &Path,
    path: &OsString,
    folder: Option<&Path>,
    cancelled: &AtomicBool,
) -> Result<HarnessModels, ModelListError> {
    let name = harness.definition().name;
    let directory = if harness == HarnessId::Opencode {
        folder
    } else {
        None
    };
    let run = |arguments| {
        run(
            program,
            arguments,
            path,
            directory,
            name,
            LIST_TIMEOUT,
            cancelled,
        )
    };
    // The shared server uses its own default location unless the nested query is explicit.
    let location =
        directory.map(|directory| format!("location[directory]={}", directory.display()));
    let mut arguments = harness.model_list_arguments().to_vec();
    if let Some(location) = &location {
        arguments.extend(["--param", location.as_str()]);
    }
    let mut models = harness.parse_models(&run(&arguments)?)?;
    // A new v2 location can return its snapshot before provider plugins settle.
    let deadline = Instant::now() + OPENCODE_CATALOG_GRACE;
    while harness == HarnessId::Opencode && models.models.is_empty() && Instant::now() < deadline {
        if cancelled.load(Ordering::Relaxed) {
            return Err(ModelListError::Cancelled);
        }
        thread::sleep(Duration::from_millis(100));
        models = harness.parse_models(&run(&arguments)?)?;
    }
    // These catalogs omit default-model effort levels, which their help lists instead.
    let effort_option = match harness {
        HarnessId::Pi => Some("--thinking <level>"),
        HarnessId::Antigravity => Some("--effort"),
        HarnessId::Omp => Some("--thinking=<value>"),
        HarnessId::Codex | HarnessId::ClaudeCode | HarnessId::Opencode => None,
    };
    if let Some(option) = effort_option {
        models.efforts = help_levels(&run(&["--help"])?, option);
    }
    Ok(models)
}

/// Runs `program` with `arguments` and returns what it printed, within a time and size limit. A
/// harness that exits unsuccessfully has failed, whatever it printed.
fn run(
    program: &Path,
    arguments: &[&str],
    path: &OsString,
    directory: Option<&Path>,
    name: &'static str,
    timeout: Duration,
    cancelled: &AtomicBool,
) -> Result<String, ModelListError> {
    if cancelled.load(Ordering::Relaxed) {
        return Err(ModelListError::Cancelled);
    }
    let failed = |error: std::io::Error| {
        warn!(harness = name, %error, "couldn't run a harness to list its models");
        ModelListError::Failed(name)
    };
    // A file avoids blocking on a full pipe while the harness is supervised.
    let mut output = tempfile::tempfile().map_err(failed)?;
    let stdout = output.try_clone().map_err(failed)?;
    let mut command = Command::new(program);
    if let Some(directory) = directory {
        command.current_dir(directory);
    }
    command
        .args(arguments)
        .env("PATH", path)
        .env("NO_COLOR", "1")
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(Stdio::null());
    let mut child = CommandChild::spawn(&mut command).map_err(|error| {
        warn!(harness = name, %error, "couldn't start a harness to list its models");
        ModelListError::Start(name)
    })?;
    let deadline = Instant::now() + timeout;
    let status = loop {
        if cancelled.load(Ordering::Relaxed) {
            return Err(ModelListError::Cancelled);
        }
        if output.metadata().map_err(failed)?.len() > MAX_LIST_OUTPUT {
            warn!(
                harness = name,
                "a harness printed too much while listing its models"
            );
            return Err(ModelListError::Unreadable(name));
        }
        if child.has_exited().map_err(failed)? {
            break child.finish().map_err(failed)?;
        }
        if Instant::now() >= deadline {
            warn!(harness = name, "a harness took too long to list its models");
            return Err(ModelListError::Timeout(name));
        }
        thread::sleep(Duration::from_millis(10));
    };
    if !status.success() {
        warn!(harness = name, %status, "a harness failed to list its models");
        return Err(ModelListError::Failed(name));
    }
    output.rewind().map_err(failed)?;
    let mut text = String::new();
    output
        .take(MAX_LIST_OUTPUT)
        .read_to_string(&mut text)
        .map_err(|_| ModelListError::Unreadable(name))?;
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::process::tests::FixtureProcess;

    #[test]
    fn concurrent_request_destruction_and_shutdown_both_wait_for_cleanup() {
        let workers = Arc::new(ModelListWorkers::default());
        let (started, ready) = mpsc::channel();
        let (release, gate) = mpsc::channel();
        let request = workers.request(HarnessId::Pi, None, move || {
            started.send(()).unwrap();
            gate.recv().unwrap();
            Err(HarnessError::NotFound {
                name: "fixture",
                binary: "fixture",
            })
        });
        ready.recv_timeout(Duration::from_secs(3)).unwrap();
        let cancellation = Arc::clone(&request.worker.cancelled);
        let (dropped, drop_done) = mpsc::channel();
        let dropping = thread::spawn(move || {
            drop(request);
            dropped.send(()).unwrap();
        });
        let deadline = Instant::now() + Duration::from_secs(3);
        while !cancellation.load(Ordering::Relaxed) {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(5));
        }
        let registry = Arc::clone(&workers);
        let (stopped, shutdown_done) = mpsc::channel();
        let stopping = thread::spawn(move || {
            registry.shutdown();
            stopped.send(()).unwrap();
        });
        // Wait until shutdown has taken ownership of its registrations before checking it blocks.
        while !workers.workers.lock().unwrap().is_empty() {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(5));
        }
        assert!(matches!(
            drop_done.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        assert!(matches!(
            shutdown_done.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        release.send(()).unwrap();
        dropping.join().unwrap();
        stopping.join().unwrap();
        drop_done.recv().unwrap();
        shutdown_done.recv().unwrap();
    }

    #[test]
    fn omp_discovers_models_and_thinking_levels_from_its_cli() {
        let directory = tempfile::tempdir().unwrap();
        let program = stub(
            directory.path(),
            "omp",
            "case \"$1 $2\" in\n'models --json') printf '%s\\n' '{\"models\":[{\"selector\":\"local/model\",\"provider\":\"local\",\"name\":\"Model\",\"thinking\":[\"high\"]}]}' ;;\n\
             '--help ') printf '      --thinking=<value>  Set thinking level: off, minimal, low, medium, high, xhigh, max, auto\\n      --service-tier=<value>  Service tier\\n' ;;\n\
             *) exit 1 ;;\nesac",
        );
        let models = list_models(
            HarnessId::Omp,
            &program,
            &OsString::from("/bin:/usr/bin"),
            None,
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(models.models[0].id, "local/model");
        assert_eq!(
            models.efforts,
            [
                "off", "minimal", "low", "medium", "high", "xhigh", "max", "auto"
            ]
        );
    }

    #[test]
    fn opencode_discovers_model_variants_through_its_cli_api() {
        let directory = tempfile::tempdir().unwrap();
        let program = stub(
            directory.path(),
            "opencode",
            r#"
            [ "$#" -eq 2 ] && [ "$1 $2" = 'api model.list' ] || exit 1
            printf '%s\n' '{"data":[{"providerID":"local","id":"model","name":"Model","variants":[{"id":"high"}]}]}'
        "#,
        );
        let models = list_models(
            HarnessId::Opencode,
            &program,
            &OsString::from("/bin:/usr/bin"),
            None,
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(models.models[0].id, "local/model");
        assert_eq!(models.models[0].efforts, Some(vec!["high".into()]));
        assert!(models.efforts.is_empty() && !models.supports_yolo);
    }

    #[test]
    fn opencode_discovers_each_folders_catalog_after_provider_startup() {
        let directory = tempfile::tempdir().unwrap();
        let program = stub(
            directory.path(),
            "opencode",
            r#"
            [ "$1 $2 $3" = 'api model.list --param' ] || exit 1
            catalog_location=${4#*=}
            [ "${4%%=*}" = 'location[directory]' ] && [ "$catalog_location" -ef "$PWD" ] || exit 1
            if [ ! -f ready ]; then
                touch ready
                printf '%s\n' '{"data":[]}'
            else
                cat catalog.json
            fi
        "#,
        );
        for (folder, variant) in [("first", "custom-name"), ("second", "Custom_Name")] {
            let path = directory.path().join(folder);
            std::fs::create_dir(&path).unwrap();
            std::fs::write(path.join("catalog.json"), serde_json::to_vec(&serde_json::json!({
                "data": [{"providerID": "local", "id": folder, "name": folder, "variants": [{"id": variant}]}]
            })).unwrap()).unwrap();
            let models = list_models(
                HarnessId::Opencode,
                &program,
                &OsString::from("/bin:/usr/bin"),
                Some(&path),
                &AtomicBool::new(false),
            )
            .unwrap();
            assert_eq!(models.models[0].id, format!("local/{folder}"));
            assert_eq!(models.models[0].efforts, Some(vec![variant.into()]));
        }
    }

    #[test]
    fn antigravity_reads_models_and_effort_levels_from_its_cli() {
        let directory = tempfile::tempdir().unwrap();
        let program = stub(
            directory.path(),
            "agy",
            "case \"$1\" in\nmodels) printf 'gemini-3.8-flash-high\\tGemini 3.8 Flash (High)\\n' ;;\n\
             --help) printf '  --effort  Reasoning effort for the current CLI session (low|medium|high)\\n  --model  Model\\n' ;;\n\
             *) exit 1 ;;\nesac",
        );
        let models = list_models(
            HarnessId::Antigravity,
            &program,
            &OsString::from("/bin:/usr/bin"),
            None,
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(models.models[0].id, "gemini-3.8-flash-high");
        assert_eq!(models.efforts, ["low", "medium", "high"]);
        assert!(models.supports_yolo);
    }

    fn stub(directory: &Path, name: &str, script: &str) -> std::path::PathBuf {
        let program = directory.join(name);
        std::fs::write(&program, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(
            &program,
            std::os::unix::fs::PermissionsExt::from_mode(0o755),
        )
        .unwrap();
        program
    }

    fn is_running(pid: &str) -> bool {
        Command::new("/bin/kill")
            .args(["-0", pid])
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success()
    }

    #[test]
    fn listing_runs_the_harness_and_reports_a_harness_that_fails_to_answer() {
        let directory = tempfile::tempdir().unwrap();
        let program = stub(
            directory.path(),
            "pi",
            "case \"$1\" in\n--list-models) printf 'provider model\\nlocal m1 x\\n' ;;\n\
             --help) printf '  --thinking <level>  Set thinking level: off, low, high\\n  -e x\\n' ;;\n\
             *) exit 1 ;;\nesac",
        );
        let path = OsString::from("/bin:/usr/bin");
        let running = AtomicBool::new(false);
        let models = list_models(HarnessId::Pi, &program, &path, None, &running).unwrap();
        assert_eq!(models.models[0].id, "local/m1");
        assert_eq!(models.efforts, ["off", "low", "high"]);
        assert!(list_models(HarnessId::Codex, &program, &path, None, &running).is_err());
        assert!(
            list_models(
                HarnessId::Pi,
                &directory.path().join("missing"),
                &path,
                None,
                &running
            )
            .is_err()
        );
        // An empty list from a harness that failed is a failure, not "no models".
        let broken = stub(directory.path(), "claude", "exit 1");
        assert!(matches!(
            list_models(HarnessId::ClaudeCode, &broken, &path, None, &running),
            Err(ModelListError::Failed("Claude Code"))
        ));
    }

    #[test]
    fn a_slow_or_flooding_harness_is_stopped() {
        let directory = tempfile::tempdir().unwrap();
        let path = OsString::from("/bin:/usr/bin");
        let running = AtomicBool::new(false);
        let pid_file = directory.path().join("pid");
        let slow = stub(
            directory.path(),
            "slow",
            &format!("echo $$ > '{}'; exec sleep 60", pid_file.display()),
        );
        let started = Instant::now();
        assert!(matches!(
            run(
                &slow,
                &[],
                &path,
                None,
                "pi",
                Duration::from_millis(300),
                &running
            ),
            Err(ModelListError::Timeout("pi"))
        ));
        assert!(started.elapsed() < Duration::from_secs(5));
        let pid = std::fs::read_to_string(&pid_file).unwrap();
        assert!(!is_running(pid.trim()), "the timed-out harness was killed");
        let child_file = directory.path().join("child");
        let wrapper = stub(
            directory.path(),
            "wrapper",
            &format!("sleep 60 & echo $! > '{}'; wait", child_file.display()),
        );
        assert!(
            run(
                &wrapper,
                &[],
                &path,
                None,
                "pi",
                Duration::from_millis(300),
                &running
            )
            .is_err()
        );
        let child = std::fs::read_to_string(&child_file).unwrap();
        // A killed process can linger briefly until it's reaped.
        let deadline = Instant::now() + Duration::from_secs(5);
        while is_running(child.trim()) {
            assert!(
                Instant::now() < deadline,
                "what the harness started was left running"
            );
            thread::sleep(Duration::from_millis(10));
        }
        let flood = stub(directory.path(), "flood", "exec yes model");
        assert!(matches!(
            run(&flood, &[], &path, None, "pi", LIST_TIMEOUT, &running),
            Err(ModelListError::Unreadable("pi"))
        ));
    }

    #[test]
    fn completed_helpers_leave_no_background_children() {
        let directory = tempfile::tempdir().unwrap();
        let pid_path = directory.path().join("child.pid");
        for exit_code in [0, 7] {
            let program = stub(
                directory.path(),
                "helper",
                &format!(
                    "sleep 60 & echo $! > '{}'; printf 'catalog'; exit {exit_code}",
                    pid_path.display()
                ),
            );
            let result = run(
                &program,
                &[],
                &OsString::from("/bin:/usr/bin"),
                None,
                "fixture",
                LIST_TIMEOUT,
                &AtomicBool::new(false),
            );
            let child = FixtureProcess::read(&pid_path);
            if exit_code == 0 {
                assert_eq!(result.unwrap(), "catalog");
            } else {
                assert!(matches!(result, Err(ModelListError::Failed("fixture"))));
            }
            child.assert_stopped();
        }
    }

    #[test]
    fn dropping_a_request_stops_its_harness() {
        let directory = tempfile::tempdir().unwrap();
        let pid_file = directory.path().join("pid");
        let slow = stub(
            directory.path(),
            "pi",
            &format!("echo $$ > '{}'; exec sleep 60", pid_file.display()),
        );
        let request = ModelListRequest::spawn(HarnessId::Pi, None, move || {
            Ok(LocatedHarness {
                program: slow,
                path: OsString::from("/bin:/usr/bin"),
            })
        });
        let deadline = Instant::now() + Duration::from_secs(10);
        while std::fs::read_to_string(&pid_file).map_or(true, |pid| pid.trim().is_empty()) {
            assert!(Instant::now() < deadline, "the harness never started");
            thread::sleep(Duration::from_millis(10));
        }
        assert!(request.poll().is_none(), "still listing");
        drop(request);
        let pid = std::fs::read_to_string(&pid_file).unwrap();
        assert!(
            !is_running(pid.trim()),
            "request destruction waits for the harness to stop"
        );
    }
}
