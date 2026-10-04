# Twine

Twine organizes coding work in a folder into sessions, each made of workflows where agents collaborate.

## Language

**Twine front end**:
The macOS app where users work with folders, sessions, and workflows.

**twine-core**:
Twine's reusable application library, which manages coding work and saved state.

**Folder**:
The directory the user opens and works in. Twine shows its files and the sessions worked on in it.
_Avoid_: Workspace, project

**Session**:
A named body of work inside a folder, listed in the sidebar next to the folder's files. A session contains workflows.

**Workflow**:
One top-level tab in a session, created from a workflow type. Its task comes from the user, typed to its first agent.

**Workflow type**:
The reusable definition a workflow is created from: its roles, stages, and handoffs. Built-in types are Terminal, Single agent, Adversarial, and Coordinator. Users can define their own.
_Avoid_: Pattern, DAG

**Workflow graph**:
A visual representation of a workflow type's roles, stages, and handoffs.

**Individual mode**:
A workflow-wide setting for follow-ups after completion or the review limit. Off by default, it allows a follow-up to a first-stage agent to start another workflow cycle with the same conversations. On keeps follow-ups individual without advancing the workflow. Switching mode starts no work, preserves the last result and history, and persists across relaunch. The setting appears in the terminal toolbar in both Tabs and Bento.

**Role**:
A responsibility within a workflow type, such as implementer, reviewer, coordinator, or worker. A role is independent of the harness that fills it.

**Harness**:
An external agent tool that Twine can launch, such as Codex, Claude Code, or pi. A harness can fill different roles in different workflows.

**Agent**:
One harness process filling one role in a workflow. Each agent is a subtab of its workflow. A Terminal workflow runs a plain shell and has no agents.
_Avoid_: Agent session

**Trace span**:
A bounded unit of work shown as a step in the Traces panel. Steps share one start-order sequence across agent tracks; spacing does not represent elapsed time. In multi-agent workflows, a span covers an agent's assignment in a stage or review round, from its incoming handoff (or initial stage entry) to its explicit completion or stop. In a single-agent workflow with harness hooks, each prompt starts a span that ends when the agent finishes responding. In Terminal workflows, Twine's shell integration records one span per command, from its output start to its exit status; shells without integration retain a process-lifetime span. Process lifecycle changes remain trace events.

**Trace event**:
A timestamped record of activity that Twine observes or performs during a workflow. Trace events can be associated with a span.

**Terminal transcript**:
The bytes exchanged with an agent's or shell's terminal. It is distinct from structured trace events.

**Config file**:
The user's settings at `~/.config/twine/config.toml`, such as color scheme.
