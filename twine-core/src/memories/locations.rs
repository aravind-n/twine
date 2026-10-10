use super::MemoryRequest;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use unicode_normalization::UnicodeNormalization;

pub(super) struct Locations {
    pub home: PathBuf,
    pub codex: PathBuf,
    pub sqlite: PathBuf,
    pub claude: PathBuf,
    pub folder: Option<PathBuf>,
    pub codex_config: toml::Value,
    pub claude_settings: Value,
    pub example: bool,
}

impl Locations {
    pub fn live(request: &MemoryRequest) -> Self {
        let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
        let codex =
            std::env::var_os("CODEX_HOME").map_or_else(|| home.join(".codex"), PathBuf::from);
        let claude = std::env::var_os("CLAUDE_CONFIG_DIR")
            .map_or_else(|| home.join(".claude"), PathBuf::from);
        let config = read_toml(&codex.join("config.toml"));
        let working = request
            .folder
            .clone()
            .or_else(|| std::env::current_dir().ok())
            .unwrap_or_else(|| home.clone());
        let sqlite_env = std::env::var("CODEX_SQLITE_HOME").ok();
        let sqlite = sqlite_location(&config, sqlite_env.as_deref(), &codex, &home, &working);
        let folder = request
            .folder
            .as_ref()
            .map(|p| p.canonicalize().unwrap_or_else(|_| p.clone()));
        let mut settings = read_json(&claude.join("settings.json"));
        if let Some(folder) = &folder {
            for name in ["settings.json", "settings.local.json"] {
                if let Some(object) = read_json(&folder.join(".claude").join(name)).as_object()
                    && let Some(target) = settings.as_object_mut()
                {
                    for (key, value) in object {
                        target.insert(key.clone(), value.clone());
                    }
                }
            }
        }
        Self {
            home,
            codex,
            sqlite,
            claude,
            folder,
            codex_config: config,
            claude_settings: settings,
            example: false,
        }
    }

    pub fn examples(root: &Path) -> Self {
        let home = root.join("home");
        let codex = home.join(".codex");
        Self {
            sqlite: codex.clone(),
            codex_config: read_toml(&codex.join("config.toml")),
            claude_settings: read_json(&home.join(".claude/settings.json")),
            claude: home.join(".claude"),
            folder: Some(root.join("folder")),
            home,
            codex,
            example: true,
        }
    }

    pub fn config_summary(&self) -> Value {
        let memory = self.codex_config.get("memories");
        let boolean = |key: &str, default: bool| {
            memory
                .and_then(|v| v.get(key))
                .and_then(toml::Value::as_bool)
                .unwrap_or(default)
        };
        json!({
            "source": self.codex.join("config.toml"),
            "features.memories": self.codex_config.get("features").and_then(|v| v.get("memories")).and_then(toml::Value::as_bool).unwrap_or(false),
            "memories.version": memory.and_then(|v| v.get("version")).and_then(toml::Value::as_str).unwrap_or("v1"),
            "memories.dual_write": boolean("dual_write", false),
            "memories.use_memories": boolean("use_memories", true),
            "memories.generate_memories": boolean("generate_memories", true),
            "memories.disable_on_external_context": boolean("disable_on_external_context", boolean("no_memories_if_mcp_or_web_search", false)),
            "codex_home": self.codex, "sqlite_home": self.sqlite,
            "note": "User-file values plus source-code defaults. Profiles, trusted folder layers, managed policy and per-session overrides may change actual enablement. Viewing never changes settings."
        })
    }
}

pub(super) fn expand(value: &str, home: &Path) -> PathBuf {
    value
        .strip_prefix("~/")
        .map_or_else(|| PathBuf::from(value), |path| home.join(path))
}

pub(super) fn read_json(path: &Path) -> Value {
    read_small(path)
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| json!({}))
}

pub(super) fn read_toml(path: &Path) -> toml::Value {
    read_small(path)
        .and_then(|s| toml::from_str(&s).ok())
        .unwrap_or_else(|| toml::Value::Table(toml::map::Map::new()))
}

fn read_small(path: &Path) -> Option<String> {
    match crate::files::read_preview(path.parent()?, path).content {
        crate::FileContent::Text(text) => Some(text),
        _ => None,
    }
}

/// Resolve repository identity from Git metadata without running Git.
pub(super) fn repository_root(folder: &Path) -> PathBuf {
    let canonical = folder.canonicalize().unwrap_or_else(|_| folder.to_owned());
    for parent in canonical.ancestors() {
        let dot_git = parent.join(".git");
        if std::fs::symlink_metadata(&dot_git).is_ok_and(|m| m.is_dir()) {
            return parent.to_owned();
        }
        if let Some(pointer) = read_small(&dot_git)
            && let Some(directory) = pointer.trim().strip_prefix("gitdir: ")
        {
            let directory = parent.join(directory);
            if let Some(common) = read_small(&directory.join("commondir"))
                && let Ok(common) = directory.join(common.trim()).canonicalize()
                && let Some(root) = common.parent()
            {
                return root.to_owned();
            }
            return parent.to_owned();
        }
    }
    canonical
}

