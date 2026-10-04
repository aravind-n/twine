//! Global config imports merge explicit TOML settings before Serde supplies defaults.

use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use toml::de::{DeTable, DeValue};

use super::{Config, ConfigDiagnostic, ConfigProblem, LoadedConfig, diagnostics, file_diagnostic};

const MAX_DEPTH: usize = 64;
const MAX_DOCUMENTS: usize = 256;

pub(super) fn load(path: &Path, source: &str) -> LoadedConfig {
    let mut loader = Loader::default();
    let canonical = match fs::canonicalize(path) {
        Ok(path) => path,
        Err(error) => {
            return LoadedConfig {
                diagnostics: vec![file_diagnostic(path, &error)],
                ..LoadedConfig::default()
            };
        }
    };
    let table = loader.document(path, source, canonical);
    let config = table.map_or_else(Config::default, |table| {
        toml::Value::Table(table).try_into().unwrap_or_else(|_| {
            loader.diagnostics.push(ConfigDiagnostic::at(
                path,
                source,
                0,
                "<document>".to_owned(),
                ConfigProblem::InvalidValue,
            ));
            Config::default()
        })
    });
    LoadedConfig {
        config,
        diagnostics: loader.diagnostics,
    }
}

#[derive(Default)]
struct Loader {
    active: Vec<PathBuf>,
    documents: usize,
    diagnostics: Vec<ConfigDiagnostic>,
}

impl Loader {
    fn document(&mut self, path: &Path, source: &str, canonical: PathBuf) -> Option<toml::Table> {
        self.documents += 1;
        let parsed = Config::parse(path, source);
        let invalid = parsed
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.problem != ConfigProblem::UnknownKey);
        if invalid {
            self.diagnostics.extend(parsed.diagnostics);
            return None;
        }
        let (mut document, _) = DeTable::parse_recoverable(source);
        let locations = diagnostics::locations(document.get_ref());
        // Unknown settings must stay ignored, even when their values cannot be represented in
        // toml::Value (for example, an unsigned integer larger than i64::MAX).
        for diagnostic in &parsed.diagnostics {
            if let Some(location) = locations
                .iter()
                .find(|location| diagnostics::display_key(&location.segments) == diagnostic.key)
            {
                remove_path(document.get_mut(), &location.segments);
            }
        }
        self.diagnostics.extend(parsed.diagnostics);
        let mut table = match toml::Table::deserialize(toml::Deserializer::from(document)) {
            Ok(table) => table,
            Err(error) => {
                self.diagnostics.push(ConfigDiagnostic::at(
                    path,
                    source,
                    error.span().map_or(0, |span| span.start),
                    diagnostics::key_at(&locations, source, &error),
                    ConfigProblem::InvalidValue,
                ));
                return None;
            }
        };
        let imports = match table.remove("import") {
            None => Vec::new(),
            Some(toml::Value::String(path)) => vec![(path, None)],
            Some(toml::Value::Array(values)) => {
                let mut paths = Vec::new();
                for (index, value) in values.into_iter().enumerate() {
                    let toml::Value::String(import) = value else {
                        self.problem(path, source, Some(index), ConfigProblem::InvalidValue);
                        return None;
                    };
                    paths.push((import, Some(index)));
                }
                paths
            }
            Some(_) => {
                self.problem(path, source, None, ConfigProblem::InvalidValue);
                return None;
            }
        };
        self.active.push(canonical);
        let mut merged = toml::Table::new();
        let mut failed = false;
        for (import, index) in imports {
            if let Some(imported) = self.import(path, source, &import, index) {
                merge(&mut merged, imported);
            } else {
                failed = true;
            }
        }
        self.active.pop();
        if failed {
            return None;
        }
        merge(&mut merged, table);
        Some(merged)
    }

    fn import(
        &mut self,
        owner: &Path,
        source: &str,
        import: &str,
        index: Option<usize>,
    ) -> Option<toml::Table> {
        let home = std::env::home_dir();
        let Some(path) = import_path(
            owner.parent().unwrap_or(Path::new(".")),
            Path::new(import),
            home.as_deref(),
        ) else {
            self.problem(owner, source, index, ConfigProblem::InvalidValue);
            return None;
        };
        let canonical = match fs::canonicalize(&path) {
            Ok(path) => path,
            Err(error) => {
                self.diagnostics.push(file_diagnostic(&path, &error));
                return None;
            }
        };
        if self.active.contains(&canonical) {
            self.problem(owner, source, index, ConfigProblem::ImportCycle);
            return None;
        }
        if self.active.len() >= MAX_DEPTH || self.documents >= MAX_DOCUMENTS {
            self.problem(owner, source, index, ConfigProblem::ImportLimit);
            return None;
        }
        match fs::read_to_string(&path) {
            Ok(imported) => self.document(&path, &imported, canonical),
            Err(error) => {
                self.diagnostics.push(file_diagnostic(&path, &error));
                None
            }
        }
    }

    fn problem(&mut self, path: &Path, source: &str, index: Option<usize>, problem: ConfigProblem) {
        let (table, _) = DeTable::parse_recoverable(source);
        let entry = table
            .get_ref()
            .iter()
            .find(|(key, _)| key.get_ref() == "import");
        let offset = entry.map_or(0, |(key, value)| {
            if let (Some(index), DeValue::Array(array)) = (index, value.get_ref()) {
                array
                    .get(index)
                    .map_or(key.span().start, |value| value.span().start)
            } else {
                key.span().start
            }
        });
        let key = index.map_or_else(|| "import".to_owned(), |index| format!("import.{index}"));
        self.diagnostics
            .push(ConfigDiagnostic::at(path, source, offset, key, problem));
    }
}

