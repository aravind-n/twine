use std::collections::{HashMap, HashSet};
use std::fmt;

use thiserror::Error;

use super::{
    Completion, HandoffContent, MAX_PARALLEL_AGENTS, MAX_REVIEW_ROUNDS, Role, RoleId, StageId,
    StageRole, WorkflowTypeDefinition,
};

/// The element of a definition that an issue points at. Indexes are positions in the
/// definition's lists, so they stay unambiguous even when two elements share an ID.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ElementPath {
    Name,
    Roles,
    Stages,
    Role(usize),
    Stage(usize),
    Handoff(usize),
    ReviewLoop(usize),
}

impl fmt::Display for ElementPath {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Name => formatter.write_str("name"),
            Self::Roles => formatter.write_str("roles"),
            Self::Stages => formatter.write_str("stages"),
            Self::Role(index) => write!(formatter, "roles[{index}]"),
            Self::Stage(index) => write!(formatter, "stages[{index}]"),
            Self::Handoff(index) => write!(formatter, "handoffs[{index}]"),
            Self::ReviewLoop(index) => write!(formatter, "review_loops[{index}]"),
        }
    }
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
#[error("{element}: {problem}")]
pub struct ValidationIssue {
    pub element: ElementPath,
    pub problem: ValidationProblem,
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum ValidationProblem {
    #[error("needs a name")]
    MissingName,
    #[error("name must be a single line")]
    MultilineName,
    #[error("needs at least one role")]
    NoRoles,
    #[error("needs at least one stage")]
    NoStages,
    #[error("needs an ID")]
    MissingId,
    #[error("ID is already used")]
    DuplicateId,
    #[error("needs instructions")]
    MissingInstructions,
    #[error("instance count {min}–{max} must be between 1 and {MAX_PARALLEL_AGENTS}")]
    InvalidInstanceCount { min: u8, max: u8 },
    #[error("role isn't used by any stage")]
    UnusedRole,
    #[error("needs at least one role")]
    EmptyStage,
    #[error("role `{0}` doesn't exist")]
    UnknownRole(RoleId),
    #[error("stage `{0}` doesn't exist")]
    UnknownStage(StageId),
    #[error("role `{0}` appears more than once")]
    RepeatedRole(RoleId),
    #[error("runs up to {count} agents at once; the limit is {MAX_PARALLEL_AGENTS}")]
    TooManyAgents { count: usize },
    #[error("role `{role}` doesn't run in stage `{stage}`")]
    RoleNotInStage { role: RoleId, stage: StageId },
    #[error("reviewer `{0}` must be a single agent")]
    ReviewerNotSingle(RoleId),
    #[error("a review stage needs a review loop")]
    ReviewWithoutLoop,
    #[error("role `{0}` receives no handoff from the previous stage")]
    MissingHandoff(RoleId),
    #[error("must go to the next stage")]
    HandoffNotForward,
    #[error("feedback must follow a review loop")]
    FeedbackOutsideReviewLoop,
    #[error("feedback must come from the reviewer, not `{0}`")]
    FeedbackNotFromReviewer(RoleId),
    #[error("stage `{0}` doesn't end with a review decision")]
    NotAReviewStage(StageId),
    #[error("must go back to an earlier stage")]
    LoopNotBackward,
    #[error("stage already has a review loop")]
    DuplicateReviewLoop,
    #[error("max rounds {0} must be between 1 and {MAX_REVIEW_ROUNDS}")]
    InvalidMaxRounds(u8),
    #[error("needs a feedback handoff back to the earlier stage")]
    LoopWithoutFeedback,
}

/// Checks that every reference resolves and that loops and parallelism stay bounded.
///
/// # Errors
///
/// Returns every issue found, each pointing at the offending element.
pub fn validate(definition: &WorkflowTypeDefinition) -> Result<(), Vec<ValidationIssue>> {
    let mut validator = Validator {
        definition,
        roles: HashMap::new(),
        stages: HashMap::new(),
        issues: Vec::new(),
    };
    validator.check_name();
    validator.check_roles();
    validator.check_stages();
    let loops = validator.check_review_loops();
    validator.check_handoffs(&loops);
    if validator.issues.is_empty() {
        Ok(())
    } else {
        Err(validator.issues)
    }
}

struct Validator<'a> {
    definition: &'a WorkflowTypeDefinition,
    /// The first role with each ID, when that role has a valid instance count.
    roles: HashMap<&'a RoleId, &'a Role>,
    /// The position of the first stage with each ID.
    stages: HashMap<&'a StageId, usize>,
    issues: Vec<ValidationIssue>,
}

