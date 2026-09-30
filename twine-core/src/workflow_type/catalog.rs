#![cfg_attr(
    not(test),
    expect(
        dead_code,
        reason = "commands for the workflow type catalog arrive with its UI"
    )
)]

use thiserror::Error;
use tracing::warn;

use super::{BuiltinType, ValidationIssue, WorkflowTypeDefinition, validate};
use crate::store::{Store, StoreError, StoredWorkflowType};
use crate::workflow::timestamp;

/// One exact workflow type. A workflow keeps the reference it started with.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum WorkflowTypeRef {
    /// Built-in types change only with Twine itself, so they follow the running app.
    Builtin(BuiltinType),
    /// One version of a user-made type. Versions never change once stored.
    User { type_id: u64, version: u32 },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkflowType {
    pub reference: WorkflowTypeRef,
    pub definition: WorkflowTypeDefinition,
}

/// The app-wide workflow types: the built-in ones, then every user-made one at its latest
/// version. Editing a type adds a version and never changes an earlier one.
pub(crate) struct WorkflowCatalog<'a> {
    store: &'a mut Store,
}

impl<'a> WorkflowCatalog<'a> {
    pub(crate) fn new(store: &'a mut Store) -> Self {
        Self { store }
    }

    /// Lists every type that can be used. A stored type that can't be loaded is skipped, so it
    /// never hides the others.
    pub(crate) fn list(&self) -> Result<Vec<WorkflowType>, CatalogError> {
        let mut types: Vec<_> = BuiltinType::ALL.into_iter().map(builtin).collect();
        for stored in self.store.latest_workflow_types()? {
            match parse(&stored) {
                Ok(workflow_type) => types.push(workflow_type),
                Err(error) => warn!(
                    type_id = stored.type_id,
                    version = stored.version,
                    kind = error.kind(),
                    "skipping a stored workflow type that can't be loaded"
                ),
            }
        }
        Ok(types)
    }

    pub(crate) fn get(&self, reference: WorkflowTypeRef) -> Result<WorkflowType, CatalogError> {
        match reference {
            WorkflowTypeRef::Builtin(id) => Ok(builtin(id)),
            WorkflowTypeRef::User { type_id, version } => {
                let definition = self
                    .store
                    .workflow_type_version(type_id, version)?
                    .ok_or(CatalogError::NotFound(reference))?;
                parse(&StoredWorkflowType {
                    type_id,
                    version,
                    definition,
                })
            }
        }
    }

    /// Adds a new user-made type at version 1.
    pub(crate) fn create(
        &mut self,
        definition: &WorkflowTypeDefinition,
    ) -> Result<WorkflowTypeRef, CatalogError> {
        let serialized = serialize(definition)?;
        let type_id = self.store.create_workflow_type(&serialized, timestamp())?;
        Ok(WorkflowTypeRef::User {
            type_id,
            version: 1,
        })
    }

    /// Adds the next version of a user-made type. Built-in types can only be copied.
    pub(crate) fn edit(
        &mut self,
        type_id: u64,
        definition: &WorkflowTypeDefinition,
    ) -> Result<WorkflowTypeRef, CatalogError> {
        let serialized = serialize(definition)?;
        let version = self
            .store
            .add_workflow_type_version(type_id, &serialized, timestamp())?
            .ok_or(CatalogError::UnknownType(type_id))?;
        Ok(WorkflowTypeRef::User { type_id, version })
    }

    /// Adds a user-made copy of a type, which can then be edited.
    pub(crate) fn copy(
        &mut self,
        reference: WorkflowTypeRef,
    ) -> Result<WorkflowTypeRef, CatalogError> {
        let mut definition = self.get(reference)?.definition;
        definition.name.push_str(" copy");
        self.create(&definition)
    }
}

fn builtin(id: BuiltinType) -> WorkflowType {
    WorkflowType {
        reference: WorkflowTypeRef::Builtin(id),
        definition: id.definition(),
    }
}

fn serialize(definition: &WorkflowTypeDefinition) -> Result<String, CatalogError> {
    validate(definition).map_err(CatalogError::Invalid)?;
    Ok(toml::to_string(definition)?)
}

