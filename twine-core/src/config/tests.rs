use super::*;

const PATH: &str = "/test/config.toml";

#[test]
fn absent_fields_use_defaults() {
    for source in ["", "# empty\n", "[appearance]\n"] {
        let loaded = Config::parse(Path::new(PATH), source);
        assert_eq!(loaded.config, Config::default());
        assert!(loaded.diagnostics.is_empty());
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
        assert!(!loaded.diagnostics.is_empty());
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
    assert!(loaded.diagnostics.is_empty());
    let source = fs::read_to_string(&path).unwrap();
    assert!(source.contains("[appearance]"));
    assert!(source.contains("# color_scheme = \"system\""));
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
    assert_eq!(Config::parse(&path, &uncommented).config, Config::default());
    assert!(Config::parse(&path, &uncommented).diagnostics.is_empty());

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
fn concurrent_first_loads_publish_one_complete_file() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("config.toml");
    std::thread::scope(|scope| {
        for _ in 0..8 {
            scope.spawn(|| {
                let loaded = Config::load(&path);
                assert_eq!(loaded.config, Config::default());
                assert!(loaded.diagnostics.is_empty());
            });
        }
    });
    assert!(fs::read_to_string(path).unwrap().contains("# color_scheme"));
}

#[test]
fn snapshot_contains_loaded_config() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("config.toml");
    fs::write(&path, "[appearance]\ncolor_scheme = 'dark'\n").unwrap();
    let application = crate::Application::with_config(Config::load(&path).config).unwrap();
    assert_eq!(
        application
            .snapshot()
            .unwrap()
            .config
            .appearance
            .color_scheme,
        ColorScheme::Dark
    );
}