pub(super) fn claude_key(path: &Path) -> String {
    let value: String = path.to_string_lossy().nfc().collect();
    let key: String = value
        .encode_utf16()
        .map(|unit| {
            u8::try_from(unit)
                .ok()
                .filter(u8::is_ascii_alphanumeric)
                .map_or('-', char::from)
        })
        .collect();
    if key.len() <= 200 {
        return key;
    }
    let hash = value.encode_utf16().fold(0_i32, |hash, unit| {
        hash.wrapping_mul(31).wrapping_add(i32::from(unit))
    });
    format!("{}-{}", &key[..200], base36(hash.unsigned_abs()))
}

fn base36(mut value: u32) -> String {
    let mut bytes = Vec::new();
    loop {
        let digit = u8::try_from(value % 36).unwrap_or(0);
        bytes.push(char::from(if digit < 10 {
            b'0' + digit
        } else {
            b'a' + digit - 10
        }));
        value /= 36;
        if value == 0 {
            break;
        }
    }
    bytes.into_iter().rev().collect()
}

pub(super) fn claude_override_key() -> Option<String> {
    if std::env::var("CLAUDE_CONFIG_DIR").ok()?.trim().is_empty() {
        return None;
    }
    let key = std::env::var("CLAUDE_CODE_PROJECT_DIR_NAME").ok()?;
    let upper = key.to_ascii_uppercase();
    let reserved = matches!(upper.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || ["COM", "LPT"].iter().any(|prefix| {
            upper
                .strip_prefix(prefix)
                .is_some_and(|s| s.len() == 1 && s.as_bytes()[0].is_ascii_digit())
        });
    (!key.is_empty()
        && key.len() <= 64
        && !reserved
        && key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'))
    .then_some(key)
}

fn sqlite_location(
    config: &toml::Value,
    environment: Option<&str>,
    codex: &Path,
    home: &Path,
    working: &Path,
) -> PathBuf {
    let configured = config.get("sqlite_home").and_then(toml::Value::as_str);
    let (value, base) = configured.map_or_else(
        || {
            (
                environment.map(str::trim).filter(|v| !v.is_empty()),
                working,
            )
        },
        |v| (Some(v), codex),
    );
    let value = value.map_or_else(|| codex.to_owned(), |v| expand(v, home));
    let path = if value.is_absolute() {
        value
    } else {
        base.join(value)
    };
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_key_handles_utf16_and_long_names_and_git_metadata_is_bounded() {
        assert_eq!(claude_key(Path::new("/a💡b")), "-a--b");
        assert_eq!(
            claude_key(Path::new("/cafe\u{301}")),
            claude_key(Path::new("/café"))
        );
        let path = format!("/{}", "a".repeat(250));
        let key = claude_key(Path::new(&path));
        assert_eq!(key[..200].len(), 200);
        assert_eq!(&key[200..], "-feo44x");
        let root = tempfile::tempdir().unwrap();
        let repo = root.path().join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        let alias = root.path().join("alias");
        std::os::unix::fs::symlink(&repo, &alias).unwrap();
        assert_eq!(repository_root(&alias), repository_root(&repo));
        let unsafe_repo = root.path().join("unsafe");
        std::fs::create_dir_all(&unsafe_repo).unwrap();
        let path = unsafe_repo.join(".git");
        std::fs::File::create(&path)
            .unwrap()
            .set_len(crate::TEXT_LIMIT + 1)
            .unwrap();
        assert_eq!(
            repository_root(&unsafe_repo),
            unsafe_repo.canonicalize().unwrap()
        );
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(repo.join(".git"), &path).unwrap();
        assert_eq!(
            repository_root(&unsafe_repo),
            unsafe_repo.canonicalize().unwrap()
        );
    }

    #[test]
    fn relative_config_and_environment_sqlite_paths_use_their_own_bases() {
        let config = toml::from_str("sqlite_home = 'state/../data'").unwrap();
        assert_eq!(
            sqlite_location(
                &config,
                Some("env"),
                Path::new("/home/.codex"),
                Path::new("/home"),
                Path::new("/folder")
            ),
            Path::new("/home/.codex/data")
        );
        let config = toml::Value::Table(toml::map::Map::new());
        assert_eq!(
            sqlite_location(
                &config,
                Some("  env  "),
                Path::new("/home/.codex"),
                Path::new("/home"),
                Path::new("/folder")
            ),
            Path::new("/folder/env")
        );
    }
}
