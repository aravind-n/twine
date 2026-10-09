//! Configuration reloads publish state without changing any workflows or terminal processes.

use std::path::Path;

use super::{Application, ApplicationError, CommandDisposition};
use crate::config::{Config, ConfigProblem};
use crate::event::{EventKind, StateEvent};

impl Application {
    pub(super) fn reload_config(&self) -> Result<CommandDisposition, ApplicationError> {
        let Some(path) = Config::user_path() else {
            return Ok(CommandDisposition::Rejected {
                code: "invalidConfig".into(),
                message: "Cannot find the user config directory.".into(),
            });
        };
        self.reload_config_from(&path)
    }

    fn reload_config_from(&self, path: &Path) -> Result<CommandDisposition, ApplicationError> {
        let loaded = Config::load(path);
        for diagnostic in &loaded.diagnostics {
            if diagnostic.problem == ConfigProblem::UnknownKey {
                tracing::warn!(%diagnostic, "configuration warning");
            } else {
                return Ok(CommandDisposition::Rejected {
                    code: "invalidConfig".into(),
                    message: format!("Cannot apply settings: {diagnostic}"),
                });
            }
        }
        let mut inner = self.lock_inner()?;
        if inner.config != loaded.config {
            inner
                .folders
                .store()
                .configure_trace_storage(&loaded.config.traces)?;
            inner
                .events
                .append(EventKind::State(StateEvent::ConfigChanged(Box::new(
                    loaded.config.clone(),
                ))))?;
            inner.config = loaded.config;
        }
        Ok(CommandDisposition::Accepted)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reload_publishes_atomic_config_changes_and_rejects_invalid_settings() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let app = Application::with_event_capacity(64).unwrap();
        app.handle_command(
            super::super::RequestId(1),
            super::super::Command::StartTerminal {
                working_directory: directory.path().to_owned(),
                size: crate::TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
            },
        )
        .unwrap();
        let before = app.snapshot().unwrap();
        std::fs::write(
            &path,
            "[terminal]\nfont_size = 18\n[terminal.colors]\nblue = '#123456'\n",
        )
        .unwrap();
        assert_eq!(
            app.reload_config_from(&path).unwrap(),
            CommandDisposition::Accepted
        );
        let updated = app.snapshot().unwrap();
        assert_eq!(updated.config.terminal.font_size.points(), 18.0);
        assert_eq!(
            updated.config.terminal.palettes.dark.ansi[4].as_str(),
            "#123456"
        );
        assert_eq!(updated.workflows, before.workflows);
        assert_eq!(updated.terminals, before.terminals);
        assert_eq!(updated.terminals.len(), 1);
        let events = app.events_after(before.sequence, 64).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].sequence, updated.sequence);
        assert_eq!(
            events[0].kind,
            EventKind::State(StateEvent::ConfigChanged(Box::new(updated.config.clone())))
        );
        assert_eq!(
            app.reload_config_from(&path).unwrap(),
            CommandDisposition::Accepted
        );
        assert_eq!(app.snapshot().unwrap().sequence, updated.sequence);
        for source in [
            "terminal.font_size = 100\n",
            "import = 'missing.toml'\n",
            "invalid = @\n",
        ] {
            std::fs::write(&path, source).unwrap();
            assert!(matches!(
                app.reload_config_from(&path).unwrap(),
                CommandDisposition::Rejected { .. }
            ));
            assert_eq!(app.snapshot().unwrap(), updated);
        }
    }
}
