use super::locations::{Locations, claude_key, claude_override_key, expand, repository_root};
use super::{
    MemoryError, MemoryHarness, MemoryKind, MemoryRequest, MemoryScope, MemorySource, SOURCE_LIMIT,
    database,
};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

pub(super) enum Backing {
    File {
        root: PathBuf,
        path: PathBuf,
    },
    Database {
        root: PathBuf,
        path: PathBuf,
        thread: String,
        column: String,
    },
    Text(String),
}

pub(super) struct Entry {
    pub source: MemorySource,
    pub backing: Backing,
}

pub(super) struct Collector {
    pub entries: Vec<Entry>,
    pub diagnostics: Vec<String>,
    seen: HashSet<String>,
    pub example: bool,
}

impl Collector {
    pub fn new(example: bool) -> Self {
        Self {
            entries: Vec::new(),
            diagnostics: Vec::new(),
            seen: HashSet::new(),
            example,
        }
    }

    pub fn push(&mut self, mut source: MemorySource, backing: Backing) {
        source.example = self.example;
        if self.entries.len() < SOURCE_LIMIT && self.seen.insert(source.id.clone()) {
            self.entries.push(Entry { source, backing });
        }
    }

    pub fn file(
        &mut self,
        root: &Path,
        path: &Path,
        harness: MemoryHarness,
        scope: MemoryScope,
        kind: MemoryKind,
        group: &str,
    ) {
        let Ok(metadata) = std::fs::symlink_metadata(path) else {
            return;
        };
        if metadata.is_dir() {
            return;
        }
        let title = path.file_name().map_or_else(
            || "Memory source".into(),
            |name| name.to_string_lossy().into_owned(),
        );
        let mut source = source(path, &title, harness, scope, kind, group);
        source.modified_at = metadata
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs());
        self.push(
            source,
            Backing::File {
                root: root.to_owned(),
                path: path.to_owned(),
            },
        );
    }

    pub fn tree(
        &mut self,
        root: &Path,
        harness: MemoryHarness,
        scope: MemoryScope,
        default: MemoryKind,
        group: &str,
    ) {
        let mut pending = vec![(root.to_owned(), 0)];
        let mut visited = 0;
        while let Some((directory, depth)) = pending.pop() {
            visited += 1;
            if visited > SOURCE_LIMIT || self.entries.len() >= SOURCE_LIMIT {
                break;
            }
            let Ok(metadata) = std::fs::symlink_metadata(&directory) else {
                continue;
            };
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                continue;
            }
            if harness == MemoryHarness::ClaudeCode
                && [".memory-sync", ".memory-sync-basis"]
                    .iter()
                    .any(|name| directory.join(name).symlink_metadata().is_ok())
            {
                self.diagnostics.push(format!(
                    "Excluded remote-synced Claude memory: {}",
                    directory.display()
                ));
                continue;
            }
            let Ok(entries) = std::fs::read_dir(&directory) else {
                self.diagnostics
                    .push(format!("Cannot list {}", directory.display()));
                continue;
            };
            let mut paths: Vec<_> = entries
                .take(SOURCE_LIMIT)
                .filter_map(Result::ok)
                .map(|e| e.path())
                .collect();
            paths.sort();
            for path in paths {
                let name = path.file_name().unwrap_or_default().to_string_lossy();
                if name == ".git" {
                    continue;
                }
                let Ok(metadata) = std::fs::symlink_metadata(&path) else {
                    continue;
                };
                if metadata.is_dir() {
                    if harness == MemoryHarness::ClaudeCode
                        && default == MemoryKind::Durable
                        && directory == root
                        && name == "team"
                    {
                        self.diagnostics.push(format!(
                            "Excluded Claude team memory mirror: {}",
                            path.display()
                        ));
                        continue;
                    }
                    if depth < 8 {
                        pending.push((path, depth + 1));
                    }
                } else {
                    let relative = path.strip_prefix(root).unwrap_or(&path);
                    self.file(
                        root,
                        &path,
                        harness,
                        scope,
                        artifact_kind(relative, default, harness),
                        group,
                    );
                }
            }
        }
    }

    fn scan(&mut self, locations: &Locations) {
        let codex = MemoryHarness::Codex;
        let claude = MemoryHarness::ClaudeCode;
        let global = MemoryScope::Global;
        for name in ["AGENTS.md", "AGENTS.override.md"] {
            self.file(
                &locations.codex,
                &locations.codex.join(name),
                codex,
                global,
                MemoryKind::Instructions,
                "Codex user instructions",
            );
        }
        self.tree(
            &locations.codex.join("rules"),
            codex,
            global,
            MemoryKind::Rule,
            "Codex execution rules",
        );
        for name in ["memories", "memories_v2"] {
            let root = locations.codex.join(name);
            self.diagnostics.push(format!("Checked {}", root.display()));
            self.tree(
                &root,
                codex,
                global,
                MemoryKind::Durable,
                &format!("Codex {name}"),
            );
        }
        self.codex_settings(locations);
        database::discover(&locations.sqlite, locations.folder.as_deref(), self);
        self.file(
            &locations.claude,
            &locations.claude.join("CLAUDE.md"),
            claude,
            global,
            MemoryKind::Instructions,
            "Claude user instructions",
        );
        self.tree(
            &locations.claude.join("rules"),
            claude,
            global,
            MemoryKind::Rule,
            "Claude user rules",
        );
        self.tree(
            &locations.claude.join("agent-memory"),
            claude,
            global,
            MemoryKind::AgentMemory,
            "Claude user agent memory",
        );
        if let Some(folder) = &locations.folder {
            self.instructions(folder, &locations.codex_config);
            self.tree(
                &folder.join(".codex/rules"),
                codex,
                MemoryScope::Folder,
                MemoryKind::Rule,
                "Codex folder execution rules",
            );
            self.tree(
                &folder.join(".claude/rules"),
                claude,
                MemoryScope::Folder,
                MemoryKind::Rule,
                "Claude folder rules",
            );
            for name in ["agent-memory", "agent-memory-local"] {
                self.tree(
                    &folder.join(".claude").join(name),
                    claude,
                    MemoryScope::Folder,
                    MemoryKind::AgentMemory,
                    &format!("Claude {name}"),
                );
            }
        }
        self.claude_stores(locations);
        let settings = json!({"source": locations.claude.join("settings.json"),
            "autoMemoryEnabled": locations.claude_settings.get("autoMemoryEnabled").cloned().unwrap_or(json!(true)),
            "autoMemoryDirectory": locations.claude_settings.get("autoMemoryDirectory"),
            "note": "User and folder settings snapshot; managed settings, command-line settings and session constraints may override it."});
        self.push(
            source(
                &locations.claude.join("settings.json"),
                "Claude memory settings",
                claude,
                global,
                MemoryKind::Configuration,
                "Memory settings",
            ),
            Backing::Text(serde_json::to_string_pretty(&settings).unwrap_or_default()),
        );
    }

    fn codex_settings(&mut self, locations: &Locations) {
        let codex = MemoryHarness::Codex;
        let global = MemoryScope::Global;
        let config = locations.config_summary();
        let enabled = config["features.memories"].as_bool().unwrap_or(false);
        self.diagnostics.push(format!(
            "Codex user-file memory flag: {}. Session overrides may differ.",
            if enabled { "enabled" } else { "off (default)" }
        ));
        let config_path = locations.codex.join("config.toml");
        self.push(
            source(
                &config_path,
                "Codex memory settings",
                codex,
                global,
                MemoryKind::Configuration,
                "Memory settings",
            ),
            Backing::Text(serde_json::to_string_pretty(&config).unwrap_or_default()),
        );
    }

    fn instructions(&mut self, folder: &Path, config: &toml::Value) {
        let mut names = vec![
            "AGENTS.md".to_owned(),
            "AGENTS.override.md".into(),
            "CLAUDE.md".into(),
            "CLAUDE.local.md".into(),
        ];
        if let Some(fallbacks) = config
            .get("project_doc_fallback_filenames")
            .and_then(toml::Value::as_array)
        {
            names.extend(
                fallbacks
                    .iter()
                    .filter_map(toml::Value::as_str)
                    .filter(|n| Path::new(n).components().count() == 1)
                    .map(str::to_owned),
            );
        }
        let mut pending = vec![(folder.to_owned(), 0)];
        let mut visited = 0;
        while let Some((directory, depth)) = pending.pop() {
            visited += 1;
            if visited > SOURCE_LIMIT {
                break;
            }
            for name in &names {
                let harness = if name.starts_with("CLAUDE") {
                    MemoryHarness::ClaudeCode
                } else {
                    MemoryHarness::Codex
                };
                self.file(
                    folder,
                    &directory.join(name),
                    harness,
                    MemoryScope::Folder,
                    MemoryKind::Instructions,
                    "Folder instructions",
                );
            }
            self.file(
                folder,
                &directory.join(".claude/CLAUDE.md"),
                MemoryHarness::ClaudeCode,
                MemoryScope::Folder,
                MemoryKind::Instructions,
                "Folder instructions",
            );
            if depth >= 6 {
                continue;
            }
            let Ok(entries) = std::fs::read_dir(&directory) else {
                continue;
            };
            let mut children: Vec<_> = entries
                .take(SOURCE_LIMIT)
                .filter_map(Result::ok)
                .filter(|e| {
                    !ignored(&e.file_name().to_string_lossy())
                        && e.file_type().is_ok_and(|t| t.is_dir())
                })
                .map(|e| e.path())
                .collect();
            children.sort();
            pending.extend(children.into_iter().map(|p| (p, depth + 1)));
        }
        self.inherited_instructions(folder, &names);
    }

    fn inherited_instructions(&mut self, folder: &Path, names: &[String]) {
        // Claude also reads instructions above the open folder, which are inherited context.
        let instruction_root = folder
            .ancestors()
            .find(|parent| parent.join(".git").symlink_metadata().is_ok());
        for parent in folder.ancestors().skip(1) {
            if parent.parent().is_none() {
                break;
            }
            for name in ["CLAUDE.md", "CLAUDE.local.md"] {
                self.file(
                    parent,
                    &parent.join(name),
                    MemoryHarness::ClaudeCode,
                    MemoryScope::Folder,
                    MemoryKind::Instructions,
                    "Inherited Claude instructions",
                );
            }
            self.file(
                parent,
                &parent.join(".claude/CLAUDE.md"),
                MemoryHarness::ClaudeCode,
                MemoryScope::Folder,
                MemoryKind::Instructions,
                "Inherited Claude instructions",
            );
            if instruction_root.is_some_and(|root| parent.starts_with(root)) {
                for name in names.iter().filter(|name| !name.starts_with("CLAUDE")) {
                    self.file(
                        parent,
                        &parent.join(name),
                        MemoryHarness::Codex,
                        MemoryScope::Folder,
                        MemoryKind::Instructions,
                        "Inherited Codex instructions",
                    );
                }
            }
        }
    }

    fn claude_stores(&mut self, locations: &Locations) {
        let expected = locations
            .folder
            .as_ref()
            .map(|folder| claude_key(&repository_root(folder)));
        let override_key = claude_override_key();
        let expected = if locations.example {
            Some("-demo-twine".to_owned())
        } else {
            override_key.or(expected)
        };
        let projects = locations.claude.join("projects");
        if let Ok(entries) = std::fs::read_dir(&projects) {
            let mut entries: Vec<_> = entries.take(SOURCE_LIMIT).filter_map(Result::ok).collect();
            entries.sort_by_key(std::fs::DirEntry::file_name);
            for entry in entries.into_iter().take(SOURCE_LIMIT) {
                if !entry.file_type().is_ok_and(|t| t.is_dir()) {
                    continue;
                }
                let key = entry.file_name().to_string_lossy().into_owned();
                let scope = if Some(&key) == expected.as_ref() {
                    MemoryScope::Folder
                } else {
                    MemoryScope::OtherFolder
                };
                self.tree(
                    &entry.path().join("memory"),
                    MemoryHarness::ClaudeCode,
                    scope,
                    MemoryKind::Durable,
                    &format!("Claude folder: {key}"),
                );
            }
        }
        if let Some(directory) = locations
            .claude_settings
            .get("autoMemoryDirectory")
            .and_then(serde_json::Value::as_str)
        {
            let path = expand(directory, &locations.home);
            if path.is_absolute() {
                self.tree(
                    &path,
                    MemoryHarness::ClaudeCode,
                    MemoryScope::Folder,
                    MemoryKind::Durable,
                    "Claude configured memory directory",
                );
            } else {
                self.diagnostics
                    .push("Claude autoMemoryDirectory is not absolute; it was skipped.".into());
            }
        }
    }
}

