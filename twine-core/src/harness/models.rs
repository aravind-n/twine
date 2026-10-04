//! The models a harness offers, read from the harness's own CLI.

use super::launch::{validate_effort, validate_model, validate_variant};
use super::{HarnessError, HarnessId};
use serde::{Deserialize, Serialize};
use thiserror::Error;

mod discovery;
pub use discovery::ModelListRequest;
pub(crate) use discovery::ModelListWorkers;

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
}
