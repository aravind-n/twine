//! Workflow types: the reusable definitions that workflows are created from.
//!
//! A type lists its roles, runs its stages in order, and moves work between stages only through
//! explicit handoffs. The only way back to an earlier stage is a bounded review loop, so a type is
//! never a general graph and never spawns agents beyond the counts chosen at launch.

use std::fmt;

use serde::{Deserialize, Serialize};

mod validation;

pub use validation::{ElementPath, ValidationIssue, ValidationProblem, validate};

/// The most agents that can run at once in one stage, counting every instance of every role.
pub const MAX_PARALLEL_AGENTS: u8 = 5;

/// The most times a review loop can send work back before the workflow stops.
pub const MAX_REVIEW_ROUNDS: u8 = 10;

#[derive(Clone, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct RoleId(pub String);

#[derive(Clone, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct StageId(pub String);

impl fmt::Display for RoleId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl fmt::Display for StageId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WorkflowTypeDefinition {
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub roles: Vec<Role>,
    /// Stages run in this order.
    pub stages: Vec<Stage>,
    pub handoffs: Vec<Handoff>,
    #[serde(default)]
    pub review_loops: Vec<ReviewLoop>,
}

/// A responsibility in the type, independent of the harness that fills it.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Role {
    pub id: RoleId,
    pub name: String,
    pub instructions: String,
    #[serde(default)]
    pub instances: InstanceCount,
}

/// How many agents can fill a role. The user picks the count within these bounds at launch.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InstanceCount {
    pub min: u8,
    pub max: u8,
}

impl Default for InstanceCount {
    fn default() -> Self {
        Self { min: 1, max: 1 }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Stage {
    pub id: StageId,
    pub name: String,
    /// Roles that run in parallel during this stage.
    pub roles: Vec<RoleId>,
    pub completion: Completion,
}

/// The explicit signal that ends a stage.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "rule", rename_all = "snake_case", deny_unknown_fields)]
pub enum Completion {
    /// Every agent in the stage signals that it is done. The empty braces make serde reject
    /// unknown keys, which it ignores on unit variants.
    AllRolesDone {},
    /// The reviewer approves, or requests changes through the stage's review loop.
    ReviewDecision { reviewer: RoleId },
}

/// One end of a handoff: a role while it runs in a stage.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct StageRole {
    pub stage: StageId,
    pub role: RoleId,
}

/// Work passed from a role in one stage to a role in the next, or back along a review loop.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Handoff {
    pub from: StageRole,
    pub to: StageRole,
    pub content: HandoffContent,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HandoffContent {
    /// The sender's finished work.
    Result,
    /// A reviewer's requested changes, sent back along a review loop.
    Feedback,
    /// A sub-task and the files its receiver owns.
    Assignment,
}

/// Sends work from a review stage back to an earlier stage when the reviewer requests changes.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ReviewLoop {
    pub review_stage: StageId,
    pub back_to: StageId,
    /// Rounds of requested changes allowed before the workflow stops.
    pub max_rounds: u8,
}
