//! Terminal palettes are resolved in core so every terminal consumer uses the same colors.

use std::fs;
use std::io;
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::{ConfigDiagnostic, file_diagnostic, imports, write_default};

mod bundled;

const SILICA_LIGHT: &str = include_str!("themes/silica_light.toml");
const SILICA_DARK: &str = include_str!("themes/silica_dark.toml");
const TWINE_LIGHT: &str = include_str!("themes/twine_light.toml");
const TWINE_DARK: &str = include_str!("themes/twine_dark.toml");

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct ThemeConfig {
    pub light: ThemeName,
    pub dark: ThemeName,
}

impl Default for ThemeConfig {
    fn default() -> Self {
        Self {
            light: ThemeName("twine_light".to_owned()),
            dark: ThemeName("twine_dark".to_owned()),
        }
    }
}

/// A theme file's basename, resolved beneath the user config's themes directory.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct ThemeName(String);

impl ThemeName {
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for ThemeName {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let name = String::deserialize(deserializer)?;
        if name.trim().is_empty()
            || matches!(name.as_str(), "." | "..")
            || name.contains(['/', '\\', '\0'])
        {
            return Err(serde::de::Error::custom(
                "theme name must be a single file basename",
            ));
        }
        Ok(Self(name))
    }
}

pub(super) const ANSI_COLOR_NAMES: [&str; 16] = [
    "black",
    "red",
    "green",
    "yellow",
    "blue",
    "magenta",
    "cyan",
    "white",
    "brblack",
    "brred",
    "brgreen",
    "bryellow",
    "brblue",
    "brmagenta",
    "brcyan",
    "brwhite",
];

/// An opaque sRGB color written as `#RRGGBB`.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct HexColor(String);

impl HexColor {
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for HexColor {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        if value.len() != 7
            || !value.starts_with('#')
            || !value.as_bytes()[1..].iter().all(u8::is_ascii_hexdigit)
        {
            return Err(serde::de::Error::custom("color must be #RRGGBB"));
        }
        Ok(Self(value))
    }
}

/// Terminal color overrides, supplied inline or through a global config import.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct TerminalColors {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub background: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub foreground: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection: Option<HexColor>,
    /// Legacy array input remains readable; new files use the individual color keys below.
    #[serde(skip_serializing, deserialize_with = "deserialize_ansi")]
    pub ansi: Option<[HexColor; 16]>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub black: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub red: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub green: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub yellow: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blue: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub magenta: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cyan: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub white: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub brblack: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub brred: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub brgreen: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bryellow: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub brblue: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub brmagenta: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub brcyan: Option<HexColor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub brwhite: Option<HexColor>,
}

impl TerminalColors {
    fn named_ansi(&self) -> [Option<&HexColor>; 16] {
        [
            self.black.as_ref(),
            self.red.as_ref(),
            self.green.as_ref(),
            self.yellow.as_ref(),
            self.blue.as_ref(),
            self.magenta.as_ref(),
            self.cyan.as_ref(),
            self.white.as_ref(),
            self.brblack.as_ref(),
            self.brred.as_ref(),
            self.brgreen.as_ref(),
            self.bryellow.as_ref(),
            self.brblue.as_ref(),
            self.brmagenta.as_ref(),
            self.brcyan.as_ref(),
            self.brwhite.as_ref(),
        ]
    }
}