fn remove_path(table: &mut DeTable<'_>, path: &[String]) {
    if let Some((key, remaining)) = path.split_first() {
        if remaining.is_empty() {
            table.remove(key.as_str());
        } else if let Some(value) = table.get_mut(key.as_str())
            && let DeValue::Table(table) = value.get_mut()
        {
            remove_path(table, remaining);
        }
    }
}

fn merge(target: &mut toml::Table, source: toml::Table) {
    for (key, value) in source {
        match (target.get_mut(&key), value) {
            (Some(toml::Value::Table(existing)), toml::Value::Table(incoming)) => {
                merge(existing, incoming);
            }
            (_, value) => {
                target.insert(key, value);
            }
        }
    }
}

fn import_path(directory: &Path, import: &Path, home: Option<&Path>) -> Option<PathBuf> {
    if import.as_os_str().is_empty() {
        return None;
    }
    if let Ok(relative) = import.strip_prefix("~") {
        return home
            .filter(|home| home.is_absolute())
            .map(|home| home.join(relative));
    }
    Some(directory.join(import))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ColorScheme;

    #[test]
    fn imports_full_config_and_preserves_omitted_fields_during_deep_merge() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        fs::write(directory.path().join("shared.toml"), "[appearance]\ncolor_scheme = 'dark'\n[terminal]\nfont_family = 'Menlo'\nfont_size = 18\n[terminal.colors]\nbackground = '#123456'\nforeground = '#abcdef'\n").unwrap();
        fs::write(&path, "import = 'shared.toml'\n[terminal]\nfont_size = 14\n[terminal.colors]\nforeground = '#ffffff'\n").unwrap();
        let loaded = Config::load(&path);
        assert_eq!(loaded.diagnostics, []);
        assert_eq!(loaded.config.appearance.color_scheme, ColorScheme::Dark);
        assert_eq!(loaded.config.terminal.font_family, "Menlo");
        assert_eq!(loaded.config.terminal.font_size.points(), 14.0);
        assert_eq!(
            loaded.config.terminal.colors.background.unwrap().as_str(),
            "#123456"
        );
        assert_eq!(
            loaded.config.terminal.colors.foreground.unwrap().as_str(),
            "#ffffff"
        );
    }

    #[test]
    fn ordered_nested_imports_resolve_relative_to_the_file_containing_them() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let nested = directory.path().join("parts");
        fs::create_dir(&nested).unwrap();
        fs::write(
            nested.join("base.toml"),
            "terminal.font_family = 'Menlo'\nterminal.font_size = 17\n",
        )
        .unwrap();
        fs::write(
            nested.join("first.toml"),
            "import = 'base.toml'\nappearance.color_scheme = 'dark'\n",
        )
        .unwrap();
        fs::write(
            directory.path().join("last.toml"),
            "terminal.font_size = 22\n",
        )
        .unwrap();
        fs::write(
            &path,
            "import = ['parts/first.toml', 'last.toml']\nterminal.colors.background = '#112233'\n",
        )
        .unwrap();
        let loaded = Config::load(&path);
        assert_eq!(loaded.diagnostics, []);
        assert_eq!(loaded.config.terminal.font_family, "Menlo");
        assert_eq!(loaded.config.terminal.font_size.points(), 22.0);
        assert_eq!(loaded.config.appearance.color_scheme, ColorScheme::Dark);
    }

    #[test]
    fn cycles_and_symlink_aliases_report_the_import_that_closes_the_cycle() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let nested = directory.path().join("nested.toml");
        fs::write(&path, "import = 'nested.toml'\n").unwrap();
        let alias = directory.path().join("alias.toml");
        std::os::unix::fs::symlink(&path, &alias).unwrap();
        for root in ["config.toml", "alias.toml"] {
            fs::write(&nested, format!("# comment\nimport = '{root}'\n")).unwrap();
            let loaded = Config::load(&path);
            assert_eq!(loaded.config, Config::default());
            assert_eq!(loaded.diagnostics.len(), 1);
            assert_eq!(loaded.diagnostics[0].file, nested);
            assert_eq!(loaded.diagnostics[0].line, 2);
            assert_eq!(loaded.diagnostics[0].key, "import");
            assert_eq!(loaded.diagnostics[0].problem, ConfigProblem::ImportCycle);
        }
    }

    #[test]
    fn imported_invalid_values_and_unknown_keys_keep_their_original_locations() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let imported = directory.path().join("shared.toml");
        fs::write(&path, "import = 'shared.toml'\nterminal.font_size = 20\n").unwrap();
        fs::write(&imported, "# comment\n[terminal]\nfont_size = 'secret'\n").unwrap();
        let invalid = Config::load(&path);
        assert_eq!(invalid.config, Config::default());
        assert_eq!(invalid.diagnostics[0].file, imported);
        assert_eq!(invalid.diagnostics[0].line, 3);
        assert_eq!(invalid.diagnostics[0].key, "terminal.font_size");
        assert_eq!(invalid.diagnostics[0].problem, ConfigProblem::InvalidValue);
        assert!(!invalid.diagnostics[0].to_string().contains("secret"));
        fs::write(
            &imported,
            "terminal.font_family = 'Menlo'\nterminal.typo = 'secret'\n",
        )
        .unwrap();
        let warning = Config::load(&path);
        assert_eq!(warning.config.terminal.font_family, "Menlo");
        assert_eq!(warning.config.terminal.font_size.points(), 20.0);
        assert_eq!(warning.diagnostics.len(), 1);
        assert_eq!(warning.diagnostics[0].file, imported);
        assert_eq!(warning.diagnostics[0].line, 2);
        assert_eq!(warning.diagnostics[0].key, "terminal.typo");
        assert_eq!(warning.diagnostics[0].problem, ConfigProblem::UnknownKey);
    }

    #[test]
    fn invalid_imports_report_the_directive_or_array_element() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        for value in ["''", "true", "42", "{}"] {
            fs::write(
                &path,
                format!("# comment\n\nimport = {value}\nterminal.font_size = 18\n"),
            )
            .unwrap();
            let loaded = Config::load(&path);
            assert_eq!(loaded.config, Config::default());
            assert_eq!(loaded.diagnostics[0].line, 3);
            assert_eq!(loaded.diagnostics[0].key, "import");
            assert_eq!(loaded.diagnostics[0].problem, ConfigProblem::InvalidValue);
        }
        fs::write(&path, "import = [\n  42,\n]\n").unwrap();
        let invalid = Config::load(&path);
        assert_eq!(invalid.diagnostics[0].line, 2);
        assert_eq!(invalid.diagnostics[0].key, "import.0");
        fs::write(&path, "import = []\nterminal.font_size = 18\n").unwrap();
        let empty = Config::load(&path);
        assert_eq!(empty.diagnostics, []);
        assert_eq!(empty.config.terminal.font_size.points(), 18.0);
    }

    #[test]
    fn shared_imports_are_valid_and_depth_is_bounded() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        fs::write(
            directory.path().join("shared.toml"),
            "terminal.font_family = 'Menlo'\n",
        )
        .unwrap();
        fs::write(&path, "import = ['shared.toml', 'shared.toml']\n").unwrap();
        assert_eq!(Config::load(&path).diagnostics, []);
        for index in 0..=MAX_DEPTH {
            fs::write(
                directory.path().join(format!("{index}.toml")),
                format!("import = '{}.toml'\n", index + 1),
            )
            .unwrap();
        }
        fs::write(&path, "import = '0.toml'\n").unwrap();
        let loaded = Config::load(&path);
        assert_eq!(loaded.config, Config::default());
        assert_eq!(loaded.diagnostics.len(), 1);
        assert_eq!(loaded.diagnostics[0].problem, ConfigProblem::ImportLimit);
    }

    #[test]
    fn oversized_unknown_integers_are_ignored_and_invalid_imports_never_panic() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let imported = directory.path().join("shared.toml");
        let source =
            "extra = 9223372036854775808\n[terminal]\nfont_size = 18\ntypo = 9223372036854775808\n";
        fs::write(&imported, source).unwrap();
        fs::write(&path, "import = 'shared.toml'\n").unwrap();
        let loaded = Config::load(&path);
        assert_eq!(loaded.config.terminal.font_size.points(), 18.0);
        assert_eq!(loaded.diagnostics.len(), 2);
        assert!(
            loaded
                .diagnostics
                .iter()
                .all(|diagnostic| diagnostic.problem == ConfigProblem::UnknownKey
                    && diagnostic.file == imported)
        );
        fs::write(
            &path,
            "# comment\nimport = 9223372036854775808\nterminal.font_size = 18\n",
        )
        .unwrap();
        let invalid = Config::load(&path);
        assert_eq!(invalid.config, Config::default());
        assert_eq!(invalid.diagnostics.len(), 1);
        assert_eq!(invalid.diagnostics[0].line, 2);
        assert_eq!(invalid.diagnostics[0].key, "import");
        assert_eq!(invalid.diagnostics[0].problem, ConfigProblem::InvalidValue);
        assert!(
            !invalid.diagnostics[0]
                .to_string()
                .contains("9223372036854775808")
        );
    }

    #[test]
    fn document_limit_bounds_wide_import_lists() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        fs::write(
            directory.path().join("shared.toml"),
            "terminal.font_family = 'Menlo'\n",
        )
        .unwrap();
        let imports = vec!["'shared.toml'"; MAX_DOCUMENTS].join(",");
        fs::write(&path, format!("import = [{imports}]\n")).unwrap();
        let loaded = Config::load(&path);
        assert_eq!(loaded.config, Config::default());
        assert_eq!(loaded.diagnostics.len(), 1);
        assert_eq!(loaded.diagnostics[0].problem, ConfigProblem::ImportLimit);
        assert_eq!(
            loaded.diagnostics[0].key,
            format!("import.{}", MAX_DOCUMENTS - 1)
        );
    }

    #[test]
    fn import_paths_are_relative_absolute_or_home_relative() {
        let directory = Path::new("/config/twine");
        assert_eq!(
            import_path(directory, Path::new("themes/custom.toml"), None),
            Some(directory.join("themes/custom.toml"))
        );
        assert_eq!(
            import_path(directory, Path::new("/other/custom.toml"), None),
            Some(PathBuf::from("/other/custom.toml"))
        );
        assert_eq!(
            import_path(
                directory,
                Path::new("~/custom.toml"),
                Some(Path::new("/home/user"))
            ),
            Some(PathBuf::from("/home/user/custom.toml"))
        );
        assert_eq!(import_path(directory, Path::new(""), None), None);
        assert_eq!(
            import_path(directory, Path::new("~/custom.toml"), None),
            None
        );
    }
}