/// A review loop whose stages resolve, as positions in the stage list.
struct ResolvedLoop {
    index: usize,
    review_stage: usize,
    back_to: usize,
}

impl Validator<'_> {
    fn report(&mut self, element: ElementPath, problem: ValidationProblem) {
        self.issues.push(ValidationIssue { element, problem });
    }

    fn check_name(&mut self) {
        let name = &self.definition.name;
        if name.trim().is_empty() {
            self.report(ElementPath::Name, ValidationProblem::MissingName);
        } else if name.chars().any(char::is_control) {
            self.report(ElementPath::Name, ValidationProblem::MultilineName);
        }
    }

    fn check_roles(&mut self) {
        let definition = self.definition;
        if definition.roles.is_empty() {
            self.report(ElementPath::Roles, ValidationProblem::NoRoles);
        }
        let mut seen = HashSet::new();
        for (index, role) in definition.roles.iter().enumerate() {
            let element = ElementPath::Role(index);
            if role.id.0.is_empty() {
                self.report(element, ValidationProblem::MissingId);
            } else if !seen.insert(&role.id) {
                self.report(element, ValidationProblem::DuplicateId);
            }
            if role.name.trim().is_empty() {
                self.report(element, ValidationProblem::MissingName);
            }
            if role.instructions.trim().is_empty() {
                self.report(element, ValidationProblem::MissingInstructions);
            }
            let count = role.instances;
            if count.min == 0 || count.min > count.max || count.max > MAX_PARALLEL_AGENTS {
                self.report(
                    element,
                    ValidationProblem::InvalidInstanceCount {
                        min: count.min,
                        max: count.max,
                    },
                );
            } else {
                self.roles.entry(&role.id).or_insert(role);
            }
        }
        let used: HashSet<_> = definition
            .stages
            .iter()
            .flat_map(|stage| &stage.roles)
            .collect();
        for (index, role) in definition.roles.iter().enumerate() {
            if !role.id.0.is_empty() && !used.contains(&role.id) {
                self.report(ElementPath::Role(index), ValidationProblem::UnusedRole);
            }
        }
    }

    fn check_stages(&mut self) {
        let definition = self.definition;
        if definition.stages.is_empty() {
            self.report(ElementPath::Stages, ValidationProblem::NoStages);
        }
        for (index, stage) in definition.stages.iter().enumerate() {
            let element = ElementPath::Stage(index);
            if stage.id.0.is_empty() {
                self.report(element, ValidationProblem::MissingId);
            } else if self.stages.contains_key(&stage.id) {
                self.report(element, ValidationProblem::DuplicateId);
            } else {
                self.stages.insert(&stage.id, index);
            }
            if stage.name.trim().is_empty() {
                self.report(element, ValidationProblem::MissingName);
            }
            if stage.roles.is_empty() {
                self.report(element, ValidationProblem::EmptyStage);
            }
            let mut seen = HashSet::new();
            let mut agents = 0;
            for role_id in &stage.roles {
                if !seen.insert(role_id) {
                    self.report(element, ValidationProblem::RepeatedRole(role_id.clone()));
                } else if let Some(role) = self.roles.get(role_id) {
                    agents += usize::from(role.instances.max);
                } else if self.is_known_role(role_id) {
                    // The role exists but its instance count is already reported.
                } else {
                    self.report(element, ValidationProblem::UnknownRole(role_id.clone()));
                }
            }
            if agents > usize::from(MAX_PARALLEL_AGENTS) {
                self.report(element, ValidationProblem::TooManyAgents { count: agents });
            }
            if let Completion::ReviewDecision { reviewer } = &stage.completion {
                if !self.is_known_role(reviewer) {
                    self.report(element, ValidationProblem::UnknownRole(reviewer.clone()));
                } else if !stage.roles.contains(reviewer) {
                    self.report(
                        element,
                        ValidationProblem::RoleNotInStage {
                            role: reviewer.clone(),
                            stage: stage.id.clone(),
                        },
                    );
                } else if self
                    .roles
                    .get(reviewer)
                    .is_some_and(|role| role.instances.max > 1)
                {
                    self.report(
                        element,
                        ValidationProblem::ReviewerNotSingle(reviewer.clone()),
                    );
                }
            }
        }
    }

    fn is_known_role(&self, id: &RoleId) -> bool {
        self.definition.roles.iter().any(|role| &role.id == id)
    }

    fn check_review_loops(&mut self) -> Vec<ResolvedLoop> {
        let definition = self.definition;
        let mut resolved = Vec::new();
        let mut looped_stages = HashSet::new();
        for (index, review_loop) in definition.review_loops.iter().enumerate() {
            let element = ElementPath::ReviewLoop(index);
            if !(1..=MAX_REVIEW_ROUNDS).contains(&review_loop.max_rounds) {
                self.report(
                    element,
                    ValidationProblem::InvalidMaxRounds(review_loop.max_rounds),
                );
            }
            let review_stage = self.stage_index(element, &review_loop.review_stage);
            let back_to = self.stage_index(element, &review_loop.back_to);
            let (Some(review_stage), Some(back_to)) = (review_stage, back_to) else {
                continue;
            };
            if !looped_stages.insert(review_stage) {
                self.report(element, ValidationProblem::DuplicateReviewLoop);
            }
            let mut valid = true;
            if !matches!(
                definition.stages[review_stage].completion,
                Completion::ReviewDecision { .. }
            ) {
                self.report(
                    element,
                    ValidationProblem::NotAReviewStage(review_loop.review_stage.clone()),
                );
                valid = false;
            }
            if back_to >= review_stage {
                self.report(element, ValidationProblem::LoopNotBackward);
                valid = false;
            }
            if valid {
                resolved.push(ResolvedLoop {
                    index,
                    review_stage,
                    back_to,
                });
            }
        }
        for (index, stage) in definition.stages.iter().enumerate() {
            if matches!(stage.completion, Completion::ReviewDecision { .. })
                && !looped_stages.contains(&index)
            {
                self.report(
                    ElementPath::Stage(index),
                    ValidationProblem::ReviewWithoutLoop,
                );
            }
        }
        resolved
    }

    fn check_handoffs(&mut self, loops: &[ResolvedLoop]) {
        let definition = self.definition;
        let mut forward = HashSet::new();
        let mut looped_back = HashSet::new();
        for (index, handoff) in definition.handoffs.iter().enumerate() {
            let element = ElementPath::Handoff(index);
            let from = self.endpoint(element, &handoff.from);
            let to = self.endpoint(element, &handoff.to);
            let (Some(from), Some(to)) = (from, to) else {
                continue;
            };
            if handoff.content == HandoffContent::Feedback {
                let review_loop = loops.iter().find(|review_loop| {
                    review_loop.review_stage == from && review_loop.back_to == to
                });
                // A reviewer outside the stage is already reported on the stage itself.
                let review_stage = &definition.stages[from];
                let reviewer = match &review_stage.completion {
                    Completion::ReviewDecision { reviewer } => {
                        Some(reviewer).filter(|reviewer| review_stage.roles.contains(reviewer))
                    }
                    Completion::AllRolesDone {} => None,
                };
                match review_loop {
                    None => self.report(element, ValidationProblem::FeedbackOutsideReviewLoop),
                    Some(_) if reviewer.is_some_and(|reviewer| reviewer != &handoff.from.role) => {
                        self.report(
                            element,
                            ValidationProblem::FeedbackNotFromReviewer(handoff.from.role.clone()),
                        );
                    }
                    Some(review_loop) => {
                        looped_back.insert(review_loop.index);
                    }
                }
            } else if to == from + 1 {
                forward.insert((to, &handoff.to.role));
            } else {
                self.report(element, ValidationProblem::HandoffNotForward);
            }
        }
        for (index, stage) in definition.stages.iter().enumerate().skip(1) {
            for role in &stage.roles {
                if !forward.contains(&(index, role)) {
                    self.report(
                        ElementPath::Stage(index),
                        ValidationProblem::MissingHandoff(role.clone()),
                    );
                }
            }
        }
        for review_loop in loops {
            if !looped_back.contains(&review_loop.index) {
                self.report(
                    ElementPath::ReviewLoop(review_loop.index),
                    ValidationProblem::LoopWithoutFeedback,
                );
            }
        }
    }

    fn stage_index(&mut self, element: ElementPath, id: &StageId) -> Option<usize> {
        let index = self.stages.get(id).copied();
        if index.is_none() {
            self.report(element, ValidationProblem::UnknownStage(id.clone()));
        }
        index
    }

    /// Resolves a handoff endpoint to its stage position, reporting what doesn't resolve.
    fn endpoint(&mut self, element: ElementPath, endpoint: &StageRole) -> Option<usize> {
        let index = self.stage_index(element, &endpoint.stage)?;
        if !self.is_known_role(&endpoint.role) {
            self.report(
                element,
                ValidationProblem::UnknownRole(endpoint.role.clone()),
            );
            return None;
        }
        if !self.definition.stages[index].roles.contains(&endpoint.role) {
            self.report(
                element,
                ValidationProblem::RoleNotInStage {
                    role: endpoint.role.clone(),
                    stage: endpoint.stage.clone(),
                },
            );
            return None;
        }
        Some(index)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workflow_type::{Handoff, InstanceCount, ReviewLoop, Stage};

    /// A lead splits the work for 2–3 workers, and a reviewer can send it back to them.
    const VALID: &str = r#"
        name = "Split and review"

        [[roles]]
        id = "lead"
        name = "Lead"
        instructions = "Split the task."

        [[roles]]
        id = "worker"
        name = "Worker"
        instructions = "Do your part."
        instances = { min = 2, max = 3 }

        [[roles]]
        id = "reviewer"
        name = "Reviewer"
        instructions = "Review the work."

        [[stages]]
        id = "split"
        name = "Split"
        roles = ["lead"]
        completion = { rule = "all_roles_done" }

        [[stages]]
        id = "work"
        name = "Work"
        roles = ["worker"]
        completion = { rule = "all_roles_done" }

        [[stages]]
        id = "review"
        name = "Review"
        roles = ["reviewer"]
        completion = { rule = "review_decision", reviewer = "reviewer" }

        [[handoffs]]
        from = { stage = "split", role = "lead" }
        to = { stage = "work", role = "worker" }
        content = "assignment"

        [[handoffs]]
        from = { stage = "work", role = "worker" }
        to = { stage = "review", role = "reviewer" }
        content = "result"

        [[handoffs]]
        from = { stage = "review", role = "reviewer" }
        to = { stage = "work", role = "worker" }
        content = "feedback"

        [[review_loops]]
        review_stage = "review"
        back_to = "work"
        max_rounds = 3
    "#;

    fn valid() -> WorkflowTypeDefinition {
        toml::from_str(VALID).expect("the fixture should parse")
    }

    fn issues(definition: &WorkflowTypeDefinition) -> Vec<ValidationIssue> {
        validate(definition).expect_err("the definition should be invalid")
    }

    fn issue(element: ElementPath, problem: ValidationProblem) -> ValidationIssue {
        ValidationIssue { element, problem }
    }

    fn role(id: &str) -> RoleId {
        RoleId(id.to_owned())
    }

    fn stage(id: &str) -> StageId {
        StageId(id.to_owned())
    }

    fn handoff(from: (&str, &str), to: (&str, &str), content: HandoffContent) -> Handoff {
        Handoff {
            from: StageRole {
                stage: stage(from.0),
                role: role(from.1),
            },
            to: StageRole {
                stage: stage(to.0),
                role: role(to.1),
            },
            content,
        }
    }

    #[test]
    fn the_fixture_is_valid_and_round_trips_through_toml() {
        let definition = valid();
        assert_eq!(validate(&definition), Ok(()));
        let serialized = toml::to_string(&definition).expect("the definition should serialize");
        assert_eq!(
            toml::from_str::<WorkflowTypeDefinition>(&serialized).expect("it should parse again"),
            definition
        );
    }

    #[test]
    fn unknown_keys_are_rejected_when_parsing() {
        for (from, to) in [
            ("max_rounds = 3", "max_rounds = 3\nforever = true"),
            (
                r#"{ rule = "all_roles_done" }"#,
                r#"{ rule = "all_roles_done", reviewer = "lead" }"#,
            ),
            (
                r#"reviewer = "reviewer" }"#,
                r#"reviewer = "reviewer", quorum = 2 }"#,
            ),
        ] {
            let source = VALID.replacen(from, to, 1);
            assert_ne!(source, VALID, "the fixture should contain {from}");
            assert!(
                toml::from_str::<WorkflowTypeDefinition>(&source).is_err(),
                "{to}"
            );
        }
    }

    #[test]
    fn issues_display_the_offending_element() {
        let mut definition = valid();
        definition.review_loops[0].max_rounds = 0;
        assert_eq!(
            issues(&definition)[0].to_string(),
            "review_loops[0]: max rounds 0 must be between 1 and 10"
        );
    }

    #[test]
    fn names_must_be_present_and_single_line() {
        let mut definition = valid();
        definition.name = " ".to_owned();
        assert_eq!(
            issues(&definition),
            [issue(ElementPath::Name, ValidationProblem::MissingName)]
        );
        definition.name = "Two\nlines".to_owned();
        assert_eq!(
            issues(&definition),
            [issue(ElementPath::Name, ValidationProblem::MultilineName)]
        );
    }

    #[test]
    fn a_type_needs_roles_and_stages() {
        let mut definition = valid();
        definition.roles.clear();
        definition.stages.clear();
        definition.handoffs.clear();
        definition.review_loops.clear();
        assert_eq!(
            issues(&definition),
            [
                issue(ElementPath::Roles, ValidationProblem::NoRoles),
                issue(ElementPath::Stages, ValidationProblem::NoStages),
            ]
        );
    }

    #[test]
    fn roles_need_unique_ids_names_and_instructions() {
        let mut definition = valid();
        let mut copy = definition.roles[2].clone();
        copy.name = String::new();
        copy.instructions = "\n".to_owned();
        definition.roles.push(copy);
        definition.roles[0].id = role("");
        assert_eq!(
            issues(&definition),
            [
                issue(ElementPath::Role(0), ValidationProblem::MissingId),
                issue(ElementPath::Role(3), ValidationProblem::DuplicateId),
                issue(ElementPath::Role(3), ValidationProblem::MissingName),
                issue(ElementPath::Role(3), ValidationProblem::MissingInstructions),
                issue(
                    ElementPath::Stage(0),
                    ValidationProblem::UnknownRole(role("lead"))
                ),
                issue(
                    ElementPath::Handoff(0),
                    ValidationProblem::UnknownRole(role("lead"))
                ),
                issue(
                    ElementPath::Stage(1),
                    ValidationProblem::MissingHandoff(role("worker"))
                ),
            ]
        );
    }

    #[test]
    fn instance_counts_are_bounded() {
        for (min, max) in [(0, 1), (3, 2), (1, MAX_PARALLEL_AGENTS + 1)] {
            let mut definition = valid();
            definition.roles[1].instances = InstanceCount { min, max };
            assert_eq!(
                issues(&definition),
                [issue(
                    ElementPath::Role(1),
                    ValidationProblem::InvalidInstanceCount { min, max }
                )]
            );
        }
    }

    #[test]
    fn unused_roles_are_rejected() {
        let mut definition = valid();
        let mut idle = definition.roles[0].clone();
        idle.id = role("idle");
        definition.roles.push(idle);
        assert_eq!(
            issues(&definition),
            [issue(ElementPath::Role(3), ValidationProblem::UnusedRole)]
        );
    }

    #[test]
    fn stages_need_unique_ids_and_known_distinct_roles() {
        let mut definition = valid();
        definition.stages[0].roles = vec![role("lead"), role("lead"), role("ghost")];
        definition.stages.push(Stage {
            id: stage("split"),
            name: String::new(),
            roles: Vec::new(),
            completion: Completion::AllRolesDone {},
        });
        assert_eq!(
            issues(&definition),
            [
                issue(
                    ElementPath::Stage(0),
                    ValidationProblem::RepeatedRole(role("lead"))
                ),
                issue(
                    ElementPath::Stage(0),
                    ValidationProblem::UnknownRole(role("ghost"))
                ),
                issue(ElementPath::Stage(3), ValidationProblem::DuplicateId),
                issue(ElementPath::Stage(3), ValidationProblem::MissingName),
                issue(ElementPath::Stage(3), ValidationProblem::EmptyStage),
            ]
        );
    }

    #[test]
    fn parallel_agents_in_a_stage_are_bounded() {
        let mut definition = valid();
        definition.roles[1].instances = InstanceCount {
            min: 2,
            max: MAX_PARALLEL_AGENTS,
        };
        definition.stages[1].roles.push(role("lead"));
        definition.handoffs.push(handoff(
            ("split", "lead"),
            ("work", "lead"),
            HandoffContent::Result,
        ));
        assert_eq!(
            issues(&definition),
            [issue(
                ElementPath::Stage(1),
                ValidationProblem::TooManyAgents {
                    count: usize::from(MAX_PARALLEL_AGENTS) + 1
                }
            )]
        );
    }

    #[test]
    fn the_reviewer_is_a_single_agent_in_its_stage() {
        let mut definition = valid();
        definition.stages[2].completion = Completion::ReviewDecision {
            reviewer: role("ghost"),
        };
        assert_eq!(
            issues(&definition),
            [issue(
                ElementPath::Stage(2),
                ValidationProblem::UnknownRole(role("ghost"))
            )]
        );

        definition.stages[2].completion = Completion::ReviewDecision {
            reviewer: role("lead"),
        };
        assert_eq!(
            issues(&definition),
            [issue(
                ElementPath::Stage(2),
                ValidationProblem::RoleNotInStage {
                    role: role("lead"),
                    stage: stage("review")
                }
            )]
        );

        definition.stages[2].completion = Completion::ReviewDecision {
            reviewer: role("worker"),
        };
        definition.stages[2].roles.push(role("worker"));
        definition.handoffs.push(handoff(
            ("work", "worker"),
            ("review", "worker"),
            HandoffContent::Result,
        ));
        definition.handoffs[2].from.role = role("worker");
        assert_eq!(
            issues(&definition),
            [issue(
                ElementPath::Stage(2),
                ValidationProblem::ReviewerNotSingle(role("worker"))
            )]
        );
    }

    #[test]
    fn handoffs_resolve_their_stages_and_roles() {
        let mut definition = valid();
        definition.handoffs.push(handoff(
            ("nowhere", "lead"),
            ("work", "worker"),
            HandoffContent::Result,
        ));
        definition.handoffs.push(handoff(
            ("split", "ghost"),
            ("work", "worker"),
            HandoffContent::Result,
        ));
        definition.handoffs.push(handoff(
            ("split", "worker"),
            ("work", "worker"),
            HandoffContent::Result,
        ));
        assert_eq!(
            issues(&definition),
            [
                issue(
                    ElementPath::Handoff(3),
                    ValidationProblem::UnknownStage(stage("nowhere"))
                ),
                issue(
                    ElementPath::Handoff(4),
                    ValidationProblem::UnknownRole(role("ghost"))
                ),
                issue(
                    ElementPath::Handoff(5),
                    ValidationProblem::RoleNotInStage {
                        role: role("worker"),
                        stage: stage("split")
                    }
                ),
            ]
        );
    }

    #[test]
    fn handoffs_only_go_to_the_next_stage() {
        let mut definition = valid();
        definition.handoffs.push(handoff(
            ("split", "lead"),
            ("review", "reviewer"),
            HandoffContent::Result,
        ));
        definition.handoffs.push(handoff(
            ("review", "reviewer"),
            ("split", "lead"),
            HandoffContent::Result,
        ));
        assert_eq!(
            issues(&definition),
            [
                issue(
                    ElementPath::Handoff(3),
                    ValidationProblem::HandoffNotForward
                ),
                issue(
                    ElementPath::Handoff(4),
                    ValidationProblem::HandoffNotForward
                ),
            ]
        );
    }

    #[test]
    fn feedback_follows_a_review_loop() {
        let mut definition = valid();
        definition.handoffs.push(handoff(
            ("split", "lead"),
            ("work", "worker"),
            HandoffContent::Feedback,
        ));
        assert_eq!(
            issues(&definition),
            [issue(
                ElementPath::Handoff(3),
                ValidationProblem::FeedbackOutsideReviewLoop
            )]
        );
    }

    #[test]
    fn feedback_comes_from_the_reviewer() {
        let mut definition = valid();
        definition.roles[1].instances = InstanceCount { min: 2, max: 2 };
        definition.stages[2].roles.push(role("worker"));
        definition.handoffs.push(handoff(
            ("work", "worker"),
            ("review", "worker"),
            HandoffContent::Result,
        ));
        definition.handoffs[2].from.role = role("worker");
        assert_eq!(
            issues(&definition),
            [
                issue(
                    ElementPath::Handoff(2),
                    ValidationProblem::FeedbackNotFromReviewer(role("worker"))
                ),
                issue(
                    ElementPath::ReviewLoop(0),
                    ValidationProblem::LoopWithoutFeedback
                ),
            ]
        );
    }

    #[test]
    fn every_role_after_the_first_stage_receives_a_handoff() {
        let mut definition = valid();
        definition.handoffs.remove(0);
        assert_eq!(
            issues(&definition),
            [issue(
                ElementPath::Stage(1),
                ValidationProblem::MissingHandoff(role("worker"))
            )]
        );
    }

    #[test]
    fn review_loops_are_bounded() {
        for max_rounds in [0, MAX_REVIEW_ROUNDS + 1] {
            let mut definition = valid();
            definition.review_loops[0].max_rounds = max_rounds;
            assert_eq!(
                issues(&definition),
                [issue(
                    ElementPath::ReviewLoop(0),
                    ValidationProblem::InvalidMaxRounds(max_rounds)
                )]
            );
        }
    }

    #[test]
    fn review_loops_go_back_from_a_review_stage() {
        let mut definition = valid();
        definition.review_loops[0].back_to = stage("review");
        definition.review_loops.push(ReviewLoop {
            review_stage: stage("work"),
            back_to: stage("split"),
            max_rounds: 1,
        });
        definition.review_loops.push(ReviewLoop {
            review_stage: stage("missing"),
            back_to: stage("split"),
            max_rounds: 1,
        });
        assert_eq!(
            issues(&definition),
            [
                issue(
                    ElementPath::ReviewLoop(0),
                    ValidationProblem::LoopNotBackward
                ),
                issue(
                    ElementPath::ReviewLoop(1),
                    ValidationProblem::NotAReviewStage(stage("work"))
                ),
                issue(
                    ElementPath::ReviewLoop(2),
                    ValidationProblem::UnknownStage(stage("missing"))
                ),
                issue(
                    ElementPath::Handoff(2),
                    ValidationProblem::FeedbackOutsideReviewLoop
                ),
            ]
        );
    }

    #[test]
    fn a_review_stage_has_exactly_one_loop_with_feedback() {
        let mut definition = valid();
        definition.review_loops.clear();
        assert_eq!(
            issues(&definition),
            [
                issue(ElementPath::Stage(2), ValidationProblem::ReviewWithoutLoop),
                issue(
                    ElementPath::Handoff(2),
                    ValidationProblem::FeedbackOutsideReviewLoop
                ),
            ]
        );

        let mut definition = valid();
        definition
            .review_loops
            .push(definition.review_loops[0].clone());
        definition.handoffs.remove(2);
        assert_eq!(
            issues(&definition),
            [
                issue(
                    ElementPath::ReviewLoop(1),
                    ValidationProblem::DuplicateReviewLoop
                ),
                issue(
                    ElementPath::ReviewLoop(0),
                    ValidationProblem::LoopWithoutFeedback
                ),
                issue(
                    ElementPath::ReviewLoop(1),
                    ValidationProblem::LoopWithoutFeedback
                ),
            ]
        );
    }
}