/// Loads a stored definition, validating it again because the rules may have tightened since it
/// was stored.
fn parse(stored: &StoredWorkflowType) -> Result<WorkflowType, CatalogError> {
    let reference = WorkflowTypeRef::User {
        type_id: stored.type_id,
        version: stored.version,
    };
    let definition = toml::from_str(&stored.definition)
        .map_err(|source| CatalogError::Unreadable { reference, source })?;
    validate(&definition).map_err(|issues| CatalogError::InvalidStored { reference, issues })?;
    Ok(WorkflowType {
        reference,
        definition,
    })
}

#[derive(Debug, Error)]
pub enum CatalogError {
    #[error("the workflow type has {} problem(s)", .0.len())]
    Invalid(Vec<ValidationIssue>),
    #[error("user workflow type {0} doesn't exist")]
    UnknownType(u64),
    #[error("workflow type {0:?} doesn't exist")]
    NotFound(WorkflowTypeRef),
    #[error("stored workflow type {reference:?} can't be read")]
    Unreadable {
        reference: WorkflowTypeRef,
        #[source]
        source: toml::de::Error,
    },
    #[error("stored workflow type {reference:?} is no longer valid")]
    InvalidStored {
        reference: WorkflowTypeRef,
        issues: Vec<ValidationIssue>,
    },
    #[error("failed to serialize the workflow type")]
    Serialize(#[from] toml::ser::Error),
    #[error(transparent)]
    Store(#[from] StoreError),
}

impl CatalogError {
    /// A name for the error that is safe to log, since some errors quote stored definitions.
    fn kind(&self) -> &'static str {
        match self {
            Self::Invalid(_) => "invalid",
            Self::UnknownType(_) => "unknown_type",
            Self::NotFound(_) => "not_found",
            Self::Unreadable { .. } => "unreadable",
            Self::InvalidStored { .. } => "invalid_stored",
            Self::Serialize(_) => "serialize",
            Self::Store(_) => "store",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workflow_type::{ElementPath, ValidationProblem};

    fn user_type(name: &str) -> WorkflowTypeDefinition {
        WorkflowTypeDefinition {
            name: name.to_owned(),
            ..BuiltinType::Adversarial.definition()
        }
    }

    fn user_ref(type_id: u64, version: u32) -> WorkflowTypeRef {
        WorkflowTypeRef::User { type_id, version }
    }

    fn type_id(reference: WorkflowTypeRef) -> u64 {
        let WorkflowTypeRef::User { type_id, .. } = reference else {
            panic!("{reference:?} should be a user type");
        };
        type_id
    }

    fn names(types: Vec<WorkflowType>) -> Vec<(WorkflowTypeRef, String)> {
        types
            .into_iter()
            .map(|workflow_type| (workflow_type.reference, workflow_type.definition.name))
            .collect()
    }

    #[test]
    fn the_catalog_lists_builtin_types_then_the_latest_user_types() {
        let mut store = Store::open_in_memory().unwrap();
        let mut catalog = WorkflowCatalog::new(&mut store);
        let first = type_id(catalog.create(&user_type("First")).unwrap());
        catalog.edit(first, &user_type("First, edited")).unwrap();
        let second = catalog.create(&user_type("Second")).unwrap();

        assert_eq!(
            names(catalog.list().unwrap()),
            [
                (
                    WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
                    "Adversarial".to_owned()
                ),
                (
                    WorkflowTypeRef::Builtin(BuiltinType::Coordinator),
                    "Coordinator".to_owned()
                ),
                (user_ref(first, 2), "First, edited".to_owned()),
                (second, "Second".to_owned()),
            ]
        );
    }

    #[test]
    fn editing_adds_a_version_and_keeps_pinned_versions_unchanged() {
        let mut store = Store::open_in_memory().unwrap();
        let mut catalog = WorkflowCatalog::new(&mut store);
        let original = user_type("Original");
        let pinned = catalog.create(&original).unwrap();

        let edited = catalog.edit(type_id(pinned), &user_type("Edited")).unwrap();

        assert_eq!(edited, user_ref(type_id(pinned), 2));
        assert_eq!(catalog.get(pinned).unwrap().definition, original);
        assert_eq!(catalog.get(edited).unwrap().definition.name, "Edited");
    }

    #[test]
    fn invalid_types_are_rejected_without_being_stored() {
        let mut store = Store::open_in_memory().unwrap();
        let mut catalog = WorkflowCatalog::new(&mut store);
        let valid = type_id(catalog.create(&user_type("Valid")).unwrap());
        let mut invalid = user_type("Invalid");
        invalid.review_loops[0].max_rounds = 0;

        for result in [catalog.create(&invalid), catalog.edit(valid, &invalid)] {
            let Err(CatalogError::Invalid(issues)) = result else {
                panic!("the invalid type should be rejected: {result:?}");
            };
            assert_eq!(issues[0].element, ElementPath::ReviewLoop(0));
            assert_eq!(issues[0].problem, ValidationProblem::InvalidMaxRounds(0));
        }
        assert_eq!(catalog.list().unwrap().len(), BuiltinType::ALL.len() + 1);
        assert!(matches!(
            catalog.get(user_ref(valid, 2)),
            Err(CatalogError::NotFound(_))
        ));
    }

    #[test]
    fn copies_of_builtin_types_are_editable_user_types() {
        let mut store = Store::open_in_memory().unwrap();
        let mut catalog = WorkflowCatalog::new(&mut store);
        for builtin in BuiltinType::ALL {
            let copy = catalog.copy(WorkflowTypeRef::Builtin(builtin)).unwrap();
            let loaded = catalog.get(copy).unwrap().definition;
            assert_eq!(
                loaded,
                WorkflowTypeDefinition {
                    name: format!("{} copy", builtin.definition().name),
                    ..builtin.definition()
                }
            );
            assert_eq!(
                catalog.edit(type_id(copy), &user_type("Mine")).unwrap(),
                user_ref(type_id(copy), 2)
            );
        }
    }

    #[test]
    fn copies_start_from_the_given_version() {
        let mut store = Store::open_in_memory().unwrap();
        let mut catalog = WorkflowCatalog::new(&mut store);
        let draft = catalog.create(&user_type("Draft")).unwrap();
        let last = catalog.edit(type_id(draft), &user_type("Final")).unwrap();

        let copy = catalog.copy(last).unwrap();

        assert_ne!(type_id(copy), type_id(draft));
        assert_eq!(catalog.get(copy).unwrap().definition.name, "Final copy");
    }

    #[test]
    fn missing_types_and_versions_are_reported() {
        let mut store = Store::open_in_memory().unwrap();
        let mut catalog = WorkflowCatalog::new(&mut store);

        assert!(matches!(
            catalog.edit(42, &user_type("Nothing")),
            Err(CatalogError::UnknownType(42))
        ));
        assert!(matches!(
            catalog.copy(user_ref(42, 1)),
            Err(CatalogError::NotFound(reference)) if reference == user_ref(42, 1)
        ));
    }

    #[test]
    fn stored_types_that_cant_be_loaded_are_skipped_in_the_list() {
        let mut store = Store::open_in_memory().unwrap();
        let unreadable = store
            .create_workflow_type("not a workflow type", 0)
            .unwrap();
        let mut invalid = user_type("No longer valid");
        invalid.review_loops[0].max_rounds = 0;
        let invalid = store
            .create_workflow_type(&toml::to_string(&invalid).unwrap(), 0)
            .unwrap();
        let mut catalog = WorkflowCatalog::new(&mut store);
        let kept = catalog.create(&user_type("Kept")).unwrap();

        assert!(matches!(
            catalog.get(user_ref(unreadable, 1)),
            Err(CatalogError::Unreadable { .. })
        ));
        assert!(matches!(
            catalog.get(user_ref(invalid, 1)),
            Err(CatalogError::InvalidStored { .. })
        ));
        assert_eq!(
            names(catalog.list().unwrap()),
            [
                (
                    WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
                    "Adversarial".to_owned()
                ),
                (
                    WorkflowTypeRef::Builtin(BuiltinType::Coordinator),
                    "Coordinator".to_owned()
                ),
                (kept, "Kept".to_owned()),
            ]
        );
    }
}
