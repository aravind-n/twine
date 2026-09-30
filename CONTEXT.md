# Twine

Twine organizes coding work in a folder into sessions, each made of workflows where agents collaborate.

## Language

**Folder**:
The directory the user opens and works in. Twine shows its files and the sessions worked on in it.
_Avoid_: Workspace, project

**Session**:
A named body of work inside a folder, listed in the sidebar next to the folder's files. A session contains workflows.

**Workflow**:
One top-level tab in a session, created from a workflow type and given its own prompt.

**Workflow type**:
The reusable definition a workflow is created from: its roles, stages, and handoffs. Built-in types are Terminal, Single agent, Adversarial, and Coordinator. Users can define their own.
_Avoid_: Pattern, DAG

**Workflow graph**:
A visual representation of a workflow type's roles, stages, and handoffs.

**Role**:
A responsibility within a workflow type, such as implementer, reviewer, coordinator, or worker. A role is independent of the harness that fills it.

**Harness**:
An external agent tool that Twine can launch, such as Codex, Claude Code, or pi. A harness can fill different roles in different workflows.

**Agent**:
One harness process filling one role in a workflow. Each agent is a subtab of its workflow. A Terminal workflow runs a plain shell and has no agents.
_Avoid_: Agent session

**Trace span**:
A bounded unit of work shown on the trace timeline. In multi-agent workflows, a span covers an agent's assignment in a stage or review round, from its incoming handoff (or initial stage entry) to its explicit completion or stop. In Terminal workflows, Twine's shell integration records one span per command, from its output start to its exit status; shells without integration retain a process-lifetime span. Process lifecycle changes remain trace events.

**Trace event**:
A timestamped record of activity that Twine observes or performs during a workflow. Trace events can be associated with a span.

**Terminal transcript**:
The bytes exchanged with an agent's or shell's terminal. It is distinct from structured trace events.

**Config file**:
The user's settings at `~/.config/twine/config.toml`, such as color scheme.
