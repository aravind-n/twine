use super::{Application, ApplicationError, CommandDisposition, RequestId};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::workflow_type::{
    WorkflowCatalog, WorkflowTypeDefinition, WorkflowTypeRef, validate_editable,
};

impl Application {
    pub(super) fn delete_workflow_type(
        &self,
        request_id: RequestId,
        reference: WorkflowTypeRef,
        expected_definition: &WorkflowTypeDefinition,
    ) -> Result<CommandDisposition, ApplicationError> {
        let mut inner = self.lock_inner()?;
        let mut catalog = WorkflowCatalog::new(inner.folders.store());
        if let Err(error) = catalog.delete(reference, expected_definition) {
            return Ok(super::rejection("deleteWorkflowTypeFailed", &error));
        }
        let types = catalog.list()?;
        inner.workflow_types_cache.clone_from(&types);
        inner
            .events
            .append(EventKind::State(StateEvent::WorkflowTypesChanged(types)))?;
        inner.events.append(EventKind::CommandCompleted {
            request_id,
            result: CommandResult::WorkflowTypeDeleted { reference },
        })?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn validate_workflow_type(
        &self,
        request_id: RequestId,
        definition: &WorkflowTypeDefinition,
    ) -> Result<CommandDisposition, ApplicationError> {
        self.lock_inner()?
            .events
            .append(EventKind::CommandCompleted {
                request_id,
                result: CommandResult::WorkflowTypeValidated {
                    issues: validate_editable(definition).err().unwrap_or_default(),
                },
            })?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn save_workflow_type(
        &self,
        request_id: RequestId,
        source: Option<WorkflowTypeRef>,
        definition: &WorkflowTypeDefinition,
        expected_definition: Option<&WorkflowTypeDefinition>,
    ) -> Result<CommandDisposition, ApplicationError> {
        if validate_editable(definition).is_err() {
            return self.validate_workflow_type(request_id, definition);
        }
        let mut inner = self.lock_inner()?;
        let mut catalog = WorkflowCatalog::new(inner.folders.store());
        // Verify the source version before adding a new one. Built-ins are always copied.
        if let Some(source) = source
            && let Err(error) = catalog.get(source)
        {
            return Ok(super::rejection("invalidWorkflowType", &error));
        }
        let reference = match source {
            Some(source @ WorkflowTypeRef::User { .. }) => {
                catalog.edit_version(source, definition, expected_definition)
            }
            _ => catalog.create(definition),
        };
        let reference = match reference {
            Ok(reference) => reference,
            Err(error) => return Ok(super::rejection("saveWorkflowTypeFailed", &error)),
        };
        let types = catalog.list()?;
        inner.workflow_types_cache.clone_from(&types);
        inner
            .events
            .append(EventKind::State(StateEvent::WorkflowTypesChanged(types)))?;
        inner.events.append(EventKind::CommandCompleted {
            request_id,
            result: CommandResult::WorkflowTypeSaved { reference },
        })?;
        Ok(CommandDisposition::Accepted)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{BuiltinType, Command, ElementPath};

    fn save(app: &Application, source: Option<WorkflowTypeRef>, name: &str) -> WorkflowTypeRef {
        let mut definition = BuiltinType::Adversarial.definition();
        definition.name = name.into();
        let cursor = app.snapshot().unwrap().sequence;
        app.handle_command(
            RequestId(1),
            Command::SaveWorkflowType {
                source,
                definition,
                expected_definition: None,
            },
        )
        .unwrap();
        let events = app.events_after(cursor, 10).unwrap();
        assert!(matches!(
            &events[0].kind,
            EventKind::State(StateEvent::WorkflowTypesChanged(_))
        ));
        let EventKind::CommandCompleted {
            result: CommandResult::WorkflowTypeSaved { reference },
            ..
        } = events[1].kind
        else {
            panic!("save must return its new reference")
        };
        reference
    }

    #[test]
    fn deleting_a_workflow_updates_the_catalog_and_keeps_pinned_versions_readable() {
        let app = Application::with_event_capacity(32).unwrap();
        let first = save(&app, None, "Delete test");
        let latest = save(&app, Some(first), "Delete test");
        let other = save(&app, None, "Keep test");
        let definition = app
            .workflow_types()
            .unwrap()
            .into_iter()
            .find(|value| value.reference == latest)
            .unwrap()
            .definition;
        let cursor = app.snapshot().unwrap().sequence;
        let receipt = app
            .handle_command(
                RequestId(2),
                Command::DeleteWorkflowType {
                    reference: latest,
                    expected_definition: Box::new(definition.clone()),
                },
            )
            .unwrap();
        assert_eq!(receipt.disposition, CommandDisposition::Accepted);
        let events = app.events_after(cursor, 10).unwrap();
        assert!(matches!(&events[0].kind,
            EventKind::State(StateEvent::WorkflowTypesChanged(types))
                if types.iter().all(|value| value.reference != latest)
                    && types.iter().any(|value| value.reference == other)));
        assert!(matches!(&events[1].kind,
            EventKind::CommandCompleted { result: CommandResult::WorkflowTypeDeleted { reference }, .. }
                if *reference == latest));
        let mut inner = app.lock_inner().unwrap();
        assert!(
            !inner
                .folders
                .store()
                .workflow_directory
                .join("delete_test.toml")
                .exists()
        );
        let catalog = WorkflowCatalog::new(inner.folders.store());
        for reference in [first, latest] {
            assert_eq!(catalog.get(reference).unwrap().definition, definition);
        }
        drop(inner);
        assert_ne!(save(&app, None, "Delete test"), latest);
    }

    #[test]
    fn deletion_rejects_builtins_and_obsolete_confirmations() {
        let app = Application::with_event_capacity(32).unwrap();
        let first = save(&app, None, "Stale delete");
        let latest = save(&app, Some(first), "Stale delete");
        let mut definition = BuiltinType::Adversarial.definition();
        definition.name = "Stale delete".into();
        let before = app.workflow_types().unwrap();
        for reference in [first, WorkflowTypeRef::Builtin(BuiltinType::Adversarial)] {
            let receipt = app
                .handle_command(
                    RequestId(2),
                    Command::DeleteWorkflowType {
                        reference,
                        expected_definition: Box::new(definition.clone()),
                    },
                )
                .unwrap();
            assert!(matches!(
                receipt.disposition,
                CommandDisposition::Rejected { .. }
            ));
        }
        definition.description.push_str(" External edit.");
        let receipt = app
            .handle_command(
                RequestId(3),
                Command::DeleteWorkflowType {
                    reference: latest,
                    expected_definition: Box::new(definition),
                },
            )
            .unwrap();
        assert!(matches!(
            receipt.disposition,
            CommandDisposition::Rejected { .. }
        ));
        assert_eq!(app.workflow_types().unwrap(), before);
    }

    #[test]
    fn duplicate_name_rejections_explain_that_a_workflow_already_exists() {
        let app = Application::with_event_capacity(32).unwrap();
        save(&app, None, "Review!");
        let mut definition = BuiltinType::Adversarial.definition();
        definition.name = "review!".to_owned();
        let result = app
            .handle_command(
                RequestId(2),
                Command::SaveWorkflowType {
                    source: None,
                    definition,
                    expected_definition: None,
                },
            )
            .unwrap();
        let CommandDisposition::Rejected { message, .. } = result.disposition else {
            panic!("duplicate names must be rejected");
        };
        assert_eq!(message, "A workflow with this name already exists.");
    }

    #[test]
    fn saving_builtin_edits_creates_a_copy_and_custom_edits_preserve_versions() {
        let app = Application::with_event_capacity(32).unwrap();
        let builtin = WorkflowTypeRef::Builtin(BuiltinType::Adversarial);
        let first = save(&app, Some(builtin), "Custom review");
        let second = save(&app, Some(first), "Custom review v2");
        let mut inner = app.lock_inner().unwrap();
        let catalog = WorkflowCatalog::new(inner.folders.store());
        assert_eq!(
            catalog.get(builtin).unwrap().definition,
            BuiltinType::Adversarial.definition()
        );
        assert_eq!(catalog.get(first).unwrap().definition.name, "Custom review");
        assert_eq!(
            catalog.get(second).unwrap().definition.name,
            "Custom review v2"
        );
        assert_eq!(catalog.list().unwrap().len(), 3);
        assert!(matches!(second, WorkflowTypeRef::User { version: 2, .. }));
    }

    #[test]
    fn file_edits_refresh_the_catalog_and_stale_editor_saves_keep_external_changes() {
        let app = Application::with_event_capacity(32).unwrap();
        let reference = save(&app, None, "Original");
        let baseline = WorkflowCatalog::new(app.lock_inner().unwrap().folders.store())
            .get(reference)
            .unwrap()
            .definition;
        let directory = app
            .lock_inner()
            .unwrap()
            .folders
            .store()
            .workflow_directory
            .clone();
        let file = std::fs::read_dir(directory)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| path.extension().is_some_and(|ext| ext == "toml"))
            .unwrap();
        let original = std::fs::read_to_string(&file).unwrap();
        let sequence = app.snapshot().unwrap().sequence;
        std::fs::write(&file, original.replace("Original", "External edit")).unwrap();
        app.lock_inner().unwrap().workflow_types_polled = None;
        let events = app.events_after(sequence, 10).unwrap();
        assert!(events.iter().any(|event| matches!(&event.kind, EventKind::State(StateEvent::WorkflowTypesChanged(types)) if types.iter().any(|ty| ty.definition.name == "External edit"))));
        let result = app
            .handle_command(
                RequestId(2),
                Command::SaveWorkflowType {
                    source: Some(reference),
                    definition: baseline.clone(),
                    expected_definition: Some(Box::new(baseline)),
                },
            )
            .unwrap();
        assert!(matches!(
            result.disposition,
            CommandDisposition::Rejected { .. }
        ));
        assert!(
            std::fs::read_to_string(file)
                .unwrap()
                .contains("External edit")
        );
    }

    #[test]
    fn invalid_save_reports_elements_without_changing_the_catalog() {
        let app = Application::with_event_capacity(32).unwrap();
        let mut definition = BuiltinType::Adversarial.definition();
        definition.roles[0].instructions.clear();
        definition.graph.as_mut().unwrap().max_activations = 0;
        let before = app.snapshot().unwrap();
        app.handle_command(
            RequestId(1),
            Command::SaveWorkflowType {
                expected_definition: None,
                source: None,
                definition,
            },
        )
        .unwrap();
        let events = app.events_after(before.sequence, 10).unwrap();
        assert_eq!(events.len(), 1);
        let EventKind::CommandCompleted {
            result: CommandResult::WorkflowTypeValidated { issues },
            ..
        } = &events[0].kind
        else {
            panic!("invalid save must return validation issues")
        };
        assert!(
            issues
                .iter()
                .any(|issue| issue.element == ElementPath::Role(0))
        );
        assert!(
            issues
                .iter()
                .any(|issue| issue.element == ElementPath::Graph)
        );
        assert_eq!(
            app.snapshot().unwrap().workflow_types,
            before.workflow_types
        );
    }
}
