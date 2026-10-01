//! The models a harness offers, read from the harness's own CLI.

use std::ffi::OsString;
use std::io::{Read, Seek};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use thiserror::Error;
use tracing::warn;

use super::launch::{validate_effort, validate_model, validate_variant};
use super::{HarnessError, HarnessId, LocatedHarness};

const LIST_TIMEOUT: Duration = Duration::from_secs(20);
const OPENCODE_CATALOG_GRACE: Duration = Duration::from_secs(2);
/// Codex's catalog carries each model's instructions, so it runs to hundreds of KiB.
const MAX_LIST_OUTPUT: u64 = 4 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HarnessModel {
    /// What the harness's `--model` flag takes.
    pub id: String,
    pub name: String,
    /// A heading for long lists, such as pi's provider.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    /// The effort levels this model supports, when they differ by model, as Codex's do.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub efforts: Option<Vec<String>>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HarnessModels {
    pub models: Vec<HarnessModel>,
    /// Whether the harness also takes model names it doesn't list.
    pub allows_custom: bool,
    /// The effort levels the harness takes, weakest first. A model's own levels take precedence.
    pub efforts: Vec<String>,
    /// Whether the harness has a flag that skips its permission prompts.
    pub supports_yolo: bool,
}

#[derive(Debug, Error)]
pub enum ModelListError {
    #[error(transparent)]
    NotFound(#[from] HarnessError),
    #[error("{0} couldn't list its models.")]
    Failed(&'static str),
    #[error("Listing models stopped before it finished.")]
    Cancelled,
    #[error("{0} couldn't be started to list its models.")]
    Start(&'static str),
    #[error("{0} took too long to list its models.")]
    Timeout(&'static str),
    #[error("{0} listed its models in a form Twine doesn't recognize.")]
    Unreadable(&'static str),
}

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

    pub(crate) fn parse_models(self, output: &str) -> Result<HarnessModels, ModelListError> {
        let name = self.definition().name;
        match self {
            Self::Codex => {
                let models = parse_codex(output).ok_or(ModelListError::Unreadable(name))?;
                // The default model's levels aren't listed, so offer every level some model takes.
                let mut efforts: Vec<String> = Vec::new();
                for effort in models
                    .iter()
                    .flat_map(|model| model.efforts.iter().flatten())
                {
                    if !efforts.contains(effort) {
                        efforts.push(effort.clone());
                    }
                }
                Ok(HarnessModels {
                    models,
                    allows_custom: false,
                    efforts,
                    supports_yolo: true,
                })
            }
            // pi's list only covers models; its help names the thinking levels.
            // pi runs tools without asking, so it has no permission prompts to skip.
            Self::Pi => Ok(HarnessModels {
                models: parse_pi(output),
                allows_custom: false,
                efforts: Vec::new(),
                supports_yolo: false,
            }),
            // Claude Code names only its aliases, and takes any full model name besides.
            Self::ClaudeCode => Ok(HarnessModels {
                models: parse_claude_help(output),
                allows_custom: true,
                efforts: help_levels(output, "--effort <level>"),
                supports_yolo: true,
            }),
            Self::Antigravity => Ok(HarnessModels {
                models: parse_antigravity(output).ok_or(ModelListError::Unreadable(name))?,
                allows_custom: false,
                efforts: Vec::new(),
                supports_yolo: true,
            }),
            Self::Omp => Ok(HarnessModels {
                models: parse_omp(output).ok_or(ModelListError::Unreadable(name))?,
                allows_custom: true,
                efforts: Vec::new(),
                supports_yolo: true,
            }),
            Self::Opencode => Ok(HarnessModels {
                models: parse_opencode(output).ok_or(ModelListError::Unreadable(name))?,
                allows_custom: true,
                // Variants require an explicit model, so the default offers no effort choices.
                efforts: Vec::new(),
                // OpenCode v2's interactive mini command doesn't accept --auto.
                supports_yolo: false,
            }),
        }
    }
}

/// `OpenCode` v2's CLI API returns the current catalog and each model's named variants.
fn parse_opencode(output: &str) -> Option<Vec<HarnessModel>> {
    #[derive(Deserialize)]
    struct Catalog {
        data: Vec<Entry>,
    }
    #[derive(Deserialize)]
    struct Entry {
        #[serde(rename = "providerID")]
        provider: String,
        id: String,
        name: String,
        #[serde(default)]
        variants: Vec<Variant>,
    }
    #[derive(Deserialize)]
    struct Variant {
        id: String,
    }
    serde_json::from_str::<Catalog>(output)
        .ok()?
        .data
        .into_iter()
        .map(|entry| {
            if entry.provider.is_empty() || entry.id.is_empty() {
                return None;
            }
            let selector = format!("{}/{}", entry.provider, entry.id);
            Some(HarnessModel {
                id: validate_model(&selector)?.to_owned(),
                name: entry.name,
                group: Some(entry.provider),
                efforts: Some(
                    entry
                        .variants
                        .into_iter()
                        .filter_map(|variant| validate_variant(&variant.id).map(str::to_owned))
                        .collect(),
                ),
            })
        })
        .collect()
}

/// OMP's JSON catalog provides exact selectors and each model's supported thinking levels.
fn parse_omp(output: &str) -> Option<Vec<HarnessModel>> {
    #[derive(Deserialize)]
    struct Catalog {
        models: Vec<Entry>,
    }
    #[derive(Deserialize)]
    struct Entry {
        selector: String,
        provider: String,
        name: String,
        #[serde(default)]
        thinking: Option<Vec<String>>,
    }
    serde_json::from_str::<Catalog>(output)
        .ok()?
        .models
        .into_iter()
        .map(|entry| {
            Some(HarnessModel {
                id: validate_model(&entry.selector)?.to_owned(),
                name: entry.name,
                group: Some(entry.provider),
                // A null list means the model doesn't reason; don't inherit global levels.
                efforts: Some(
                    entry
                        .thinking
                        .unwrap_or_default()
                        .into_iter()
                        .filter(|level| validate_effort(level).is_some())
                        .collect(),
                ),
            })
        })
        .collect()
}

/// Antigravity's tab-separated model IDs and display names, in its picker order.
fn parse_antigravity(output: &str) -> Option<Vec<HarnessModel>> {
    let models: Vec<HarnessModel> = output
        .lines()
        .filter_map(|line| line.split_once('\t'))
        .map(|(id, name)| {
            let name = name.trim();
            if name.is_empty() {
                return None;
            }
            Some(HarnessModel {
                id: validate_model(id)?.to_owned(),
                name: name.to_owned(),
                group: None,
                efforts: None,
            })
        })
        .collect::<Option<_>>()?;
    (!models.is_empty()).then_some(models)
}

/// Codex's catalog, as its model picker shows it: listed models in priority order.
fn parse_codex(output: &str) -> Option<Vec<HarnessModel>> {
    #[derive(Deserialize)]
    struct Catalog {
        models: Vec<Entry>,
    }
    #[derive(Deserialize)]
    struct Entry {
        slug: String,
        display_name: Option<String>,
        visibility: Option<String>,
        #[serde(default)]
        priority: i64,
        #[serde(default)]
        supported_reasoning_levels: Vec<Level>,
    }
    #[derive(Deserialize)]
    struct Level {
        effort: String,
    }
    let mut entries: Vec<Entry> = serde_json::from_str::<Catalog>(output)
        .ok()?
        .models
        .into_iter()
        .filter(|entry| entry.visibility.as_deref() == Some("list"))
        .collect();
    entries.sort_by_key(|entry| entry.priority);
    Some(
        entries
            .into_iter()
            .map(|entry| HarnessModel {
                name: entry.display_name.unwrap_or_else(|| entry.slug.clone()),
                id: entry.slug,
                group: None,
                efforts: Some(
                    entry
                        .supported_reasoning_levels
                        .into_iter()
                        .map(|level| level.effort)
                        .filter(|effort| validate_effort(effort).is_some())
                        .collect(),
                ),
            })
            .collect(),
    )
}

/// pi's table of `provider  model  …` rows, one model per signed-in provider's entry.
fn parse_pi(output: &str) -> Vec<HarnessModel> {
    output
        .lines()
        .skip_while(|line| !line.trim_start().starts_with("provider"))
        .skip(1)
        .filter_map(|line| {
            let mut columns = line.split_whitespace();
            let (provider, model) = (columns.next()?, columns.next()?);
            Some(HarnessModel {
                id: format!("{provider}/{model}"),
                name: model.to_owned(),
                group: Some(provider.to_owned()),
                efforts: None,
            })
        })
        .collect()
}

/// The quoted aliases in the description of Claude Code's `--model` option.
fn parse_claude_help(output: &str) -> Vec<HarnessModel> {
    let mut lines = output
        .lines()
        .skip_while(|line| !line.trim_start().starts_with("--model "));
    let Some(first) = lines.next() else {
        return Vec::new();
    };
    // The description continues on indented lines until the next option.
    let description: String = std::iter::once(first)
        .chain(lines.take_while(|line| !line.trim_start().starts_with('-')))
        .collect::<Vec<_>>()
        .join(" ");
    description
        .split('\'')
        .skip(1)
        .step_by(2)
        .filter(|alias| {
            !alias.is_empty() && alias.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        })
        .map(|alias| {
            let mut name = alias.to_owned();
            if let Some(first) = name.get_mut(0..1) {
                first.make_ascii_uppercase();
            }
            HarnessModel {
                id: alias.to_owned(),
                name,
                group: None,
                efforts: None,
            }
        })
        .collect()
}

/// The levels an option's help lists, as in `--effort <level>  … (low, medium, high)` or
/// `--thinking <level>  Set thinking level: off, low, high`.
fn help_levels(help: &str, option: &str) -> Vec<String> {
    let mut lines = help
        .lines()
        .skip_while(|line| !line.trim_start().starts_with(option));
    let Some(first) = lines.next() else {
        return Vec::new();
    };
    let description: String =
        std::iter::once(&first[first.find(option).unwrap_or(0) + option.len()..])
            .chain(lines.take_while(|line| !line.trim_start().starts_with('-')))
            .collect::<Vec<_>>()
            .join(" ");
    let list = match (description.find('('), description.find(':')) {
        (Some(open), _) => description[open + 1..]
            .split(')')
            .next()
            .unwrap_or_default(),
        (None, Some(colon)) => &description[colon + 1..],
        (None, None) => return Vec::new(),
    };
    list.split([',', '|'])
        .filter_map(|level| validate_effort(level).map(str::to_owned))
        .collect()
}

/// A model list running on its own thread, so a slow harness never holds up the caller. Dropping
/// it stops the harness.
pub struct ModelListRequest {
    receiver: mpsc::Receiver<Result<HarnessModels, ModelListError>>,
    cancelled: Arc<AtomicBool>,
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
        let spawned = thread::Builder::new()
            .name("harness-models".into())
            .spawn(move || {
                let result = locate().map_err(ModelListError::from).and_then(|located| {
                    list_models(
                        harness,
                        &located.program,
                        &located.path,
                        folder.as_deref(),
                        &flag,
                    )
                });
                let _ = sender.send(result);
            });
        if let Err(error) = spawned {
            warn!(%error, "couldn't start listing harness models");
        }
        Self {
            receiver,
            cancelled,
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
        self.cancelled.store(true, Ordering::Relaxed);
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
    let failed = |error: std::io::Error| {
        warn!(harness = name, %error, "couldn't run a harness to list its models");
        ModelListError::Failed(name)
    };
    // A file avoids blocking on a full pipe while the harness is supervised.
    let mut output = tempfile::tempfile().map_err(failed)?;
    let stdout = output.try_clone().map_err(failed)?;
    // Its own process group, so stopping it also stops anything it started, like a wrapper's binary.
    let mut command = Command::new(program);
    if let Some(directory) = directory {
        command.current_dir(directory);
    }
    let child = std::os::unix::process::CommandExt::process_group(&mut command, 0)
        .args(arguments)
        .env("PATH", path)
        .env("NO_COLOR", "1")
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| {
            warn!(harness = name, %error, "couldn't start a harness to list its models");
            ModelListError::Start(name)
        })?;
    let mut child = KilledOnDrop {
        child,
        reaped: false,
    };
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
        if let Some(status) = child.child.try_wait().map_err(failed)? {
            child.reaped = true;
            break status;
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

/// Terminates the harness and its process group on every early return, and reaps it.
struct KilledOnDrop {
    child: std::process::Child,
    /// Once reaped, its group ID may be reused, so the group is no longer signalled.
    reaped: bool,
}

impl Drop for KilledOnDrop {
    fn drop(&mut self) {
        if !self.reaped
            && let Ok(group) = i32::try_from(self.child.id())
        {
            // SAFETY: The unreaped child leads its own process group, so this group is still its.
            unsafe { libc::kill(-group, libc::SIGKILL) };
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_lists_its_picker_models_in_priority_order() {
        let output = r#"{"models":[
            {"slug":"b","display_name":"Beta","visibility":"list","priority":2,
             "supported_reasoning_levels":[{"effort":"low"},{"effort":"ultra"}]},
            {"slug":"hidden","display_name":"Hidden","visibility":"hide","priority":0},
            {"slug":"a","display_name":"Alpha","visibility":"list","priority":1,"extra":{"x":1},
             "supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]},
            {"slug":"plain","visibility":"list","priority":3}
        ]}"#;
        let models = HarnessId::Codex.parse_models(output).unwrap();
        assert!(!models.allows_custom);
        assert_eq!(
            models
                .models
                .iter()
                .map(|m| (m.id.as_str(), m.name.as_str()))
                .collect::<Vec<_>>(),
            [("a", "Alpha"), ("b", "Beta"), ("plain", "plain")]
        );
        assert_eq!(
            models.models[1].efforts.as_deref(),
            Some(&["low".to_owned(), "ultra".to_owned()][..])
        );
        assert_eq!(models.efforts, ["low", "high", "ultra"]);
        assert!(HarnessId::Codex.parse_models("not json").is_err());
    }

    #[test]
    fn pi_lists_provider_and_model_rows_as_provider_ids() {
        let output = "provider    model                         context  max-out  thinking  images\n\
                      lmstudio    qwen/qwen3.8-27b              169.7K   32.8K    yes       yes\n\
                      openrouter  ~anthropic/claude-opus-latest 1M       128K     yes       yes\n\n";
        let models = HarnessId::Pi.parse_models(output).unwrap().models;
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "lmstudio/qwen/qwen3.8-27b");
        assert_eq!(models[0].name, "qwen/qwen3.8-27b");
        assert_eq!(models[1].group.as_deref(), Some("openrouter"));
        assert_eq!(
            HarnessId::Pi
                .parse_models("No models available.\n")
                .unwrap()
                .models,
            []
        );
    }

    #[test]
    fn omp_lists_exact_selectors_and_model_specific_thinking_levels() {
        let output = r#"{"models":[
            {"selector":"local/plain","provider":"local","name":"Plain model","thinking":null},
            {"selector":"local/path/model","provider":"local","name":"Reasoning model","thinking":["low","high","BAD"]}
        ]}"#;
        let models = HarnessId::Omp.parse_models(output).unwrap();
        assert_eq!(models.models.len(), 2);
        assert_eq!(models.models[0].name, "Plain model");
        assert_eq!(models.models[0].efforts, Some(vec![]));
        assert_eq!(models.models[1].id, "local/path/model");
        assert_eq!(models.models[1].group.as_deref(), Some("local"));
        assert_eq!(
            models.models[1].efforts,
            Some(vec!["low".into(), "high".into()])
        );
        assert!(models.allows_custom && models.supports_yolo);
        assert_eq!(
            HarnessId::Omp
                .parse_models(r#"{"models":[]}"#)
                .unwrap()
                .models,
            []
        );
        for unreadable in [
            "not json",
            "{}",
            r#"{"models":[{"selector":"--flag","provider":"local","name":"Bad"}]}"#,
        ] {
            assert!(HarnessId::Omp.parse_models(unreadable).is_err());
        }
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
    fn opencode_lists_provider_selectors_and_model_specific_variants() {
        let output = r#"{"location":{"directory":"/folder"},"data":[
            {"providerID":"opencode","id":"plain","name":"Plain","variants":[]},
            {"providerID":"local","id":"path/model","name":"Reasoning",
             "variants":[{"id":"low"},{"id":"high"},{"id":"custom-name"},{"id":"Custom_Name"},{"id":"bad#variant"}]}
        ]}"#;
        let models = HarnessId::Opencode.parse_models(output).unwrap();
        assert_eq!(models.models[0].id, "opencode/plain");
        assert_eq!(models.models[0].efforts, Some(vec![]));
        assert_eq!(models.models[1].id, "local/path/model");
        assert_eq!(models.models[1].name, "Reasoning");
        assert_eq!(models.models[1].group.as_deref(), Some("local"));
        assert_eq!(
            models.models[1].efforts,
            Some(vec![
                "low".into(),
                "high".into(),
                "custom-name".into(),
                "Custom_Name".into()
            ])
        );
        assert_eq!(models.efforts, Vec::<String>::new());
        assert!(models.allows_custom && !models.supports_yolo);
        assert_eq!(
            HarnessId::Opencode
                .parse_models(r#"{"data":[]}"#)
                .unwrap()
                .models,
            []
        );
        for unreadable in [
            "",
            "not json",
            "{}",
            r#"{"data":[{"providerID":"","id":"model","name":"Bad"}]}"#,
        ] {
            assert!(HarnessId::Opencode.parse_models(unreadable).is_err());
        }
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
    fn antigravity_lists_model_ids_and_names_without_losing_spaces() {
        let output = "Fetching available models...\n\
                      gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n\
                      claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)\n";
        let models = HarnessId::Antigravity.parse_models(output).unwrap();
        assert_eq!(models.models.len(), 2);
        assert_eq!(models.models[0].id, "gemini-3.8-flash-high");
        assert_eq!(models.models[0].name, "Gemini 3.8 Flash (High)");
        assert_eq!(models.models[1].name, "Claude Sonnet 4.6 (Thinking)");
        assert!(!models.allows_custom);
        assert!(models.supports_yolo);
        for unreadable in ["not a model list", "", "--flag\tBad model", "model\t"] {
            assert!(HarnessId::Antigravity.parse_models(unreadable).is_err());
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

    #[test]
    fn claude_code_offers_the_aliases_its_help_names_and_custom_names() {
        let output = "  --fallback-model <model>   Enable fallback\n\
                      \x20 --model <model>            Model for the current session. Provide\n\
                      \x20                            an alias for the latest model (e.g.\n\
                      \x20                            'fable', 'opus', or 'sonnet') or a\n\
                      \x20                            model's full name.\n\
                      \x20 -n, --name <name>          Set a 'display name'\n\
                      \x20 --effort <level>           Effort level for the current session\n\
                      \x20                            (low, medium, high, xhigh, max)\n\
                      \x20 --environment <id>         Create a session\n";
        let models = HarnessId::ClaudeCode.parse_models(output).unwrap();
        assert!(models.allows_custom);
        assert_eq!(
            models
                .models
                .iter()
                .map(|m| (m.id.as_str(), m.name.as_str()))
                .collect::<Vec<_>>(),
            [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet")]
        );
        assert_eq!(models.efforts, ["low", "medium", "high", "xhigh", "max"]);
        let changed = HarnessId::ClaudeCode
            .parse_models("Usage: claude\n")
            .unwrap();
        assert!(changed.models.is_empty() && changed.allows_custom);
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
        while is_running(pid.trim()) {
            assert!(Instant::now() < deadline, "the harness kept running");
            thread::sleep(Duration::from_millis(10));
        }
    }
}