fn deserialize_ansi<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<[HexColor; 16]>, D::Error> {
    Option::<Vec<HexColor>>::deserialize(deserializer)?
        .map(|colors| {
            colors.try_into().map_err(|_| {
                serde::de::Error::custom("ANSI palette must contain exactly 16 colors")
            })
        })
        .transpose()
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct TerminalPalette {
    pub background: HexColor,
    pub foreground: HexColor,
    pub cursor: HexColor,
    pub selection: HexColor,
    pub ansi: [HexColor; 16],
}

impl TerminalPalette {
    fn apply(&mut self, colors: &TerminalColors) {
        if let Some(color) = &colors.background {
            self.background = color.clone();
        }
        if let Some(color) = &colors.foreground {
            self.foreground = color.clone();
        }
        if let Some(color) = &colors.cursor {
            self.cursor = color.clone();
        }
        if let Some(color) = &colors.selection {
            self.selection = color.clone();
        }
        if let Some(colors) = &colors.ansi {
            self.ansi.clone_from(colors);
        }
        for (slot, color) in self.ansi.iter_mut().zip(colors.named_ansi()) {
            if let Some(color) = color {
                *slot = color.clone();
            }
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct TerminalPalettes {
    pub light: TerminalPalette,
    pub dark: TerminalPalette,
}

impl Default for TerminalPalettes {
    fn default() -> Self {
        Self {
            light: embedded_palette(TWINE_LIGHT),
            dark: embedded_palette(TWINE_DARK),
        }
    }
}

impl TerminalPalettes {
    pub(super) fn apply(&mut self, colors: &TerminalColors) {
        self.light.apply(colors);
        self.dark.apply(colors);
    }
}

fn embedded_palette(source: &str) -> TerminalPalette {
    let table: toml::Table = toml::from_str(source).expect("valid embedded theme document");
    let colors: TerminalColors = table["terminal"]["colors"]
        .clone()
        .try_into()
        .expect("valid embedded terminal palette");
    let ansi = colors
        .named_ansi()
        .map(|color| color.expect("complete embedded ANSI palette").clone());
    TerminalPalette {
        background: colors.background.expect("embedded background"),
        foreground: colors.foreground.expect("embedded foreground"),
        cursor: colors.cursor.expect("embedded cursor"),
        selection: colors.selection.expect("embedded selection"),
        ansi,
    }
}

pub(super) fn publish(config_path: &Path) -> Vec<(&'static str, ConfigDiagnostic)> {
    let directory = config_path.parent().unwrap_or(Path::new("."));
    bundled::publish(directory);
    let mut failures = Vec::new();
    // Publish defaults before resolving either global imports or appearance selectors.
    for (name, source, legacy_name, legacy_source) in [
        (
            "twine_light.toml",
            TWINE_LIGHT,
            "silica_light.toml",
            SILICA_LIGHT,
        ),
        (
            "twine_dark.toml",
            TWINE_DARK,
            "silica_dark.toml",
            SILICA_DARK,
        ),
    ] {
        let path = directory.join("themes").join(name);
        let result = match fs::symlink_metadata(&path) {
            Ok(_) => continue,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                // Carry customized defaults forward once; untouched Silica files stay optional.
                let legacy_path = directory.join("themes").join(legacy_name);
                let source = match fs::read_to_string(&legacy_path) {
                    Ok(legacy) => {
                        if legacy == legacy_source {
                            source.to_owned()
                        } else {
                            legacy
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::NotFound => source.to_owned(),
                    Err(error) => {
                        let diagnostic =
                            file_diagnostic(&legacy_path, &super::ConfigFileError::Read(error));
                        tracing::warn!(%diagnostic, "cannot migrate default theme file");
                        failures.push((name, diagnostic));
                        continue;
                    }
                };
                write_default(&path, &source).map(|_| ())
            }
            Err(error) => Err(super::ConfigFileError::Read(error)),
        };
        if let Err(error) = result {
            let diagnostic = file_diagnostic(&path, &error);
            tracing::warn!(%diagnostic, "cannot publish default theme file");
            failures.push((name, diagnostic));
        }
    }
    failures
}

pub(super) fn load(
    config_path: &Path,
    selection: &ThemeConfig,
    publication_failures: &[(&str, ConfigDiagnostic)],
) -> (TerminalPalettes, Vec<ConfigDiagnostic>) {
    let directory = config_path.parent().unwrap_or(Path::new("."));
    let mut palettes = TerminalPalettes::default();
    let mut diagnostics = Vec::new();
    for (name, palette) in [
        (&selection.light, &mut palettes.light),
        (&selection.dark, &mut palettes.dark),
    ] {
        let filename = format!("{}.toml", name.as_str());
        if let Some((_, diagnostic)) = publication_failures
            .iter()
            .find(|(failed, _)| *failed == filename)
        {
            diagnostics.push(diagnostic.clone());
            continue;
        }
        let path = directory.join("themes").join(filename);
        let source = match fs::read_to_string(&path) {
            Ok(source) => source,
            Err(error) => {
                diagnostics.push(file_diagnostic(&path, &super::ConfigFileError::Read(error)));
                continue;
            }
        };
        let loaded = imports::load(&path, &source);
        diagnostics.extend(loaded.diagnostics);
        palette.apply(&loaded.config.terminal.colors);
    }
    (palettes, diagnostics)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, ConfigProblem};

    #[test]
    fn selectors_resolve_independent_palettes_and_theme_files_import_colors_only() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        let themes = directory.path().join("themes");
        fs::create_dir(&themes).unwrap();
        fs::write(
            themes.join("my light.toml"),
            "[terminal.colors]\nbackground = '#112233'\nblue = '#445566'\n",
        )
        .unwrap();
        fs::write(
            themes.join("base.toml"),
            "[terminal]\nfont_size = 22\n[terminal.colors]\nbackground = '#778899'\n",
        )
        .unwrap();
        fs::write(
            themes.join("my_dark.toml"),
            "import = 'base.toml'\n[terminal.colors]\nblue = '#abcdef'\n",
        )
        .unwrap();
        fs::write(&config, "[theme]\nlight = 'my light'\ndark = 'my_dark'\n").unwrap();
        let loaded = Config::load(&config);
        assert_eq!(loaded.diagnostics, []);
        assert_eq!(
            loaded.config.terminal.font_size,
            super::super::FontSize::default()
        );
        assert_eq!(
            loaded.config.terminal.palettes.light.background.as_str(),
            "#112233"
        );
        assert_eq!(
            loaded.config.terminal.palettes.light.ansi[4].as_str(),
            "#445566"
        );
        assert_eq!(
            loaded.config.terminal.palettes.light.foreground,
            TerminalPalettes::default().light.foreground
        );
        assert_eq!(
            loaded.config.terminal.palettes.dark.background.as_str(),
            "#778899"
        );
        assert_eq!(
            loaded.config.terminal.palettes.dark.ansi[4].as_str(),
            "#abcdef"
        );
    }

    #[test]
    fn omitted_selectors_keep_the_corresponding_default() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        for mode in ["light", "dark"] {
            fs::write(&config, format!("[theme]\n{mode} = 'nord'\n")).unwrap();
            let loaded = Config::load(&config);
            assert_eq!(loaded.diagnostics, []);
            let (selected, omitted, default) = if mode == "light" {
                (
                    &loaded.config.terminal.palettes.light,
                    &loaded.config.terminal.palettes.dark,
                    TerminalPalettes::default().dark,
                )
            } else {
                (
                    &loaded.config.terminal.palettes.dark,
                    &loaded.config.terminal.palettes.light,
                    TerminalPalettes::default().light,
                )
            };
            assert_eq!(selected.background.as_str(), "#2e3440");
            assert_eq!(*omitted, default);
        }
    }

    #[test]
    fn global_imports_and_inline_colors_override_selected_palettes() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        let themes = directory.path().join("themes");
        fs::create_dir(&themes).unwrap();
        fs::write(
            themes.join("light.toml"),
            "[terminal.colors]\nbackground = '#112233'\nblue = '#123456'\n",
        )
        .unwrap();
        fs::write(
            themes.join("dark.toml"),
            "[terminal.colors]\nbackground = '#445566'\nblue = '#654321'\n",
        )
        .unwrap();
        let nested = directory.path().join("nested");
        fs::create_dir(&nested).unwrap();
        fs::write(nested.join("shared.toml"), "[theme]\nlight = 'light'\n[terminal.colors]\nbackground = '#abcdef'\nred = '#111111'\n").unwrap();
        fs::write(&config, "import = 'nested/shared.toml'\n[theme]\ndark = 'dark'\n[terminal.colors]\nred = '#222222'\n").unwrap();
        let loaded = Config::load(&config);
        assert_eq!(loaded.diagnostics, []);
        for palette in [
            &loaded.config.terminal.palettes.light,
            &loaded.config.terminal.palettes.dark,
        ] {
            assert_eq!(palette.background.as_str(), "#abcdef");
            assert_eq!(palette.ansi[1].as_str(), "#222222");
        }
        assert_eq!(
            loaded.config.terminal.palettes.light.ansi[4].as_str(),
            "#123456"
        );
        assert_eq!(
            loaded.config.terminal.palettes.dark.ansi[4].as_str(),
            "#654321"
        );
    }

    #[test]
    fn selected_theme_errors_report_the_file_and_preserve_its_contents() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        fs::write(
            &config,
            "terminal.font_size = 20\n[theme]\ndark = 'missing'\n",
        )
        .unwrap();
        let theme = directory.path().join("themes/missing.toml");
        let missing = Config::load(&config);
        assert_eq!(missing.config, Config::default());
        assert_eq!(missing.diagnostics[0].file, theme);
        assert!(matches!(
            missing.diagnostics[0].problem,
            ConfigProblem::File(_)
        ));
        assert!(!theme.exists());
        let invalid = "[terminal.colors]\nforeground = 'secret'\n";
        fs::write(&theme, invalid).unwrap();
        let loaded = Config::load(&config);
        assert_eq!(loaded.config, Config::default());
        assert_eq!(loaded.diagnostics[0].file, theme);
        assert_eq!(loaded.diagnostics[0].line, 2);
        assert_eq!(loaded.diagnostics[0].key, "terminal.colors.foreground");
        assert_eq!(loaded.diagnostics[0].problem, ConfigProblem::InvalidValue);
        assert!(!loaded.diagnostics[0].to_string().contains("secret"));
        assert_eq!(fs::read_to_string(&theme).unwrap(), invalid);
    }

    #[test]
    fn invalid_selector_names_and_types_report_the_appearance_key() {
        for mode in ["light", "dark"] {
            for value in [
                "''",
                "' '",
                "'../escape'",
                "'/absolute'",
                "'a\\b'",
                "'.'",
                "'..'",
                "1",
                "[]",
            ] {
                let source = format!("[theme]\n{mode} = {value}\n");
                let loaded = Config::parse(Path::new("/test/config.toml"), &source);
                assert_eq!(loaded.config, Config::default());
                assert_eq!(loaded.diagnostics.len(), 1, "{value}");
                assert_eq!(loaded.diagnostics[0].key, format!("theme.{mode}"));
                assert_eq!(loaded.diagnostics[0].line, 2);
                assert_eq!(loaded.diagnostics[0].problem, ConfigProblem::InvalidValue);
            }
        }
    }

    #[test]
    fn invalid_unused_default_files_do_not_override_a_selected_theme() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        let themes = directory.path().join("themes");
        fs::create_dir(&themes).unwrap();
        fs::write(themes.join("twine_dark.toml"), "invalid = @").unwrap();
        fs::write(&config, "[theme]\ndark = 'nord'\n").unwrap();
        let loaded = Config::load(&config);
        assert_eq!(loaded.diagnostics, []);
        assert_eq!(
            loaded.config.terminal.palettes.dark.background.as_str(),
            "#2e3440"
        );
        assert_eq!(
            fs::read_to_string(themes.join("twine_dark.toml")).unwrap(),
            "invalid = @"
        );
    }

    #[test]
    fn named_colors_override_only_their_ansi_slots_in_both_appearances() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        for (slot, name) in [
            "black",
            "red",
            "green",
            "yellow",
            "blue",
            "magenta",
            "cyan",
            "white",
            "brblack",
            "brred",
            "brgreen",
            "bryellow",
            "brblue",
            "brmagenta",
            "brcyan",
            "brwhite",
        ]
        .iter()
        .enumerate()
        {
            fs::write(&config, format!("[terminal.colors]\n{name} = '#123456'\n")).unwrap();
            let loaded = Config::load(&config);
            assert_eq!(loaded.diagnostics, []);
            let mut expected = TerminalPalettes::default();
            expected.light.ansi[slot] = HexColor("#123456".into());
            expected.dark.ansi[slot] = HexColor("#123456".into());
            assert_eq!(loaded.config.terminal.palettes, expected, "{name}");
        }
    }

    #[test]
    fn named_colors_merge_across_imports_and_report_invalid_values_by_name() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        fs::write(
            directory.path().join("colors.toml"),
            "[terminal.colors]\nblack = '#111111'\nblue = '#222222'\nbrmagenta = '#333333'\n",
        )
        .unwrap();
        fs::write(
            &config,
            "import = 'colors.toml'\n[terminal.colors]\nblue = '#444444'\n",
        )
        .unwrap();
        let loaded = Config::load(&config);
        assert_eq!(loaded.diagnostics, []);
        for palette in [
            &loaded.config.terminal.palettes.light,
            &loaded.config.terminal.palettes.dark,
        ] {
            assert_eq!(palette.ansi[0].as_str(), "#111111");
            assert_eq!(palette.ansi[4].as_str(), "#444444");
            assert_eq!(palette.ansi[13].as_str(), "#333333");
        }
        fs::write(&config, "[terminal.colors]\nbrblue = 'secret'\n").unwrap();
        let loaded = Config::load(&config);
        assert_eq!(loaded.config, Config::default());
        assert_eq!(loaded.diagnostics[0].key, "terminal.colors.brblue");
        assert_eq!(loaded.diagnostics[0].line, 2);
        assert_eq!(loaded.diagnostics[0].problem, ConfigProblem::InvalidValue);
        assert!(!loaded.diagnostics[0].to_string().contains("secret"));
    }

    #[test]
    fn legacy_array_remains_readable_and_named_keys_override_it() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        fs::write(
            &config,
            format!(
                "[terminal.colors]\nansi = [{}]\nblue = '#abcdef'\n",
                vec!["'#112233'"; 16].join(",")
            ),
        )
        .unwrap();
        let loaded = Config::load(&config);
        assert_eq!(loaded.diagnostics, []);
        assert_eq!(
            loaded.config.terminal.palettes.dark.ansi[0].as_str(),
            "#112233"
        );
        assert_eq!(
            loaded.config.terminal.palettes.dark.ansi[4].as_str(),
            "#abcdef"
        );
        let serialized = toml::to_string(&loaded.config.terminal.colors).unwrap();
        assert!(serialized.contains("blue ="));
        assert!(!serialized.contains("ansi ="));
    }

    #[test]
    fn mixed_formats_preserve_import_order_and_local_precedence() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        fs::write(
            directory.path().join("named.toml"),
            "[terminal.colors]\nblue = '#abcdef'\n",
        )
        .unwrap();
        let legacy = format!(
            "[terminal.colors]\nansi = [{}]\n",
            vec!["'#112233'"; 16].join(",")
        );
        fs::write(directory.path().join("legacy.toml"), &legacy).unwrap();
        for (source, expected) in [
            (format!("import = 'named.toml'\n{legacy}"), "#112233"),
            ("import = ['named.toml', 'legacy.toml']\n".into(), "#112233"),
            ("import = ['legacy.toml', 'named.toml']\n".into(), "#abcdef"),
        ] {
            fs::write(&config, source).unwrap();
            let loaded = Config::load(&config);
            assert_eq!(loaded.diagnostics, []);
            assert_eq!(
                loaded.config.terminal.palettes.dark.ansi[4].as_str(),
                expected
            );
        }
    }

    #[test]
    fn seeds_both_palettes_and_preserves_user_edits() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        let first = Config::load(&config);
        assert_eq!(first.config, Config::default());
        assert_eq!(first.diagnostics, []);
        let dark = directory.path().join("themes/twine_dark.toml");
        assert_eq!(fs::read_to_string(&dark).unwrap(), TWINE_DARK);
        assert_eq!(
            fs::read_to_string(directory.path().join("themes/twine_light.toml")).unwrap(),
            TWINE_LIGHT
        );
        fs::write(&dark, "[terminal.colors]\nbackground = '#112233'").unwrap();
        let edited = Config::load(&config);
        assert_eq!(
            edited.config.terminal.palettes.dark.background.as_str(),
            "#112233"
        );
        assert_eq!(
            edited.config.terminal.palettes.light,
            TerminalPalettes::default().light
        );
        assert_eq!(
            fs::read_to_string(&dark).unwrap(),
            "[terminal.colors]\nbackground = '#112233'"
        );
    }

    #[test]
    fn untouched_legacy_defaults_adopt_twine_without_overwriting_silica() {
        let directory = tempfile::tempdir().unwrap();
        let themes = directory.path().join("themes");
        fs::create_dir(&themes).unwrap();
        fs::write(themes.join("silica_light.toml"), SILICA_LIGHT).unwrap();
        fs::write(themes.join("silica_dark.toml"), SILICA_DARK).unwrap();
        let loaded = Config::load(&directory.path().join("config.toml"));
        assert_eq!(loaded.diagnostics, []);
        assert_eq!(loaded.config.terminal.palettes, TerminalPalettes::default());
        assert_eq!(
            fs::read_to_string(themes.join("silica_light.toml")).unwrap(),
            SILICA_LIGHT
        );
        assert_eq!(
            fs::read_to_string(themes.join("silica_dark.toml")).unwrap(),
            SILICA_DARK
        );
    }

    #[test]
    fn customized_legacy_defaults_are_carried_forward_only_on_first_load() {
        let directory = tempfile::tempdir().unwrap();
        let themes = directory.path().join("themes");
        fs::create_dir(&themes).unwrap();
        let customized = "[terminal.colors]\nbackground = '#112233'\n";
        fs::write(themes.join("silica_dark.toml"), customized).unwrap();
        let config = directory.path().join("config.toml");
        let first = Config::load(&config);
        assert_eq!(first.diagnostics, []);
        assert_eq!(
            first.config.terminal.palettes.dark.background.as_str(),
            "#112233"
        );
        assert_eq!(
            first.config.terminal.palettes.light,
            TerminalPalettes::default().light
        );
        assert_eq!(
            fs::read_to_string(themes.join("silica_dark.toml")).unwrap(),
            customized
        );
        assert_eq!(
            fs::read_to_string(themes.join("twine_dark.toml")).unwrap(),
            customized
        );

        fs::write(
            themes.join("silica_dark.toml"),
            "[terminal.colors]\nbackground = '#445566'\n",
        )
        .unwrap();
        let again = Config::load(&config);
        assert_eq!(again.diagnostics, []);
        assert_eq!(
            again.config.terminal.palettes,
            first.config.terminal.palettes
        );
        assert_eq!(
            fs::read_to_string(themes.join("twine_dark.toml")).unwrap(),
            customized
        );
    }

    #[test]
    fn unreadable_legacy_defaults_report_the_file_and_retry_after_repair() {
        let directory = tempfile::tempdir().unwrap();
        let themes = directory.path().join("themes");
        fs::create_dir(&themes).unwrap();
        let legacy = themes.join("silica_dark.toml");
        let current = themes.join("twine_dark.toml");
        fs::write(&legacy, [0xff, 0xfe]).unwrap();
        let config = directory.path().join("config.toml");
        let first = Config::load(&config);
        assert_eq!(first.config, Config::default());
        assert_eq!(first.diagnostics.len(), 1);
        assert_eq!(first.diagnostics[0].file, legacy);
        assert!(matches!(
            first.diagnostics[0].problem,
            ConfigProblem::File(_)
        ));
        assert!(!current.exists());
        assert_eq!(fs::read(&legacy).unwrap(), [0xff, 0xfe]);
        let repaired = "[terminal.colors]\nbackground = '#112233'\n";
        fs::write(&legacy, repaired).unwrap();
        let again = Config::load(&config);
        assert_eq!(again.diagnostics, []);
        assert_eq!(
            again.config.terminal.palettes.dark.background.as_str(),
            "#112233"
        );
        assert_eq!(fs::read_to_string(&current).unwrap(), repaired);
    }

    #[test]
    fn failed_unused_migration_does_not_block_a_selected_theme() {
        let directory = tempfile::tempdir().unwrap();
        let themes = directory.path().join("themes");
        fs::create_dir(&themes).unwrap();
        fs::write(themes.join("silica_dark.toml"), [0xff, 0xfe]).unwrap();
        let config = directory.path().join("config.toml");
        fs::write(&config, "[theme]\ndark = 'nord'\n").unwrap();
        let loaded = Config::load(&config);
        assert_eq!(loaded.diagnostics, []);
        assert_eq!(
            loaded.config.terminal.palettes.dark.background.as_str(),
            "#2e3440"
        );
        assert!(!themes.join("twine_dark.toml").exists());
    }

    #[test]
    fn existing_twine_defaults_take_precedence_over_legacy_customizations() {
        let directory = tempfile::tempdir().unwrap();
        let themes = directory.path().join("themes");
        fs::create_dir(&themes).unwrap();
        let current = "[terminal.colors]\nbackground = '#778899'\n";
        fs::write(themes.join("twine_dark.toml"), current).unwrap();
        fs::write(
            themes.join("silica_dark.toml"),
            "[terminal.colors]\nbackground = '#112233'\n",
        )
        .unwrap();
        let loaded = Config::load(&directory.path().join("config.toml"));
        assert_eq!(loaded.diagnostics, []);
        assert_eq!(
            loaded.config.terminal.palettes.dark.background.as_str(),
            "#778899"
        );
        assert_eq!(
            fs::read_to_string(themes.join("twine_dark.toml")).unwrap(),
            current
        );
    }

    #[test]
    fn imported_colors_and_inline_overrides_apply_to_both_appearances() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        let theme = directory.path().join("custom.toml");
        fs::write(&theme, "[terminal.colors]\nbackground = '#123456'\nforeground = '#ABCDEF'\ncursor = '#abcdef'\nselection = '#654321'\n").unwrap();
        for import in ["custom.toml".to_owned(), theme.display().to_string()] {
            fs::write(
                &config,
                format!("import = '{import}'\n[terminal.colors]\nforeground = '#ffffff'\n"),
            )
            .unwrap();
            let loaded = Config::load(&config);
            assert_eq!(loaded.diagnostics, []);
            for palette in [
                &loaded.config.terminal.palettes.light,
                &loaded.config.terminal.palettes.dark,
            ] {
                assert_eq!(palette.background.as_str(), "#123456");
                assert_eq!(palette.foreground.as_str(), "#ffffff");
                assert_eq!(palette.cursor.as_str(), "#abcdef");
                assert_eq!(palette.selection.as_str(), "#654321");
            }
        }
    }

    #[test]
    fn full_palette_import_pins_the_same_colors_for_light_and_dark() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        fs::write(&config, "import = 'themes/twine_dark.toml'\n").unwrap();
        let loaded = Config::load(&config);
        assert_eq!(loaded.diagnostics, []);
        assert_eq!(
            loaded.config.terminal.palettes.light,
            TerminalPalettes::default().dark
        );
        assert_eq!(
            loaded.config.terminal.palettes.light,
            loaded.config.terminal.palettes.dark
        );
    }

    #[test]
    fn invalid_imports_report_the_theme_file_and_fall_back_without_overwriting() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        fs::write(&config, "import = 'custom.toml'\nterminal.font_size = 18\n").unwrap();
        let theme = directory.path().join("custom.toml");
        let missing = Config::load(&config);
        assert_eq!(missing.config, Config::default());
        assert_eq!(missing.diagnostics[0].file, theme);
        assert!(!theme.exists());
        for (source, problem) in [
            (
                "[terminal.colors]\nforeground = 'secret'",
                ConfigProblem::InvalidValue,
            ),
            (
                "[terminal.colors]\nforeground = @",
                ConfigProblem::InvalidToml,
            ),
        ] {
            fs::write(&theme, source).unwrap();
            let loaded = Config::load(&config);
            assert_eq!(loaded.config, Config::default());
            assert_eq!(loaded.diagnostics[0].file, theme);
            assert_eq!(loaded.diagnostics[0].line, 2);
            assert_eq!(loaded.diagnostics[0].key, "terminal.colors.foreground");
            assert_eq!(loaded.diagnostics[0].problem, problem);
            assert!(!loaded.diagnostics[0].to_string().contains("secret"));
            assert_eq!(fs::read_to_string(&theme).unwrap(), source);
        }
    }

    #[test]
    fn invalid_inline_colors_and_ansi_lengths_report_the_key() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        for value in ["'secret'", "'#123'", "'#gg0000'", "42", "'#12345678'"] {
            fs::write(
                &config,
                format!("[terminal.colors]\nbackground = {value}\n"),
            )
            .unwrap();
            let loaded = Config::load(&config);
            assert_eq!(loaded.config, Config::default());
            assert_eq!(loaded.diagnostics[0].key, "terminal.colors.background");
            assert_eq!(loaded.diagnostics[0].line, 2);
        }
        for count in [0, 15, 17] {
            fs::write(
                &config,
                format!(
                    "terminal.colors.ansi = [{}]",
                    vec!["'#112233'"; count].join(",")
                ),
            )
            .unwrap();
            let loaded = Config::load(&config);
            assert_eq!(loaded.config, Config::default());
            assert_eq!(loaded.diagnostics[0].problem, ConfigProblem::InvalidValue);
        }
    }
}
