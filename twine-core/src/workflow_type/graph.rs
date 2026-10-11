use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use super::{
    ElementPath, MAX_PARALLEL_AGENTS, ValidationIssue, ValidationProblem, WorkflowTypeDefinition,
};

/// Agent coordination, not a general task executor. Only explicit signals follow links.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AgentGraph {
    pub edges: Vec<GraphEdge>,
    #[serde(default)]
    pub receive: BTreeMap<String, GraphReceive>,
    /// Review decisions belong to the agent, including an agent with no outgoing links.
    #[serde(default)]
    pub review_agents: BTreeSet<String>,
    #[serde(default)]
    pub positions: BTreeMap<String, GraphPosition>,
    #[serde(default)]
    pub finish: GraphFinish,
    #[serde(default = "default_limit")]
    pub max_activations: u16,
}

impl AgentGraph {
    /// Legacy endpoint links remain readable; new graphs infer entry and result roles.
    #[must_use]
    pub fn is_start(&self, role: &str) -> bool {
        if self.edges.iter().any(|edge| edge.from == "task") {
            return self
                .edges
                .iter()
                .any(|edge| edge.from == "task" && edge.to == role);
        }
        !self
            .edges
            .iter()
            .any(|edge| edge.to == role && edge.event != GraphEvent::Feedback)
    }

    #[must_use]
    pub fn is_result(&self, role: &str) -> bool {
        if self.edges.iter().any(|edge| edge.to == "finish") {
            return self
                .edges
                .iter()
                .any(|edge| edge.from == role && edge.to == "finish");
        }
        !self
            .edges
            .iter()
            .any(|edge| edge.from == role && edge.event != GraphEvent::Feedback)
    }

    #[must_use]
    pub fn is_review(&self, role: &str) -> bool {
        self.review_agents.contains(role)
            || self.edges.iter().any(|edge| {
                edge.from == role
                    && matches!(edge.event, GraphEvent::Feedback | GraphEvent::Approved)
            })
    }

    fn has_endpoints(&self) -> bool {
        self.edges
            .iter()
            .any(|edge| edge.from == "task" || edge.to == "finish")
    }
}

