//! Terminal palettes are resolved in core so every terminal consumer uses the same colors.

use std::fs;
use std::io;
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::{ConfigDiagnostic, file_diagnostic, imports, write_default};

mod bundled;

const SILICA_LIGHT: &str = include_str!("themes/silica_light.toml");
const SILICA_DARK: &str = include_str!("themes/silica_dark.toml");
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
            light: embedded_palette(SILICA_LIGHT),
            dark: embedded_palette(SILICA_DARK),
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

pub(super) fn default_color_settings() -> &'static str {
    &SILICA_DARK[SILICA_DARK
        .find("cursor =")
        .expect("embedded cursor setting")..]
}

pub(super) fn load(config_path: &Path) -> (TerminalPalettes, Vec<ConfigDiagnostic>) {
    let directory = config_path.parent().unwrap_or(Path::new("."));
    bundled::publish(directory);
    let mut palettes = TerminalPalettes::default();
    let mut diagnostics = Vec::new();
    let mut files = Vec::new();
    // Publish both defaults before resolving imports, so either theme can import the other.
    for (name, source) in [
        ("silica_light.toml", SILICA_LIGHT),
        ("silica_dark.toml", SILICA_DARK),
    ] {
        let path = directory.join("themes").join(name);
        let result = match fs::read_to_string(&path) {
            Ok(source) => Ok(source),
            Err(error) if error.kind() == io::ErrorKind::NotFound => write_default(&path, source),
            Err(error) => Err(super::ConfigFileError::Read(error)),
        };
        match result {
            Ok(source) => files.push((path, source)),
            Err(error) => diagnostics.push(file_diagnostic(&path, &error)),
        }
    }
    for (path, source) in files {
        let loaded = imports::load(&path, &source);
        diagnostics.extend(loaded.diagnostics);
        let palette = if path
            .file_name()
            .is_some_and(|name| name == "silica_light.toml")
        {
            &mut palettes.light
        } else {
            &mut palettes.dark
        };
        palette.apply(&loaded.config.terminal.colors);
    }
    (palettes, diagnostics)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, ConfigProblem};

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
        let dark = directory.path().join("themes/silica_dark.toml");
        assert_eq!(fs::read_to_string(&dark).unwrap(), SILICA_DARK);
        assert_eq!(
            fs::read_to_string(directory.path().join("themes/silica_light.toml")).unwrap(),
            SILICA_LIGHT
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
        fs::write(&config, "import = 'themes/silica_dark.toml'\n").unwrap();
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
