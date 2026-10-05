//! User configuration. Serde defaults are the schema for both loading and the starter file.

use std::ffi::OsStr;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;
use toml::de::DeTable;

mod diagnostics;
mod editing;
mod imports;
mod themes;

pub use diagnostics::{ConfigDiagnostic, ConfigProblem};
pub use editing::{ConfigEditError, read_user_file, save_user_file};
pub use themes::{HexColor, TerminalColors, TerminalPalette, TerminalPalettes};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct Config {
    pub appearance: Appearance,
    pub terminal: TerminalConfig,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct TerminalConfig {
    /// An installed font family. Empty selects the platform's system monospace font.
    pub font_family: String,
    pub font_size: FontSize,
    pub colors: TerminalColors,
    /// Resolved colors for consumers; never accepted as a user setting.
    #[serde(skip_deserializing)]
    pub palettes: TerminalPalettes,
}

/// A terminal font size in points, limited to 6 through 72.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(transparent)]
pub struct FontSize(f64);

// Deserialization and the default only construct finite, positive values, so equality is reflexive.
impl Eq for FontSize {}

impl Default for FontSize {
    fn default() -> Self {
        Self(13.0)
    }
}

impl FontSize {
    #[must_use]
    pub const fn points(self) -> f64 {
        self.0
    }
}

impl<'de> Deserialize<'de> for FontSize {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let points = f64::deserialize(deserializer)?;
        if !(6.0..=72.0).contains(&points) {
            return Err(serde::de::Error::custom(
                "font size must be between 6 and 72 points",
            ));
        }
        Ok(Self(points))
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct Appearance {
    pub color_scheme: ColorScheme,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ColorScheme {
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Debug, Default)]
pub struct LoadedConfig {
    pub config: Config,
    pub diagnostics: Vec<ConfigDiagnostic>,
}

impl Config {
    /// The same user config path used by loading and the settings editor.
    #[must_use]
    pub fn user_path() -> Option<PathBuf> {
        user_config_path(
            std::env::var_os("XDG_CONFIG_HOME").as_deref(),
            std::env::home_dir().as_deref(),
        )
    }

    /// Loads `$XDG_CONFIG_HOME/twine/config.toml`, falling back to `~/.config/twine`.
    #[must_use]
    pub fn load_user() -> Self {
        let Some(path) = Self::user_path() else {
            tracing::error!("cannot find user config directory; using defaults");
            return Self::default();
        };
        let loaded = Self::load(&path);
        for diagnostic in &loaded.diagnostics {
            if diagnostic.problem == ConfigProblem::UnknownKey {
                tracing::warn!(%diagnostic, "configuration warning");
            } else {
                tracing::error!(%diagnostic, "configuration error");
            }
        }
        loaded.config
    }

    /// Loads a file, creating a commented default file if missing. Existing files are never
    /// overwritten. Any read, syntax, or validation failure returns the complete defaults.
    #[must_use]
    pub fn load(path: &Path) -> LoadedConfig {
        let source = match read_or_create(path) {
            Ok(source) => source,
            Err(error) => {
                return LoadedConfig {
                    diagnostics: vec![file_diagnostic(path, &error)],
                    ..LoadedConfig::default()
                };
            }
        };
        Self::load_source(path, &source)
    }

    /// Resolves a draft using the same imports, themes, and validation as a saved config.
    pub(crate) fn load_source(path: &Path, source: &str) -> LoadedConfig {
        let (mut palettes, diagnostics) = themes::load(path);
        let mut loaded = imports::load(path, source);
        loaded.diagnostics.extend(diagnostics);
        if loaded
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.problem != ConfigProblem::UnknownKey)
        {
            loaded.config = Self::default();
        } else {
            palettes.apply(&loaded.config.terminal.colors);
            loaded.config.terminal.palettes = palettes;
        }
        loaded
    }

    fn parse(path: &Path, source: &str) -> LoadedConfig {
        let (config, mut diagnostics) = parse_document(path, source);
        // The document loader handles this reserved, top-level directive.
        diagnostics.retain(|diagnostic| {
            diagnostic.key != "import" || diagnostic.problem != ConfigProblem::UnknownKey
        });
        LoadedConfig {
            config,
            diagnostics,
        }
    }
}

fn user_config_path(xdg: Option<&OsStr>, home: Option<&Path>) -> Option<PathBuf> {
    xdg.map(Path::new)
        .filter(|path| path.is_absolute())
        .map(|path| path.join("twine/config.toml"))
        .or_else(|| {
            home.filter(|path| path.is_absolute())
                .map(|home| home.join(".config/twine/config.toml"))
        })
}

fn file_diagnostic(path: &Path, error: &impl std::fmt::Display) -> ConfigDiagnostic {
    ConfigDiagnostic {
        file: path.to_owned(),
        line: 1,
        key: "<document>".to_owned(),
        problem: ConfigProblem::File(error.to_string()),
    }
}

fn parse_document<T: serde::de::DeserializeOwned + Default>(
    path: &Path,
    source: &str,
) -> (T, Vec<ConfigDiagnostic>) {
    let (table, errors) = DeTable::parse_recoverable(source);
    let locations = diagnostics::locations(table.get_ref());
    let mut diagnostics = Vec::new();
    for error in errors {
        let offset = error.span().map_or(0, |span| span.start);
        diagnostics.push(ConfigDiagnostic::at(
            path,
            source,
            offset,
            diagnostics::key_at(&locations, source, &error),
            ConfigProblem::InvalidToml,
        ));
    }
    if !diagnostics.is_empty() {
        return (T::default(), diagnostics);
    }

    let mut track = serde_path_to_error::Track::new();
    let deserializer =
        serde_path_to_error::Deserializer::new(toml::Deserializer::from(table), &mut track);
    let result = serde_ignored::deserialize(deserializer, |key| {
        let segments = diagnostics::ignored_segments(&key);
        let offset = locations
            .iter()
            .find(|location| location.segments == segments)
            .map_or(0, |location| location.start);
        diagnostics.push(ConfigDiagnostic::at(
            path,
            source,
            offset,
            diagnostics::display_key(&segments),
            ConfigProblem::UnknownKey,
        ));
    });
    let config = match result {
        Ok(config) => config,
        Err(error) => {
            diagnostics.push(ConfigDiagnostic::at(
                path,
                source,
                error.span().map_or(0, |span| span.start),
                track.path().to_string(),
                ConfigProblem::InvalidValue,
            ));
            T::default()
        }
    };
    (config, diagnostics)
}

fn read_or_create(path: &Path) -> Result<String, ConfigFileError> {
    match fs::read_to_string(path) {
        Ok(source) => return Ok(source),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(ConfigFileError::Read(error)),
    }

    write_default(path, &default_source()?)
}

fn default_source() -> Result<String, ConfigFileError> {
    let mut defaults = toml::Value::try_from(Config::default())?;
    defaults["terminal"]
        .as_table_mut()
        .expect("terminal is a table")
        .remove("palettes");
    let defaults = toml::to_string_pretty(&defaults)?;
    let mut source = String::from(
        "# Twine configuration. Uncomment settings to override their defaults.\n\
         # Settings saved in Twine apply immediately.\n\
         # appearance.color_scheme accepts \"system\", \"light\", or \"dark\".\n\
         # terminal.font_family selects an installed monospace family (for example, \"JetBrains Mono\").\n\
         # An empty, unavailable, or proportional family uses system monospace.\n\
         # terminal.font_size accepts 6 through 72 points, including fractional sizes.\n\
         # Top-level import accepts a TOML file path or a list of paths.\n\
         # Later imports override earlier imports; settings in this file override all imports.\n\
         # Imported files use the same tables as this config; colors use #RRGGBB strings.\n\
         # Default themes/silica_light.toml and silica_dark.toml follow macOS appearance.\n\n\
         # import = [\"themes/silica_dark.toml\"]\n\n",
    );
    for line in defaults.lines() {
        if line.starts_with('[') || line.is_empty() {
            source.push_str(line);
        } else {
            source.push_str("# ");
            source.push_str(line);
        }
        source.push('\n');
        if line == "[terminal.colors]" {
            source.push_str("# background = \"#0c1013\"\n# foreground = \"#e5e1cf\"\n");
            for line in themes::default_color_settings().lines() {
                source.push_str("# ");
                source.push_str(line);
                source.push('\n');
            }
        }
    }

    Ok(source)
}

fn write_default(path: &Path, source: &str) -> Result<String, ConfigFileError> {
    if publish_default(path, source)? {
        Ok(source.to_owned())
    } else {
        fs::read_to_string(path).map_err(ConfigFileError::Read)
    }
}

fn publish_default(path: &Path, source: &str) -> Result<bool, ConfigFileError> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent).map_err(ConfigFileError::Create)?;
    // Publish a complete file atomically without replacing a config created by another launch.
    let mut temporary = tempfile::NamedTempFile::new_in(parent).map_err(ConfigFileError::Create)?;
    temporary
        .write_all(source.as_bytes())
        .map_err(ConfigFileError::Create)?;
    temporary
        .as_file()
        .sync_all()
        .map_err(ConfigFileError::Create)?;
    match temporary.persist_noclobber(path) {
        Ok(_) => Ok(true),
        Err(error) if error.error.kind() == io::ErrorKind::AlreadyExists => Ok(false),
        Err(error) => Err(ConfigFileError::Create(error.error)),
    }
}

