use std::path::{Path, PathBuf};

use thiserror::Error;
use toml::de::{DeTable, DeValue};

#[derive(Clone, Debug, Eq, Error, PartialEq)]
#[error("{file}:{line}: {key}: {problem}", file = .file.display())]
pub struct ConfigDiagnostic {
    pub file: PathBuf,
    pub line: usize,
    pub key: String,
    pub problem: ConfigProblem,
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum ConfigProblem {
    #[error("invalid TOML syntax; using defaults")]
    InvalidToml,
    #[error("invalid setting value or type; using defaults")]
    InvalidValue,
    #[error("configuration import cycle; using defaults")]
    ImportCycle,
    #[error("configuration import limit exceeded; using defaults")]
    ImportLimit,
    #[error("unknown key; ignored")]
    UnknownKey,
    #[error("{0}")]
    File(String),
}

impl ConfigDiagnostic {
    pub(super) fn at(
        path: &Path,
        source: &str,
        offset: usize,
        key: String,
        problem: ConfigProblem,
    ) -> Self {
        Self {
            file: path.to_owned(),
            line: source.as_bytes()[..offset.min(source.len())]
                .split(|&byte| byte == b'\n')
                .count(),
            key,
            problem,
        }
    }
}

pub(super) struct Location {
    pub segments: Vec<String>,
    pub start: usize,
    end: usize,
}

pub(super) fn locations(table: &DeTable<'_>) -> Vec<Location> {
    let mut locations = Vec::new();
    collect_locations(table, &[], &mut locations);
    locations
}

fn collect_locations(table: &DeTable<'_>, prefix: &[String], locations: &mut Vec<Location>) {
    for (key, value) in table {
        let mut path = prefix.to_vec();
        path.push(key.get_ref().to_string());
        locations.push(Location {
            segments: path.clone(),
            start: key.span().start,
            end: value.span().end,
        });
        if let DeValue::Table(table) = value.get_ref() {
            collect_locations(table, &path, locations);
        }
    }
}

pub(super) fn key_at(locations: &[Location], source: &str, error: &toml::de::Error) -> String {
    let span = error.span().unwrap_or(0..0);
    let offset = span.start;
    // Duplicate assignments are omitted from the recovered tree. The parser's error span
    // identifies the key; parse that token and recover its parent only when unambiguous.
    if error.message().starts_with("duplicate key")
        && let Some(token) = source.get(span)
        && let Ok(key) = DeTable::parse(&format!("{token} = 0"))
        && let Some(duplicate) = self::locations(key.get_ref()).last()
    {
        let mut originals = locations.iter().filter(|location| {
            location.start < offset && location.segments.ends_with(&duplicate.segments)
        });
        if let Some(original) = originals.next()
            && originals.next().is_none()
        {
            return display_key(&original.segments);
        }
        return display_key(&duplicate.segments);
    }
    // Recovery retains spans for many malformed values. Prefer the innermost containing key;
    // an unrecognizable document/header has no trustworthy key to report.
    locations
        .iter()
        .filter(|location| location.start <= offset && offset <= location.end)
        .max_by_key(|location| location.start)
        .map_or_else(
            || "<document>".to_owned(),
            |location| display_key(&location.segments),
        )
}

pub(super) fn ignored_segments(path: &serde_ignored::Path<'_>) -> Vec<String> {
    match path {
        serde_ignored::Path::Root => Vec::new(),
        serde_ignored::Path::Map { parent, key } => {
            let mut segments = ignored_segments(parent);
            segments.push(key.clone());
            segments
        }
        serde_ignored::Path::Seq { parent, index } => {
            let mut segments = ignored_segments(parent);
            segments.push(index.to_string());
            segments
        }
        serde_ignored::Path::Some { parent }
        | serde_ignored::Path::NewtypeStruct { parent }
        | serde_ignored::Path::NewtypeVariant { parent } => ignored_segments(parent),
    }
}

pub(super) fn display_key(segments: &[String]) -> String {
    segments
        .iter()
        .map(|segment| {
            if !segment.is_empty()
                && segment
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
            {
                segment.clone()
            } else {
                format!("{segment:?}")
            }
        })
        .collect::<Vec<_>>()
        .join(".")
}
