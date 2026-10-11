use std::sync::LazyLock;

use super::{WorkflowTypeDefinition, files};

/// Stable identities for the default TOML graphs shipped with Twine.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BuiltinType {
    Adversarial,
    Coordinator,
}

impl BuiltinType {
    pub const ALL: [Self; 2] = [Self::Adversarial, Self::Coordinator];

    #[must_use]
    pub fn definition(self) -> WorkflowTypeDefinition {
        static ADVERSARIAL: LazyLock<WorkflowTypeDefinition> =
            LazyLock::new(|| load(BuiltinType::Adversarial));
        static COORDINATOR: LazyLock<WorkflowTypeDefinition> =
            LazyLock::new(|| load(BuiltinType::Coordinator));
        match self {
            Self::Adversarial => ADVERSARIAL.clone(),
            Self::Coordinator => COORDINATOR.clone(),
        }
    }

    const fn contents(self) -> &'static str {
        match self {
            Self::Adversarial => include_str!("../../workflows/adversarial.toml"),
            Self::Coordinator => include_str!("../../workflows/coordinator.toml"),
        }
    }

    /// Historical defaults test saved stage-based runs without changing today's built-ins.
    #[cfg(test)]
    pub(crate) fn legacy_definition(self) -> WorkflowTypeDefinition {
        let contents = match self {
            Self::Adversarial => include_str!("../../tests/fixtures/legacy-adversarial.toml"),
            Self::Coordinator => include_str!("../../tests/fixtures/legacy-coordinator.toml"),
        };
        toml::from_str(contents).expect("legacy workflow fixture must parse")
    }
}

fn load(builtin: BuiltinType) -> WorkflowTypeDefinition {
    files::decode(builtin.contents())
        .expect("bundled workflow TOML must be valid")
        .definition
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workflow_type::{GraphReceive, InstanceCount, validate};

    #[test]
    fn legacy_defaults_remain_readable() {
        for builtin in BuiltinType::ALL {
            assert_eq!(validate(&builtin.legacy_definition()), Ok(()));
        }
    }

    #[test]
    fn every_builtin_is_an_agent_only_graph() {
        for builtin in BuiltinType::ALL {
            let definition = builtin.definition();
            assert_eq!(validate(&definition), Ok(()), "{builtin:?}");
            assert_eq!(definition.stages, []);
            assert_eq!(definition.handoffs, []);
            assert_eq!(definition.review_loops, []);
            let graph = definition.graph.as_ref().unwrap();
            for role in &definition.roles {
                assert_eq!(role.instances, InstanceCount::default());
            }
            for edge in &graph.edges {
                assert!(definition.roles.iter().any(|role| role.id.0 == edge.from));
                assert!(definition.roles.iter().any(|role| role.id.0 == edge.to));
            }
        }
    }

    #[test]
    fn bundled_graphs_can_be_read_as_user_workflow_files() {
        let directory = tempfile::tempdir().unwrap();
        for builtin in BuiltinType::ALL {
            let path = directory.path().join("workflow.toml");
            std::fs::write(&path, builtin.contents()).unwrap();
            assert_eq!(files::read(&path).unwrap().definition, builtin.definition());
        }
    }

    #[test]
    fn coordinator_waits_for_both_distinct_workers() {
        let definition = BuiltinType::Coordinator.definition();
        let graph = definition.graph.unwrap();
        assert_eq!(definition.roles.len(), 4);
        assert!(graph.is_start("planner"));
        assert!(graph.is_result("coordinator"));
        assert_eq!(graph.receive.get("coordinator"), Some(&GraphReceive::All));
        let incoming: Vec<_> = graph
            .edges
            .iter()
            .filter(|edge| edge.to == "coordinator")
            .collect();
        assert_eq!(incoming.len(), 2);
        assert!(incoming.iter().any(|edge| edge.from == "worker-1"));
        assert!(incoming.iter().any(|edge| edge.from == "worker-2"));
    }
}