#[derive(Debug, Error)]
enum ConfigFileError {
    #[error("cannot read file ({0}); using defaults")]
    Read(io::Error),
    #[error("cannot create default file ({0}); using defaults")]
    Create(io::Error),
    #[error("cannot serialize default config; using defaults")]
    Serialize(#[from] toml::ser::Error),
}

#[cfg(test)]
mod tests {
    use super::*;

    const PATH: &str = "/test/config.toml";

    #[test]
    fn xdg_config_path_uses_absolute_xdg_or_home_fallback() {
        let home = Some(Path::new("/home/user"));
        assert_eq!(
            user_config_path(Some(OsStr::new("/xdg")), home),
            Some(PathBuf::from("/xdg/twine/config.toml"))
        );
        for xdg in [None, Some(OsStr::new("")), Some(OsStr::new("relative"))] {
            assert_eq!(
                user_config_path(xdg, home),
                Some(PathBuf::from("/home/user/.config/twine/config.toml"))
            );
        }
        assert_eq!(
            user_config_path(Some(OsStr::new("/xdg")), None),
            Some(PathBuf::from("/xdg/twine/config.toml"))
        );
        assert_eq!(user_config_path(None, None), None);
    }

    #[test]
    fn absent_fields_use_defaults() {
        for source in ["", "# empty\n", "[appearance]\n", "[terminal]\n"] {
            let loaded = Config::parse(Path::new(PATH), source);
            assert_eq!(loaded.config, Config::default());
            assert_eq!(loaded.diagnostics, []);
        }
    }