pub(super) fn discover(request: &MemoryRequest) -> Result<(Vec<Entry>, Vec<String>), MemoryError> {
    if request
        .folder
        .iter()
        .chain(request.examples_root.iter())
        .any(|p| !p.is_absolute())
    {
        return Err(MemoryError::InvalidPath);
    }
    let mut collector = Collector::new(false);
    collector.scan(&Locations::live(request));
    if let Some(root) = &request.examples_root {
        collector.example = true;
        collector.scan(&Locations::examples(root));
    }
    if collector.entries.len() >= SOURCE_LIMIT {
        collector
            .diagnostics
            .push(format!("Discovery is limited to {SOURCE_LIMIT} sources."));
    }
    collector.entries.sort_by(|a, b| {
        a.source
            .group
            .cmp(&b.source.group)
            .then(a.source.location.cmp(&b.source.location))
    });
    Ok((collector.entries, collector.diagnostics))
}

pub(super) fn source(
    path: &Path,
    title: &str,
    harness: MemoryHarness,
    scope: MemoryScope,
    kind: MemoryKind,
    group: &str,
) -> MemorySource {
    let location = path.to_string_lossy().into_owned();
    MemorySource {
        id: identifier(&location),
        title: title.into(),
        harness,
        scope,
        kind,
        location,
        group: group.into(),
        format: path
            .extension()
            .map_or_else(|| "text".into(), |s| s.to_string_lossy().to_lowercase()),
        modified_at: None,
        example: false,
        association: None,
    }
}

