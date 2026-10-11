# ADR 0007: Model agent coordination explicitly and persist Individual mode

- Status: Accepted (existing decision, documented retrospectively)
- Recorded: 2026-10-10

## Context

A reusable workflow definition coordinates roles without tying a role to one harness. After a run finishes, a user may want another coordinated cycle or an independent follow-up without unintentionally invoking other agents.

## Decision

Model workflow types as versioned roles, stages, handoffs, and review behavior; the graph presents those coordination rules, not a general DAG executor. A workflow belongs to a session in a folder, and an agent is a harness process filling a role.

Persist workflow-wide Individual mode, defaulting Off. After completion or the review limit, Off allows a first-stage follow-up to begin another cycle in the same conversations; On keeps follow-ups individual. Changing mode starts no work, leaves terminals and prior results/history intact, and invalidates queued continuation input through its mode revision. Preserve core availability and generation checks even when the UI moves the control.

## Consequences

Follow-up routing belongs to core and must survive relaunch. Child activity and trace recovery are observations, not authority to advance the workflow. UI wording and tests must distinguish changing the mode from starting work.

## Evidence

- [Terminology](../../CONTEXT.md), [architecture rules](../../AGENTS.md#architecture), [workflow types](../../twine-core/src/workflow_type.rs), [validation](../../twine-core/src/workflow_type/validation.rs).
- [WorkflowRun](../../twine-core/src/workflow_run.rs) and its mode/queued-input tests.
- [PR 82](https://github.com/aravind-n/twine/pull/82); prior delivery notes were cross-checked against the current core implementation.
