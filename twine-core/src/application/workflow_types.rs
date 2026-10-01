use super::{Application, ApplicationError, CommandDisposition, RequestId};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::workflow_type::{WorkflowCatalog, WorkflowTypeDefinition, WorkflowTypeRef, validate};

impl Application {
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
                    issues: validate(definition).err().unwrap_or_default(),
                },
            })?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn save_workflow_type(
        &self,
        request_id: RequestId,
        source: Option<WorkflowTypeRef>,
        definition: &WorkflowTypeDefinition,
    ) -> Result<CommandDisposition, ApplicationError> {
        if validate(definition).is_err() {
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
            Some(WorkflowTypeRef::User { type_id, .. }) => catalog.edit(type_id, definition),
            _ => catalog.create(definition),
        };
        let reference = match reference {
            Ok(reference) => reference,
            Err(error) => return Ok(super::rejection("saveWorkflowTypeFailed", &error)),
        };
        let types = catalog.list()?;
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
            Command::SaveWorkflowType { source, definition },
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
    fn invalid_save_reports_elements_without_changing_the_catalog() {
        let app = Application::with_event_capacity(32).unwrap();
        let mut definition = BuiltinType::Adversarial.definition();
        definition.roles[0].instructions.clear();
        definition.review_loops[0].max_rounds = 0;
        let before = app.snapshot().unwrap();
        app.handle_command(
            RequestId(1),
            Command::SaveWorkflowType {
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
                .any(|issue| issue.element == ElementPath::ReviewLoop(0))
        );
        assert_eq!(
            app.snapshot().unwrap().workflow_types,
            before.workflow_types
        );
    }
}