pub(super) fn identifier(location: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    Sha256::digest(location.as_bytes())
        .iter()
        .flat_map(|byte| {
            [
                char::from(HEX[usize::from(byte >> 4)]),
                char::from(HEX[usize::from(byte & 15)]),
            ]
        })
        .collect()
}

fn ignored(name: &str) -> bool {
    matches!(
        name,
        ".git"
            | "target"
            | "out"
            | "build"
            | "node_modules"
            | ".build"
            | "vendor"
            | "memory-viewer-fixtures"
    )
}

fn artifact_kind(path: &Path, fallback: MemoryKind, harness: MemoryHarness) -> MemoryKind {
    if matches!(fallback, MemoryKind::AgentMemory | MemoryKind::Rule) {
        return fallback;
    }
    let pieces: Vec<_> = path
        .components()
        .map(|p| p.as_os_str().to_string_lossy())
        .collect();
    if pieces.iter().any(|p| p == "extensions") {
        return MemoryKind::Extension;
    }
    if pieces.iter().any(|p| p == "skills") {
        return MemoryKind::Skill;
    }
    if pieces.iter().any(|p| p == "rollout_summaries") {
        return MemoryKind::RolloutSummary;
    }
    match path.file_name().and_then(|s| s.to_str()) {
        Some("MEMORY.md") if harness == MemoryHarness::Codex => MemoryKind::Durable,
        Some("memory_summary.md" | "MEMORY.md") => MemoryKind::Summary,
        Some("raw_memories.md") => MemoryKind::RawMemory,
        Some(name) if name.starts_with("phase") => MemoryKind::Artifact,
        _ => fallback,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(root: &Path, relative: &str, contents: &str) {
        let path = root.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, contents).unwrap();
    }

    #[test]
    fn discovers_versions_extensions_rules_and_agent_memory_with_honest_scopes() {
        let root = tempfile::tempdir().unwrap();
        for (name, content) in [
            ("home/.codex/memories/memory_summary.md", "v1\nsummary"),
            (
                "home/.codex/memories_v2/memory_summary.md",
                "v1\nv2 summary",
            ),
            (
                "home/.codex/memories/extensions/ad_hoc/resources/note.json",
                "{\"note\":\"context\"}",
            ),
            ("home/.codex/memories/skills/build/SKILL.md", "# Build"),
            (
                "home/.claude/projects/-demo-twine/memory/MEMORY.md",
                "# Folder",
            ),
            ("home/.claude/projects/-another/memory/MEMORY.md", "# Other"),
            (
                "home/.claude/agent-memory/reviewer/MEMORY.md",
                "# User agent",
            ),
            (
                "folder/.claude/agent-memory-local/reviewer/MEMORY.md",
                "# Local agent",
            ),
            ("folder/.claude/rules/swift.md", "# Swift"),
            ("folder/AGENTS.md", "# Folder instructions"),
            ("folder/AGENTS.override.md", "# Override"),
            (
                "folder/designs/memory-viewer-fixtures/CLAUDE.md",
                "must be excluded",
            ),
        ] {
            write(root.path(), name, content);
        }
        let locations = Locations::examples(root.path());
        let mut collector = Collector::new(true);
        collector.scan(&locations);
        assert!(
            collector
                .entries
                .iter()
                .any(|e| e.source.kind == MemoryKind::Extension && e.source.format == "json")
        );
        assert!(
            collector
                .entries
                .iter()
                .any(|e| e.source.kind == MemoryKind::Skill)
        );
        assert_eq!(
            collector
                .entries
                .iter()
                .filter(|e| e.source.kind == MemoryKind::AgentMemory)
                .count(),
            2
        );
        assert!(
            collector
                .entries
                .iter()
                .any(|e| e.source.scope == MemoryScope::OtherFolder)
        );
        assert!(
            collector
                .entries
                .iter()
                .any(|e| e.source.kind == MemoryKind::Rule)
        );
        assert!(
            !collector
                .entries
                .iter()
                .any(|e| e.source.location.contains("memory-viewer-fixtures"))
        );
        assert!(collector.entries.iter().all(|e| e.source.example));
    }

    #[test]
    fn symlinks_are_listed_but_never_read_and_large_files_are_bounded() {
        let root = tempfile::tempdir().unwrap();
        write(root.path(), "outside.md", "outside context");
        std::fs::create_dir_all(root.path().join("home/.codex/memories")).unwrap();
        let path = root.path().join("home/.codex/memories/link.md");
        std::os::unix::fs::symlink(root.path().join("outside.md"), &path).unwrap();
        assert_eq!(
            crate::files::read_preview(&root.path().join("home/.codex/memories"), &path).content,
            crate::FileContent::Unsupported
        );
        let large = root.path().join("home/.codex/memories/large.md");
        FileForTest::large(&large);
        assert_eq!(
            crate::files::read_preview(&root.path().join("home/.codex/memories"), &large).content,
            crate::FileContent::TooLarge
        );
    }

    struct FileForTest;
    impl FileForTest {
        fn large(path: &Path) {
            std::fs::File::create(path)
                .unwrap()
                .set_len(crate::TEXT_LIMIT + 1)
                .unwrap();
        }
    }

    #[test]
    fn unknown_source_ids_and_relative_requests_are_rejected() {
        assert!(matches!(
            super::super::catalog(&MemoryRequest {
                folder: Some("relative".into()),
                ..MemoryRequest::default()
            }),
            Err(MemoryError::InvalidPath)
        ));
        assert!(matches!(
            super::super::read(&MemoryRequest {
                source_id: Some("../../auth.json".into()),
                ..MemoryRequest::default()
            }),
            Err(MemoryError::MissingSource)
        ));
    }

    #[test]
    fn codex_handbook_is_durable_while_claude_index_is_a_summary() {
        assert_eq!(
            artifact_kind(
                Path::new("MEMORY.md"),
                MemoryKind::Durable,
                MemoryHarness::Codex
            ),
            MemoryKind::Durable
        );
        assert_eq!(
            artifact_kind(
                Path::new("MEMORY.md"),
                MemoryKind::Durable,
                MemoryHarness::ClaudeCode
            ),
            MemoryKind::Summary
        );
        assert_eq!(
            artifact_kind(
                Path::new("reviewer/MEMORY.md"),
                MemoryKind::AgentMemory,
                MemoryHarness::ClaudeCode
            ),
            MemoryKind::AgentMemory
        );
    }

    #[test]
    fn remote_claude_mirrors_are_excluded_and_nested_codex_instructions_are_inherited() {
        let root = tempfile::tempdir().unwrap();
        for (name, content) in [
            ("home/.claude/projects/-demo-twine/memory/local.md", "local"),
            (
                "home/.claude/projects/-demo-twine/memory/team/shared/remote.md",
                "remote",
            ),
            (
                "home/.claude/projects/-demo-twine/memory/mount/.memory-sync",
                "{\"v\":1}",
            ),
            (
                "home/.claude/projects/-demo-twine/memory/mount/remote.md",
                "remote",
            ),
            ("folder/AGENTS.md", "inherited"),
            ("folder/nested/file.txt", "folder exists"),
        ] {
            write(root.path(), name, content);
        }
        std::fs::create_dir_all(root.path().join("folder/.git")).unwrap();
        let mut collector = Collector::new(true);
        collector.scan(&Locations::examples(root.path()));
        assert!(
            collector
                .entries
                .iter()
                .any(|e| e.source.location.ends_with("local.md"))
        );
        assert!(
            !collector
                .entries
                .iter()
                .any(|e| e.source.location.ends_with("remote.md"))
        );
        assert_eq!(
            collector
                .diagnostics
                .iter()
                .filter(|d| d.contains("Excluded"))
                .count(),
            2
        );
        let mut locations = Locations::examples(root.path());
        locations.folder = Some(root.path().join("folder/nested"));
        let mut collector = Collector::new(true);
        collector.scan(&locations);
        assert!(
            collector
                .entries
                .iter()
                .any(|e| e.source.location.ends_with("folder/AGENTS.md"))
        );
    }
}
