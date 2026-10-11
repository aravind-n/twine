//! Workflow types: the reusable definitions that workflows are created from.
//!
//! Types coordinate a fixed set of agents through explicit signals. Graphs support parallel
//! work, streamed pieces, joins, and bounded feedback. Ordered stages remain readable for
//! existing workflow files and saved runs.

use std::fmt;

use serde::{Deserialize, Serialize};

mod builtin;
mod catalog;
mod files;
mod graph;
mod validation;

pub use builtin::BuiltinType;
pub(crate) use catalog::WorkflowCatalog;
pub use catalog::{CatalogError, WorkflowType, WorkflowTypeRef};
pub use graph::{AgentGraph, GraphEdge, GraphEvent, GraphFinish, GraphPosition, GraphReceive};
pub(crate) use validation::validate_editable;
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
    #[serde(default)]
    pub stages: Vec<Stage>,
    #[serde(default)]
    pub handoffs: Vec<Handoff>,
    #[serde(default)]
    pub review_loops: Vec<ReviewLoop>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub graph: Option<AgentGraph>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<AgentColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_defaults: Option<AgentDefaults>,
}

/// A portable color name. The front end chooses the platform color for each appearance.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentColor {
    Blue,
    Teal,
    Green,
    Yellow,
    Orange,
    Red,
    Pink,
    Purple,
}

/// Optional choices that prefill the launch form. Each launch can override them.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AgentDefaults {
    pub harness: crate::HarnessId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub yolo: bool,
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
