use super::{RunAgentStatus, RunStatus, WorkflowRun};

impl WorkflowRun {
    /// Earlier records have completion history but no per-agent status. Infer only missing fields;
    /// explicit statuses describe the latest invocation, including review loop backs.
    pub(crate) fn from_stored_json(state: &str) -> Result<Self, serde_json::Error> {
        let value: serde_json::Value = serde_json::from_str(state)?;
        let legacy: Vec<_> = value["agents"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|agent| agent.get("status").is_none())
            .filter_map(|agent| agent["agentId"].as_u64())
            .collect();
        let mut run: Self = serde_json::from_value(value)?;
        for id in legacy {
            let status = run.legacy_agent_status(id);
            if let Some(agent) = run.agents.iter_mut().find(|a| a.agent_id == id) {
                agent.status = status;
            }
        }
        Ok(run)
    }

    fn legacy_agent_status(&self, id: u64) -> RunAgentStatus {
        if self.completions.contains_key(&id) {
            return RunAgentStatus::Completed;
        }
        let latest = self.traces.iter().rev().find(|event| {
            event.agent_id == Some(id)
                && matches!(event.kind.as_str(), "roleCompleted" | "agentStarted")
        });
        if self.active_agents().iter().any(|a| a.agent_id == id) {
            // A prior generation's completion doesn't complete a newly entered role.
            match self.status {
                RunStatus::Running => {
                    return if latest.is_some_and(|e| {
                        e.generation == self.generation && e.kind == "agentStarted"
                    }) {
                        RunAgentStatus::Running
                    } else {
                        RunAgentStatus::Waiting
                    };
                }
                RunStatus::Interrupted => return RunAgentStatus::Interrupted,
                RunStatus::Cancelled => return RunAgentStatus::Cancelled,
                RunStatus::Failed | RunStatus::LimitReached => return RunAgentStatus::Failed,
                RunStatus::Completed => {}
            }
        }
        match latest.map(|event| event.kind.as_str()) {
            Some("roleCompleted") => RunAgentStatus::Completed,
            Some("agentStarted") => RunAgentStatus::Cancelled,
            _ => RunAgentStatus::Waiting,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        BuiltinType, CompletionSignal, Decision, HarnessId, RoleLaunch, WorkflowType,
        WorkflowTypeRef,
    };

    fn run() -> WorkflowRun {
        let mut run = WorkflowRun::new(
            WorkflowType {
                reference: WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
                definition: BuiltinType::Adversarial.definition(),
            },
            "Task".into(),
            &[
                RoleLaunch {
                    role: "implementer".into(),
                    harness: HarnessId::Pi,
                },
                RoleLaunch {
                    role: "reviewer".into(),
                    harness: HarnessId::Pi,
                },
            ],
        )
        .unwrap();
        for (agent, id) in run.agents.iter_mut().zip(1..) {
            agent.agent_id = id;
        }
        run
    }

    fn signal(decision: Decision) -> CompletionSignal {
        CompletionSignal {
            decision,
            summary: "Explicit feedback".into(),
            assignments: vec![],
        }
    }

    fn legacy(run: &WorkflowRun) -> WorkflowRun {
        let mut value = serde_json::to_value(run).unwrap();
        for agent in value["agents"].as_array_mut().unwrap() {
            agent.as_object_mut().unwrap().remove("status");
        }
        WorkflowRun::from_stored_json(&value.to_string()).unwrap()
    }

    #[test]
    fn legacy_records_preserve_completed_roles_and_explicit_new_statuses() {
        let mut run = run();
        run.complete(1, 1, signal(Decision::Done)).unwrap();
        let restored = legacy(&run);
        assert_eq!(restored.agents[0].status, RunAgentStatus::Completed);
        assert_eq!(restored.agents[1].status, RunAgentStatus::Waiting);
        run.complete(2, 2, signal(Decision::Approve)).unwrap();
        let restored = legacy(&run);
        assert!(
            restored
                .agents
                .iter()
                .all(|a| a.status == RunAgentStatus::Completed)
        );
        assert_eq!(restored.traces, run.traces);
        assert_eq!(restored.status, RunStatus::Completed);
        run.agents[0].status = RunAgentStatus::Exited;
        let restored =
            WorkflowRun::from_stored_json(&serde_json::to_string(&run).unwrap()).unwrap();
        assert_eq!(restored.agents[0].status, RunAgentStatus::Exited);
    }

    #[test]
    fn a_review_loop_interrupted_or_failed_before_launch_cannot_reuse_completed_status() {
        for status in [RunStatus::Interrupted, RunStatus::Failed] {
            let mut run = run();
            run.complete(1, 1, signal(Decision::Done)).unwrap();
            run.complete(2, 2, signal(Decision::RequestChanges))
                .unwrap();
            assert_eq!(run.generation, 3);
            assert_eq!(run.agents[0].status, RunAgentStatus::Waiting);
            assert_eq!(run.agents[1].status, RunAgentStatus::Completed);
            assert_eq!(legacy(&run).agents[0].status, RunAgentStatus::Waiting);
            run.finish(status, "Stopped before launch");
            assert_eq!(
                run.agents[0].status,
                match status {
                    RunStatus::Interrupted => RunAgentStatus::Interrupted,
                    _ => RunAgentStatus::Failed,
                }
            );
            assert_eq!(run.agents[1].status, RunAgentStatus::Completed);
        }
    }
}
