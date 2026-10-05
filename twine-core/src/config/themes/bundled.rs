//! Optional theme files are published once and used only when the user imports one.

use std::fs;
use std::io;
use std::path::Path;

use super::{file_diagnostic, write_default};

const THEMES: &[(&str, &str)] = &[
    (
        "catppuccin_mocha.toml",
        include_str!("catppuccin_mocha.toml"),
    ),
    (
        "catppuccin_latte.toml",
        include_str!("catppuccin_latte.toml"),
    ),
    ("tokyo_night.toml", include_str!("tokyo_night.toml")),
    ("tokyo_night_day.toml", include_str!("tokyo_night_day.toml")),
    ("gruvbox_dark.toml", include_str!("gruvbox_dark.toml")),
    ("gruvbox_light.toml", include_str!("gruvbox_light.toml")),
    ("dracula.toml", include_str!("dracula.toml")),
    ("nord.toml", include_str!("nord.toml")),
];

const LICENSES: &[(&str, &str)] = &[
    (
        "licenses/catppuccin.txt",
        include_str!("licenses/catppuccin.txt"),
    ),
    (
        "licenses/tokyo_night.txt",
        include_str!("licenses/tokyo_night.txt"),
    ),
    ("licenses/gruvbox.txt", include_str!("licenses/gruvbox.txt")),
    ("licenses/dracula.txt", include_str!("licenses/dracula.txt")),
    ("licenses/nord.txt", include_str!("licenses/nord.txt")),
];

pub(super) fn publish(directory: &Path) {
    for &(name, source) in THEMES.iter().chain(LICENSES) {
        let path = directory.join("themes").join(name);
        let result = match fs::symlink_metadata(&path) {
            Ok(_) => continue,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                write_default(&path, source).map(|_| ())
            }
            Err(error) => Err(super::super::ConfigFileError::Read(error)),
        };
        if let Err(error) = result {
            let diagnostic = file_diagnostic(&path, &error);
            // An unused optional theme must never make the active configuration fall back.
            tracing::warn!(%diagnostic, "cannot publish bundled theme file");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::ANSI_COLOR_NAMES;
    use super::*;
    use crate::config::Config;

    #[test]
    fn seeds_every_theme_and_license_without_changing_the_default_palettes() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        let loaded = Config::load(&config);
        assert_eq!(loaded.config, Config::default());
        assert_eq!(loaded.diagnostics, []);
        for &(name, source) in THEMES.iter().chain(LICENSES) {
            assert_eq!(
                fs::read_to_string(directory.path().join("themes").join(name)).unwrap(),
                source,
            );
        }
    }

    #[test]
    fn each_theme_import_resolves_every_named_color_in_both_appearances() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        for &(name, source) in THEMES {
            fs::write(&config, format!("import = 'themes/{name}'\n")).unwrap();
            let loaded = Config::load(&config);
            assert_eq!(loaded.diagnostics, [], "{name}");
            let document: toml::Table = toml::from_str(source).unwrap();
            let colors = document["terminal"]["colors"].as_table().unwrap();
            assert_eq!(colors.len(), 20, "{name} has all individual color settings");
            for palette in [
                &loaded.config.terminal.palettes.light,
                &loaded.config.terminal.palettes.dark,
            ] {
                for (key, color) in [
                    ("background", &palette.background),
                    ("foreground", &palette.foreground),
                    ("cursor", &palette.cursor),
                    ("selection", &palette.selection),
                ] {
                    assert_eq!(
                        color.as_str(),
                        colors[key].as_str().unwrap(),
                        "{name}: {key}"
                    );
                }
                for (key, color) in ANSI_COLOR_NAMES.iter().zip(&palette.ansi) {
                    assert_eq!(
                        color.as_str(),
                        colors[*key].as_str().unwrap(),
                        "{name}: {key}"
                    );
                }
            }
        }
    }

    #[test]
    fn preserves_user_edits_and_ignores_unused_invalid_or_unreadable_themes() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        let _ = Config::load(&config);
        let theme = directory.path().join("themes/catppuccin_mocha.toml");
        let edited = "[terminal.colors]\nblue = '#123456'\n";
        fs::write(&theme, edited).unwrap();
        let invalid = directory.path().join("themes/dracula.toml");
        fs::write(&invalid, "invalid = @").unwrap();
        let unreadable = directory.path().join("themes/nord.toml");
        fs::remove_file(&unreadable).unwrap();
        fs::create_dir(&unreadable).unwrap();
        let loaded = Config::load(&config);
        assert_eq!(loaded.config, Config::default());
        assert_eq!(loaded.diagnostics, []);
        assert_eq!(fs::read_to_string(&theme).unwrap(), edited);
        assert_eq!(fs::read_to_string(&invalid).unwrap(), "invalid = @");
        assert!(unreadable.is_dir());
        fs::write(&config, "import = 'themes/catppuccin_mocha.toml'\n").unwrap();
        let imported = Config::load(&config);
        assert_eq!(imported.diagnostics, []);
        assert_eq!(
            imported.config.terminal.palettes.dark.ansi[4].as_str(),
            "#123456"
        );
    }
}