const fn default_limit() -> u16 {
    32
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct GraphEdge {
    pub id: String,
    /// A role ID. Legacy files can also use `task`.
    pub from: String,
    /// A role ID. Legacy files can also use `finish`.
    pub to: String,
    pub event: GraphEvent,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GraphEvent {
    Task,
    Done,
    PieceReady,
    Feedback,
    Approved,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GraphReceive {
    #[default]
    Any,
    All,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GraphFinish {
    #[default]
    All,
    Choose,
    Timed,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct GraphPosition {
    pub x: i32,
    pub y: i32,
}

pub(super) fn validate_graph(
    definition: &WorkflowTypeDefinition,
    issues: &mut Vec<ValidationIssue>,
) {
    let Some(graph) = &definition.graph else {
        return;
    };
    let mut report = |element, message: &str| {
        issues.push(ValidationIssue {
            element,
            problem: ValidationProblem::Graph(message.to_owned()),
        });
    };
    let roles: BTreeSet<_> = definition
        .roles
        .iter()
        .map(|role| role.id.0.as_str())
        .collect();
    if !definition.stages.is_empty()
        || !definition.handoffs.is_empty()
        || !definition.review_loops.is_empty()
    {
        report(
            ElementPath::Graph,
            "use a graph or ordered stages, not both",
        );
    }
    if !(1..=256).contains(&graph.max_activations) {
        report(
            ElementPath::Graph,
            "activation limit must be between 1 and 256",
        );
    }
    if roles.contains("task") || roles.contains("finish") {
        report(ElementPath::Roles, "task and finish are reserved IDs");
    }
    if graph.edges.len() > 64 {
        report(ElementPath::Graph, "a graph can use at most 64 links");
    }
    let mut ids = BTreeSet::new();
    let mut links = BTreeSet::new();
    for (index, edge) in graph.edges.iter().enumerate() {
        let element = ElementPath::Edge(index);
        if edge.id.is_empty() || !ids.insert(&edge.id) {
            report(element, "use a unique link ID");
        }
        if !(edge.from == "task" || roles.contains(edge.from.as_str()))
            || !(edge.to == "finish" || roles.contains(edge.to.as_str()))
        {
            report(
                element,
                "connect Task to an agent, an agent to an agent, or an agent to Finish",
            );
        }
        if (edge.from == "task") != (edge.event == GraphEvent::Task)
            || edge.to == "finish" && !matches!(edge.event, GraphEvent::Done | GraphEvent::Approved)
        {
            report(
                element,
                "use Task from Task and Done or Approved into Finish",
            );
        }
        if edge.from == edge.to {
            report(element, "connect two different agents");
        }
        if !links.insert((&edge.from, &edge.to, edge.event as u8)) {
            report(element, "this link already exists");
        }
    }
    for key in &graph.review_agents {
        if !roles.contains(key.as_str()) {
            report(ElementPath::Graph, "review rule refers to an unknown agent");
        }
    }
    for key in graph.receive.keys() {
        if !roles.contains(key.as_str()) {
            report(
                ElementPath::Graph,
                "receive rule refers to an unknown agent",
            );
        }
    }
    for (key, position) in &graph.positions {
        if key != "task" && key != "finish" && !roles.contains(key.as_str())
            || !(0..=4000).contains(&position.x)
            || !(0..=4000).contains(&position.y)
        {
            report(ElementPath::Graph, "node position is invalid");
        }
    }
    check_events_and_count(definition, graph, &mut report);
    check_paths(definition, graph, &mut report);
}

fn check_events_and_count(
    definition: &WorkflowTypeDefinition,
    graph: &AgentGraph,
    report: &mut impl FnMut(ElementPath, &str),
) {
    let count: usize = definition
        .roles
        .iter()
        .map(|role| usize::from(role.instances.max))
        .sum();
    if count > usize::from(MAX_PARALLEL_AGENTS) {
        report(ElementPath::Roles, "a graph can use at most five agents");
    }
    for (index, role) in definition.roles.iter().enumerate() {
        let reviewer = graph.is_review(&role.id.0);
        if reviewer
            && graph
                .edges
                .iter()
                .any(|edge| edge.from == role.id.0 && edge.event == GraphEvent::Done)
        {
            report(
                ElementPath::Role(index),
                "a review agent uses Approved or Feedback instead of Done",
            );
        }
    }
}

fn check_paths(
    definition: &WorkflowTypeDefinition,
    graph: &AgentGraph,
    report: &mut impl FnMut(ElementPath, &str),
) {
    if !graph.has_endpoints() {
        check_agent_paths(definition, graph, report);
        return;
    }
    let mut reachable = BTreeSet::from(["task"]);
    loop {
        let before = reachable.len();
        for edge in &graph.edges {
            if reachable.contains(edge.from.as_str()) {
                reachable.insert(&edge.to);
            }
        }
        if before == reachable.len() {
            break;
        }
    }
    for (index, role) in definition.roles.iter().enumerate() {
        if !reachable.contains(role.id.0.as_str()) {
            report(ElementPath::Role(index), "connect this agent to Task");
        }
    }
    if !reachable.contains("finish") {
        report(ElementPath::Graph, "connect at least one agent to Finish");
    }
    let mut finishing = BTreeSet::from(["finish"]);
    loop {
        let before = finishing.len();
        for edge in &graph.edges {
            if finishing.contains(edge.to.as_str()) {
                finishing.insert(&edge.from);
            }
        }
        if before == finishing.len() {
            break;
        }
    }
    for (index, role) in definition.roles.iter().enumerate() {
        if !finishing.contains(role.id.0.as_str()) {
            report(
                ElementPath::Role(index),
                "connect this agent to a path to Finish",
            );
        }
    }
}

fn check_agent_paths(
    definition: &WorkflowTypeDefinition,
    graph: &AgentGraph,
    report: &mut impl FnMut(ElementPath, &str),
) {
    let mut reachable: BTreeSet<_> = definition
        .roles
        .iter()
        .filter(|role| graph.is_start(&role.id.0))
        .map(|role| role.id.0.as_str())
        .collect();
    let mut finishing: BTreeSet<_> = definition
        .roles
        .iter()
        .filter(|role| graph.is_result(&role.id.0))
        .map(|role| role.id.0.as_str())
        .collect();
    if reachable.is_empty() {
        report(
            ElementPath::Graph,
            "add a start agent with no forward inputs",
        );
    }
    if finishing.is_empty() {
        report(
            ElementPath::Graph,
            "add a result agent with no forward outputs",
        );
    }
    loop {
        let before = (reachable.len(), finishing.len());
        for edge in graph
            .edges
            .iter()
            .filter(|edge| edge.event != GraphEvent::Feedback)
        {
            if reachable.contains(edge.from.as_str()) {
                reachable.insert(&edge.to);
            }
            if finishing.contains(edge.to.as_str()) {
                finishing.insert(&edge.from);
            }
        }
        if before == (reachable.len(), finishing.len()) {
            break;
        }
    }
    for (index, role) in definition.roles.iter().enumerate() {
        if !reachable.contains(role.id.0.as_str()) {
            report(
                ElementPath::Role(index),
                "connect this agent to a start agent",
            );
        }
        if !finishing.contains(role.id.0.as_str()) {
            report(
                ElementPath::Role(index),
                "connect this agent to a result agent",
            );
        }
    }
}
