use super::{
    Completion, Handoff, HandoffContent, InstanceCount, MAX_PARALLEL_AGENTS, ReviewLoop, Role,
    RoleId, Stage, StageId, StageRole, WorkflowTypeDefinition,
};

/// Built-in types ship with Twine and can be copied but not edited.
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
        match self {
            Self::Adversarial => adversarial(),
            Self::Coordinator => coordinator(),
        }
    }
}

const ADVERSARIAL_REVIEW_ROUNDS: u8 = 3;

fn adversarial() -> WorkflowTypeDefinition {
    WorkflowTypeDefinition {
        name: "Adversarial".to_owned(),
        description: "An implementer does the task and a reviewer reviews it until approval."
            .to_owned(),
        roles: vec![
            role(
                "implementer",
                "Implementer",
                "Complete the task in this folder. When the reviewer requests changes, address \
                 their feedback, then signal that you are done again.",
            ),
            role(
                "reviewer",
                "Reviewer",
                "Review the implementer's changes to this folder against the task. Approve them, \
                 or request changes with specific, actionable feedback.",
            ),
        ],
        stages: vec![
            stage(
                "implement",
                "Implement",
                &["implementer"],
                Completion::AllRolesDone {},
            ),
            stage(
                "review",
                "Review",
                &["reviewer"],
                Completion::ReviewDecision {
                    reviewer: RoleId("reviewer".to_owned()),
                },
            ),
        ],
        handoffs: vec![
            handoff(
                ("implement", "implementer"),
                ("review", "reviewer"),
                HandoffContent::Result,
            ),
            handoff(
                ("review", "reviewer"),
                ("implement", "implementer"),
                HandoffContent::Feedback,
            ),
        ],
        review_loops: vec![ReviewLoop {
            review_stage: StageId("review".to_owned()),
            back_to: StageId("implement".to_owned()),
            max_rounds: ADVERSARIAL_REVIEW_ROUNDS,
        }],
    }
}

fn coordinator() -> WorkflowTypeDefinition {
    WorkflowTypeDefinition {
        name: "Coordinator".to_owned(),
        description: "A coordinator splits the task among parallel workers and gathers their \
                      results."
            .to_owned(),
        roles: vec![
            role(
                "coordinator",
                "Coordinator",
                "Split the task into one part per worker. Give each worker a sub-task and the set \
                 of files it owns; no file may belong to more than one worker. When the workers \
                 finish, gather and check their results.",
            ),
            Role {
                instances: InstanceCount {
                    min: 2,
                    max: MAX_PARALLEL_AGENTS,
                },
                ..role(
                    "worker",
                    "Worker",
                    "Complete your sub-task. Change only the files you own; other workers are \
                     editing the rest of this folder at the same time.",
                )
            },
        ],
        stages: vec![
            stage(
                "split",
                "Split",
                &["coordinator"],
                Completion::AllRolesDone {},
            ),
            stage("work", "Work", &["worker"], Completion::AllRolesDone {}),
            stage(
                "gather",
                "Gather",
                &["coordinator"],
                Completion::AllRolesDone {},
            ),
        ],
        handoffs: vec![
            handoff(
                ("split", "coordinator"),
                ("work", "worker"),
                HandoffContent::Assignment,
            ),
            handoff(
                ("work", "worker"),
                ("gather", "coordinator"),
                HandoffContent::Result,
            ),
        ],
        review_loops: Vec::new(),
    }
}

fn role(id: &str, name: &str, instructions: &str) -> Role {
    Role {
        id: RoleId(id.to_owned()),
        name: name.to_owned(),
        instructions: instructions.to_owned(),
        instances: InstanceCount::default(),
    }
}

fn stage(id: &str, name: &str, roles: &[&str], completion: Completion) -> Stage {
    Stage {
        id: StageId(id.to_owned()),
        name: name.to_owned(),
        roles: roles
            .iter()
            .map(|role| RoleId((*role).to_owned()))
            .collect(),
        completion,
    }
}

fn handoff(from: (&str, &str), to: (&str, &str), content: HandoffContent) -> Handoff {
    let endpoint = |(stage, role): (&str, &str)| StageRole {
        stage: StageId(stage.to_owned()),
        role: RoleId(role.to_owned()),
    };
    Handoff {
        from: endpoint(from),
        to: endpoint(to),
        content,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workflow_type::validate;

    #[test]
    fn every_builtin_type_is_valid() {
        for builtin in BuiltinType::ALL {
            assert_eq!(validate(&builtin.definition()), Ok(()), "{builtin:?}");
        }
    }
}