    #[test]
    fn terminal_settings_accept_fractional_sizes_and_toml_key_forms() {
        for source in [
            "[terminal]\nfont_family = 'JetBrains Mono'\nfont_size = 15.5\n",
            "terminal.font_family = 'JetBrains Mono'\nterminal.font_size = 15.5\n",
            "terminal = { font_family = 'JetBrains Mono', font_size = 15.5 }\n",
        ] {
            let loaded = Config::parse(Path::new(PATH), source);
            assert_eq!(loaded.config.terminal.font_family, "JetBrains Mono");
            assert_eq!(loaded.config.terminal.font_size, FontSize(15.5));
            assert!(loaded.diagnostics.is_empty(), "{:?}", loaded.diagnostics);
        }
        for size in ["6", "13", "72", "6.0", "72.0"] {
            let loaded = Config::parse(Path::new(PATH), &format!("terminal.font_size = {size}\n"));
            assert_eq!(
                loaded.config.terminal.font_size,
                FontSize(size.parse::<f64>().unwrap())
            );
            assert_eq!(loaded.diagnostics, []);
        }
    }

    #[test]
    fn omitted_terminal_settings_preserve_the_other_setting() {
        let family = Config::parse(Path::new(PATH), "terminal.font_family = 'Menlo'\n");
        assert_eq!(family.config.terminal.font_family, "Menlo");
        assert_eq!(family.config.terminal.font_size, FontSize::default());
        let size = Config::parse(Path::new(PATH), "terminal.font_size = 18\n");
        assert_eq!(size.config.terminal.font_family, "");
        assert_eq!(size.config.terminal.font_size, FontSize(18.0));
        assert_eq!(family.diagnostics, []);
        assert_eq!(size.diagnostics, []);
    }

    #[test]
    fn invalid_terminal_values_report_the_setting_and_use_complete_defaults() {
        for (key, values) in [
            ("font_family", vec!["42", "true", "[]", "{}"]),
            (
                "font_size",
                vec![
                    "0", "-13", "5.99", "72.01", "nan", "inf", "-inf", "'secret'", "true", "[]",
                    "{}",
                ],
            ),
        ] {
            for value in values {
                let source =
                    format!("[appearance]\ncolor_scheme = 'dark'\n[terminal]\n{key} = {value}\n");
                let loaded = Config::parse(Path::new(PATH), &source);
                assert_eq!(loaded.config, Config::default());
                assert_eq!(loaded.diagnostics.len(), 1);
                let diagnostic = &loaded.diagnostics[0];
                assert_eq!(diagnostic.line, 4, "{source}");
                assert_eq!(diagnostic.key, format!("terminal.{key}"));
                assert_eq!(diagnostic.problem, ConfigProblem::InvalidValue);
                assert!(!diagnostic.to_string().contains("secret"));
            }
        }
    }

