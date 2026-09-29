//! User configuration. Serde defaults are the schema for both loading and the starter file.

use std::fs;
use std::io::{self, Write};
use std::path::Path;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use toml::de::DeTable;

mod diagnostics;

pub use diagnostics::{ConfigDiagnostic, ConfigProblem};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default)]
pub struct Config {
    pub appearance: Appearance,
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
    /// Loads the fixed user config path, reporting problems without preventing startup.
    #[must_use]
    pub fn load_user() -> Self {
        let Some(home) = std::env::home_dir().filter(|home| home.is_absolute()) else {
            tracing::error!(
                "cannot find home directory for ~/.config/twine/config.toml; using defaults"
            );
            return Self::default();
        };
        let loaded = Self::load(&home.join(".config/twine/config.toml"));
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
        match read_or_create(path) {
            Ok(source) => Self::parse(path, &source),
            Err(error) => LoadedConfig {
                diagnostics: vec![ConfigDiagnostic {
                    file: path.to_owned(),
                    line: 1,
                    key: "<document>".to_owned(),
                    problem: ConfigProblem::File(error.to_string()),
                }],
                ..LoadedConfig::default()
            },
        }
    }

    fn parse(path: &Path, source: &str) -> LoadedConfig {
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
            return LoadedConfig {
                config: Self::default(),
                diagnostics,
            };
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
                Self::default()
            }
        };
        LoadedConfig {
            config,
            diagnostics,
        }
    }
}

fn read_or_create(path: &Path) -> Result<String, ConfigFileError> {
    match fs::read_to_string(path) {
        Ok(source) => return Ok(source),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(ConfigFileError::Read(error)),
    }

    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent).map_err(ConfigFileError::Create)?;
    let defaults = toml::to_string_pretty(&Config::default())?;
    let mut source = String::from(
        "# Twine configuration. Uncomment settings to override their defaults.\n\
         # Settings are loaded at startup; they do not change app behavior yet.\n\
         # appearance.color_scheme accepts \"system\", \"light\", or \"dark\".\n\n",
    );
    for line in defaults.lines() {
        if line.starts_with('[') || line.is_empty() {
            source.push_str(line);
        } else {
            source.push_str("# ");
            source.push_str(line);
        }
        source.push('\n');
    }

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
        Ok(_) => Ok(source),
        Err(error) if error.error.kind() == io::ErrorKind::AlreadyExists => {
            fs::read_to_string(path).map_err(ConfigFileError::Read)
        }
        Err(error) => Err(ConfigFileError::Create(error.error)),
    }
}

#[derive(Debug, Error)]
enum ConfigFileError {
    #[error("cannot read config ({0}); using defaults")]
    Read(io::Error),
    #[error("cannot create default config ({0}); using defaults")]
    Create(io::Error),
    #[error("cannot serialize default config; using defaults")]
    Serialize(#[from] toml::ser::Error),
}

#[cfg(test)]
mod tests;
