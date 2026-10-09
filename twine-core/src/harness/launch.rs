//! Launch options and the harness flags they become, including the ones that skip permission
//! prompts. Every value is validated here before it can reach a harness's command line.

use std::ffi::OsString;

use super::HarnessId;

/// A model is passed as one argument after `--model`, so it stays short and plain.
const MAX_MODEL_BYTES: usize = 256;

/// Keep Claude's conversation in native terminal scrollback, even when the user has
/// enabled its fullscreen renderer. Apply this to fresh launches and resumed agents.
pub(crate) fn launch_environment(harness: HarnessId) -> &'static [(&'static str, &'static str)] {
    match harness {
        HarnessId::ClaudeCode => &[("CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN", "1")],
        _ => &[],
    }
}

/// Per-process observer settings supplement the harness's static launch environment.
pub(crate) fn observed_environment(
    harness: HarnessId,
    inbox: Option<&super::steps::StepInbox>,
) -> Vec<(&str, &str)> {
    let mut environment = launch_environment(harness).to_vec();
    if let Some(inbox) = inbox {
        environment.extend(
            inbox
                .environment
                .iter()
                .map(|(key, value)| (key.as_str(), value.as_str())),
        );
    }
    environment
}

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
    match harness {
        HarnessId::Codex => {
            // Invocation-only hooks and effort overrides require embedded mode.
            // Choose it explicitly instead of emitting the shared-server fallback warning.
            arguments.extend([
                OsString::from("--no-daemon"),
                OsString::from("--no-alt-screen"),
            ]);
        }
        HarnessId::Pi => {
            arguments.extend([OsString::from("--tui-mode"), OsString::from("regular")]);
        }
        _ => {}
    }
    if harness == HarnessId::Opencode {
        // A private server keeps tools and their child processes within this terminal's lifetime.
        arguments.push(OsString::from("--standalone"));
    }
    if yolo {
        match harness {
            HarnessId::Codex => {
                arguments.push(OsString::from("--dangerously-bypass-approvals-and-sandbox"));
            }
            HarnessId::ClaudeCode | HarnessId::Antigravity => {
                arguments.push(OsString::from("--dangerously-skip-permissions"));
            }
            HarnessId::Pi | HarnessId::Opencode => {}
            HarnessId::Omp => {
                arguments.push(OsString::from("--auto-approve"));
            }
        }
    }
    if let Some(model) = model {
        let model = match (harness, effort) {
            (HarnessId::Opencode, Some(variant)) => {
                format!("{}#{variant}", model.split('#').next().unwrap_or(model))
            }
            _ => model.to_owned(),
        };
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
            HarnessId::ClaudeCode | HarnessId::Antigravity => {
                arguments.extend([OsString::from("--effort"), OsString::from(effort)]);
            }
            HarnessId::Pi | HarnessId::Omp => {
                arguments.extend([OsString::from("--thinking"), OsString::from(effort)]);
            }
            // OpenCode's variant is part of the selected model; the default has no known variants.
            HarnessId::Opencode => {}
        }
    }
    arguments
}

/// A launch's optional model and effort, trimmed, or `None` when either is given but invalid.
pub(crate) fn validate_options<'a>(
    harness: HarnessId,
    model: Option<&'a str>,
    effort: Option<&'a str>,
    yolo: bool,
) -> Option<LaunchOptions<'a>> {
    Some(LaunchOptions {
        model: model.map_or(Some(None), |model| validate_model(model).map(Some))?,
        effort: effort.map_or(Some(None), |effort| {
            if harness == HarnessId::Opencode {
                validate_variant(effort).map(Some)
            } else {
                validate_effort(effort).map(Some)
            }
        })?,
        yolo,
    })
}

/// A named variant carried after `#` in a model selector, including custom punctuation and case.
pub(crate) fn validate_variant(variant: &str) -> Option<&str> {
    let variant = variant.trim();
    (!variant.is_empty()
        && variant.len() <= MAX_MODEL_BYTES
        && variant
            .chars()
            .all(|c| !c.is_whitespace() && !c.is_control() && c != '#'))
    .then_some(variant)
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
                validate_options(harness, Some("m1"), Some("high"), true).unwrap(),
            )
            .into_iter()
            .map(|argument| argument.into_string().unwrap())
            .collect::<Vec<_>>()
        };
        assert_eq!(
            arguments(HarnessId::Codex),
            [
                "--no-daemon",
                "--no-alt-screen",
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
            [
                "--tui-mode",
                "regular",
                "--model",
                "m1",
                "--thinking",
                "high"
            ]
        );
        assert_eq!(
            arguments(HarnessId::Antigravity),
            [
                "--dangerously-skip-permissions",
                "--model",
                "m1",
                "--effort",
                "high"
            ]
        );
        assert_eq!(
            launch_arguments(HarnessId::Antigravity, LaunchOptions::default()),
            Vec::<OsString>::new()
        );
        assert_eq!(
            launch_arguments(HarnessId::Pi, LaunchOptions::default()),
            ["--tui-mode", "regular"]
        );
        assert_eq!(
            arguments(HarnessId::Omp),
            ["--auto-approve", "--model", "m1", "--thinking", "high"]
        );
        assert_eq!(
            launch_arguments(HarnessId::Omp, LaunchOptions::default()),
            Vec::<OsString>::new()
        );
        assert_eq!(
            arguments(HarnessId::Opencode),
            ["--standalone", "--model", "m1#high"]
        );
    }

    #[test]
    fn opencode_variants_keep_named_selectors_and_other_harnesses_validation() {
        for (model, effort, expected) in [
            (
                Some("local/model#deep"),
                None,
                vec!["--standalone", "--model", "local/model#deep"],
            ),
            (
                Some("local/model#low"),
                Some("high"),
                vec!["--standalone", "--model", "local/model#high"],
            ),
            (None, Some("high"), vec!["--standalone"]),
        ] {
            assert_eq!(
                launch_arguments(
                    HarnessId::Opencode,
                    validate_options(HarnessId::Opencode, model, effort, true).unwrap()
                ),
                expected.into_iter().map(OsString::from).collect::<Vec<_>>()
            );
        }
        assert_eq!(
            validate_options(HarnessId::Codex, Some(" m "), None, false)
                .map(|options| (options.model(), options.effort())),
            Some((Some("m"), None))
        );
        assert_eq!(
            validate_options(HarnessId::Codex, None, Some("High"), false),
            None
        );
        for variant in ["custom-name", "custom_name", "High", "high"] {
            let options = validate_options(
                HarnessId::Opencode,
                Some("local/model"),
                Some(variant),
                false,
            )
            .unwrap();
            assert_eq!(
                launch_arguments(HarnessId::Opencode, options),
                ["--standalone", "--model", &format!("local/model#{variant}")].map(OsString::from)
            );
        }
        for variant in ["bad#variant", "bad variant", "bad\nvariant", ""] {
            assert!(
                validate_options(
                    HarnessId::Opencode,
                    Some("local/model"),
                    Some(variant),
                    false
                )
                .is_none()
            );
            assert!(validate_options(HarnessId::Codex, Some("m1"), Some(variant), false).is_none());
        }
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