    #[test]
    fn accepts_all_color_schemes_and_toml_key_forms() {
        for (value, expected) in [
            ("system", ColorScheme::System),
            ("light", ColorScheme::Light),
            ("dark", ColorScheme::Dark),
        ] {
            for source in [
                format!("[appearance]\ncolor_scheme = '{value}'\n"),
                format!("appearance.color_scheme = '{value}'\n"),
                format!("appearance = {{ color_scheme = '{value}' }}\n"),
                format!("['appearance']\n'color_scheme' = '{value}'\n"),
            ] {
                let loaded = Config::parse(Path::new(PATH), &source);
                assert_eq!(loaded.config.appearance.color_scheme, expected);
                assert!(loaded.diagnostics.is_empty(), "{:?}", loaded.diagnostics);
            }
        }
    }

    #[test]
    fn invalid_values_report_file_line_and_key_without_leaking_values() {
        for value in ["'secret-invalid-value'", "42", "true", "[]", "{}"] {
            let source = format!("# comment\n[appearance]\ncolor_scheme = {value}\n");
            let loaded = Config::parse(Path::new(PATH), &source);
            assert_eq!(loaded.config, Config::default());
            assert_eq!(loaded.diagnostics.len(), 1);
            let diagnostic = &loaded.diagnostics[0];
            assert_eq!(diagnostic.file, Path::new(PATH));
            assert_eq!(diagnostic.line, 3);
            assert_eq!(diagnostic.key, "appearance.color_scheme");
            assert_eq!(diagnostic.problem, ConfigProblem::InvalidValue);
            assert!(!diagnostic.to_string().contains("secret-invalid-value"));
        }
    }

    #[test]
    fn invalid_table_type_falls_back() {
        let loaded = Config::parse(Path::new(PATH), "appearance = 42\n");
        assert_eq!(loaded.config, Config::default());
        assert_eq!(loaded.diagnostics[0].key, "appearance");
        assert_eq!(loaded.diagnostics[0].line, 1);
    }

    #[test]
    fn malformed_toml_reports_location_and_uses_defaults() {
        for value in ["@", "'unterminated", "[1,", ""] {
            let source = format!("[appearance]\ncolor_scheme = {value}\n");
            let loaded = Config::parse(Path::new(PATH), &source);
            assert_eq!(loaded.config, Config::default());
            assert_ne!(loaded.diagnostics, []);
            let diagnostic = &loaded.diagnostics[0];
            assert_eq!(diagnostic.file, Path::new(PATH));
            assert!(diagnostic.line >= 2);
            assert_eq!(diagnostic.key, "appearance.color_scheme", "{source}");
            assert_eq!(diagnostic.problem, ConfigProblem::InvalidToml);
        }
    }

    #[test]
    fn unknown_keys_warn_and_preserve_valid_values() {
        let loaded = Config::parse(
            Path::new(PATH),
            "extra = 'secret'\n[appearance]\ncolor_scheme = 'dark'\ntypo = true\n[future]\nsetting = 42\n",
        );
        assert_eq!(loaded.config.appearance.color_scheme, ColorScheme::Dark);
        let warnings: Vec<_> = loaded
            .diagnostics
            .iter()
            .map(|diagnostic| {
                assert_eq!(diagnostic.problem, ConfigProblem::UnknownKey);
                assert!(!diagnostic.to_string().contains("secret"));
                (diagnostic.key.as_str(), diagnostic.line)
            })
            .collect();
        assert!(warnings.contains(&("extra", 1)));
        assert!(warnings.contains(&("appearance.typo", 4)));
        assert!(warnings.contains(&("future", 5)));
        assert_eq!(warnings.len(), 3);
    }

