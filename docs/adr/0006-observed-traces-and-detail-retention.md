# ADR 0006: Separate observed traces from orchestration and retain full recorded detail

- Status: Accepted (existing decision, documented retrospectively)
- Recorded: 2026-10-10

## Context

Trace navigation needs both an understandable sequence of work and the full recorded tool/subagent detail. Observer timing is incomplete, native schemas differ, and compact UI previews must not become the only stored copy.

## Decision

Overview positions spans by start order across tracks; spacing is not elapsed time. In Depth presents observed activity timing and details. Expose optional public summaries, usage, and verified parent relationships only when the harness records them. Never substitute raw/private reasoning, infer missing times, or guess relationships from terminal prose.

Live observations and background recovery use the exact linked native conversation and stable identities. Historical imports and child activity never advance or complete the parent workflow. Root completion requires its supported successful response signal. Bound observer queues and deadlines to preserve interactive terminal responsiveness; observation remains best effort where hooks or capacity are unavailable.

Keep compact metadata/previews in SQLite and full large bodies in private content-addressed files. Pagination limits a read, not what was recorded. Retention, per-step pinning, and cache cleanup are explicit; active and pinned data is protected. Do not delete native harness files during Twine trace cleanup. Show a recorded-event fallback when old steps lack detailed activity.

## Consequences

UI detail may legitimately say unavailable; accuracy takes priority over invented completeness. Payload storage and retention are independent of snapshots and presentation mode. Regression tests cover large Unicode payloads, paging, relaunch, recovery identity, observer shutdown, and parent/child completion isolation.

## Evidence

- [Trace completeness audit](../trace-audit.md), including the current cache/retention defaults and harness support matrix.
- [Domain definitions](../../CONTEXT.md#language), [trace model](../../twine-core/src/trace.rs), [payload storage](../../twine-core/src/store/trace_payloads.rs).
- [PR 97](https://github.com/aravind-n/twine/pull/97), [PR 137](https://github.com/aravind-n/twine/pull/137).
