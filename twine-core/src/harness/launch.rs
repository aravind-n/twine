//! Launch options and the harness flags they become, including the ones that skip permission
//! prompts. Every value is validated here before it can reach a harness's command line.

use std::ffi::OsString;

use super::HarnessId;

/// A model is passed as one argument after `--model`, so it stays short and plain.
const MAX_MODEL_BYTES: usize = 256;

/// A launch's model and effort level, checked so neither can read as a flag or break out of the
/// Codex config value it goes into. Only `validate_options` makes one.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct LaunchOptions<'a> {
    model: Option<&'a str>,
    effort: Option<&'a str>,
    /// Skips the harness's permission prompts, where it has them.
    yolo: bool,
}

impl<'a> LaunchOptions<'a> {
    pub(crate) fn model(self) -> Option<&'a str> {
        self.model
    }

    pub(crate) fn effort(self) -> Option<&'a str> {
        self.effort
    }

    pub(crate) fn yolo(self) -> bool {
        self.yolo
    }
}

/// The launch arguments for a model and effort level, in each harness's own flags.
pub(crate) fn launch_arguments(harness: HarnessId, options: LaunchOptions<'_>) -> Vec<OsString> {
    let mut arguments = Vec::new();
    let LaunchOptions {
        model,
        effort,
        yolo,
    } = options;
    if yolo {
        match harness {
            HarnessId::Codex => {
                arguments.push(OsString::from("--dangerously-bypass-approvals-and-sandbox"));
            }
            HarnessId::ClaudeCode => {
                arguments.push(OsString::from("--dangerously-skip-permissions"));
            }
            HarnessId::Pi => {}
        }
    }
    if let Some(model) = model {
        arguments.extend([OsString::from("--model"), OsString::from(model)]);
    }
    if let Some(effort) = effort {
        match harness {
            HarnessId::Codex => {
                arguments.extend([
                    OsString::from("-c"),
                    OsString::from(format!("model_reasoning_effort=\"{effort}\"")),
                ]);
            }
            HarnessId::ClaudeCode => {
                arguments.extend([OsString::from("--effort"), OsString::from(effort)]);
            }
            HarnessId::Pi => {
                arguments.extend([OsString::from("--thinking"), OsString::from(effort)]);
            }
        }
    }
    arguments
}

/// A launch's optional model and effort, trimmed, or `None` when either is given but invalid.
pub(crate) fn validate_options<'a>(
    model: Option<&'a str>,
    effort: Option<&'a str>,
    yolo: bool,
) -> Option<LaunchOptions<'a>> {
    Some(LaunchOptions {
        model: model.map_or(Some(None), |model| validate_model(model).map(Some))?,
        effort: effort.map_or(Some(None), |effort| validate_effort(effort).map(Some))?,
        yolo,
    })
}

/// An effort level: one short lowercase word, as every harness names them.
pub(crate) fn validate_effort(effort: &str) -> Option<&str> {
    let effort = effort.trim();
    (!effort.is_empty()
        && effort.len() <= 32
        && effort
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()))
    .then_some(effort)
}

/// A model to pass after `--model`: trimmed, and rejected when it could read as a flag or
/// isn't a single plain word.
pub(crate) fn validate_model(model: &str) -> Option<&str> {
    let model = model.trim();
    (!model.is_empty()
        && model.len() <= MAX_MODEL_BYTES
        && !model.starts_with('-')
        && model.chars().all(|c| !c.is_whitespace() && !c.is_control()))
    .then_some(model)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_harness_gets_the_model_and_effort_in_its_own_flags() {
        let arguments = |harness| {
            launch_arguments(
                harness,
                validate_options(Some("m1"), Some("high"), true).unwrap(),
            )
            .into_iter()
            .map(|argument| argument.into_string().unwrap())
            .collect::<Vec<_>>()
        };
        assert_eq!(
            arguments(HarnessId::Codex),
            [
                "--dangerously-bypass-approvals-and-sandbox",
                "--model",
                "m1",
                "-c",
                "model_reasoning_effort=\"high\""
            ]
        );
        assert_eq!(
            arguments(HarnessId::ClaudeCode),
            [
                "--dangerously-skip-permissions",
                "--model",
                "m1",
                "--effort",
                "high"
            ]
        );
        assert_eq!(
            arguments(HarnessId::Pi),
            ["--model", "m1", "--thinking", "high"]
        );
        assert!(launch_arguments(HarnessId::Pi, LaunchOptions::default()).is_empty());
        assert_eq!(
            validate_options(Some(" m "), None, false)
                .map(|options| (options.model(), options.effort())),
            Some((Some("m"), None))
        );
        assert_eq!(validate_options(None, Some("High"), false), None);
        assert_eq!(validate_effort(" xhigh "), Some("xhigh"));
        for bad in ["", "High", "a b", "\"x", "x=1"] {
            assert_eq!(validate_effort(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn models_are_single_plain_arguments() {
        assert_eq!(validate_model("  gpt-6.1-sol "), Some("gpt-6.1-sol"));
        assert_eq!(
            validate_model("openrouter/~anthropic/claude-opus-latest"),
            Some("openrouter/~anthropic/claude-opus-latest")
        );
        for bad in [
            "",
            "   ",
            "-x",
            "--model",
            "two words",
            "line\nbreak",
            &"m".repeat(257),
        ] {
            assert_eq!(validate_model(bad), None, "{bad:?}");
        }
    }
}