    #[test]
    fn duplicate_keys_report_the_duplicate_location() {
        for key in ["color_scheme", "'color_scheme'", "\"color_scheme\""] {
            let source = format!("[appearance]\ncolor_scheme = 'light'\n{key} = 'secret'\n");
            let loaded = Config::parse(Path::new(PATH), &source);
            assert_eq!(loaded.config, Config::default());
            assert_eq!(loaded.diagnostics[0].line, 3);
            assert_eq!(loaded.diagnostics[0].key, "appearance.color_scheme");
            assert_eq!(loaded.diagnostics[0].problem, ConfigProblem::InvalidToml);
            assert!(!loaded.diagnostics[0].to_string().contains("secret"));
        }
    }

    #[test]
    fn quoted_keys_with_dots_do_not_collide_with_nested_paths() {
        let loaded = Config::parse(
            Path::new(PATH),
            "\"appearance.typo\" = 1\n[appearance]\ntypo = 2\n",
        );
        assert_eq!(loaded.diagnostics.len(), 2);
        assert!(
            loaded
                .diagnostics
                .iter()
                .any(|diagnostic| diagnostic.key == "\"appearance.typo\"" && diagnostic.line == 1)
        );
        assert!(
            loaded
                .diagnostics
                .iter()
                .any(|diagnostic| diagnostic.key == "appearance.typo" && diagnostic.line == 3)
        );
    }

    #[test]
    fn duplicate_leaf_does_not_claim_an_ambiguous_parent() {
        let loaded = Config::parse(
            Path::new(PATH),
            "appearance.color_scheme = 'light'\nfuture.color_scheme = 'system'\nappearance.color_scheme = 'dark'\n",
        );
        assert_eq!(loaded.config, Config::default());
        assert_eq!(loaded.diagnostics[0].line, 3);
        assert_eq!(loaded.diagnostics[0].key, "color_scheme");
    }

    #[test]
    fn first_load_creates_commented_defaults_and_preserves_edits() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("twine/config.toml");
        let loaded = Config::load(&path);
        assert_eq!(loaded.config, Config::default());
        assert_eq!(loaded.diagnostics, []);
        let source = fs::read_to_string(&path).unwrap();
        assert!(source.contains("[appearance]"));
        assert!(source.contains("# color_scheme = \"system\""));
        assert!(source.contains("[terminal]"));
        assert!(source.contains("# font_family = \"\""));
        assert!(source.contains("# font_size = 13.0"));
        assert_eq!(Config::parse(&path, &source).config, Config::default());
        let uncommented = source
            .lines()
            .filter_map(|line| {
                line.strip_prefix("# ")
                    .filter(|line| line.contains(" = "))
                    .or_else(|| line.starts_with('[').then_some(line))
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert_eq!(
            Config::parse(&path, &uncommented).config.terminal.font_size,
            FontSize::default()
        );
        assert_eq!(Config::parse(&path, &uncommented).diagnostics, []);

        let edited = "[appearance]\ncolor_scheme = 'light'\n";
        fs::write(&path, edited).unwrap();
        assert_eq!(
            Config::load(&path).config.appearance.color_scheme,
            ColorScheme::Light
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), edited);

        fs::write(&path, "invalid = @").unwrap();
        assert_eq!(Config::load(&path).config, Config::default());
        assert_eq!(fs::read_to_string(&path).unwrap(), "invalid = @");
    }

    #[test]
    fn io_errors_and_invalid_utf8_fall_back_without_overwriting() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        fs::write(&path, [0xff, 0xfe]).unwrap();
        for path in [&path, &path.join("config.toml"), directory.path()] {
            let loaded = Config::load(path);
            assert_eq!(loaded.config, Config::default());
            assert!(matches!(
                loaded.diagnostics[0].problem,
                ConfigProblem::File(_)
            ));
        }
        assert_eq!(fs::read(&path).unwrap(), [0xff, 0xfe]);
    }

    #[test]
    fn unreadable_config_does_not_publish_sibling_theme_files() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        fs::create_dir(&path).unwrap();
        let loaded = Config::load(&path);
        assert_eq!(loaded.config, Config::default());
        assert!(matches!(
            loaded.diagnostics[0].problem,
            ConfigProblem::File(_)
        ));
        assert!(!directory.path().join("themes").exists());
    }

    #[test]
    fn concurrent_first_loads_publish_one_complete_file() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        std::thread::scope(|scope| {
            for _ in 0..8 {
                scope.spawn(|| {
                    let loaded = Config::load(&path);
                    assert_eq!(loaded.config, Config::default());
                    assert_eq!(loaded.diagnostics, []);
                });
            }
        });
        assert!(fs::read_to_string(path).unwrap().contains("# color_scheme"));
    }
}
