# Trace completeness audit

The October 3 discussion asked for tools, parallel subagents, and all available
trace detail beyond a prompt/response circle. On October 4, the Timeline
inspector was accepted with Overview and In Depth modes. The approved design
included compact activity counts, an Inspect activity action, and subagent
assignment/result/parent/timing/status details. Model/usage summaries, exposed
reasoning summaries, retries, permissions, and compaction were conditional
additions when the harness emits them. They were never a promise to reconstruct
private thinking, missing token counts, or unobserved timestamps.

## Drift and root causes

| Gap | Cause | Result in PR 137 |
| --- | --- | --- |
| Loaded legacy history disappeared | Refresh restarted at the first 200 events; span paging used a fixed page count | Preserve the loaded range and append further pages |
| Old traces appeared empty in In Depth | Only structured tool/subagent records were rendered | Show the saved event log as the fallback |
| Recent traces missed their final events | Pi/OMP shutdown discarded queued observations | Drain root and child queues with a deadline; promptly wake the receiver |
| Resumed children split across steps | A new prompt ID bypassed existing native identity correlation | Keep known child lifetimes and tools in their original assignment |
| LLM calls and usage were absent | The activity schema supported only tools/subagents | Add model calls and emitted notes, with optional metadata |
| Old native detail was never used | No linked-conversation reconciliation existed | Recover exact Codex/Claude/Pi/OMP records in a background worker |
| Claude response text was partial | One response can span several native records | Combine public blocks in source order and merge final usage |
| Codex file edits were absent from recovered history | Typed FileChange records were skipped; the October 8 sample contained 150 across 10 native rollouts | Recover complete file diffs, move paths, stdout/stderr, timing and status |
| Full details were irretrievable | The only stored copy was a 2 KiB preview | Retain complete large payloads in deduplicated files and page their contents |
| Later activity was omitted | Each span stopped recording after 10,000 records | Remove that cutoff and retain paged access |
| Overview lacked the approved entry point | Counts/action were absent | Show whole-step counts and Inspect activity |
| OpenCode had no observer | Its inline plugin configuration was not used | Add a private passive launch plugin while preserving existing settings |

## What is recorded

| Harness | Live observation | Saved-history recovery |
| --- | --- | --- |
| Codex | Prompt/tool/child/lifecycle events | Exact response IDs, public responses and exposed reasoning summaries, actual usage, native tools and declared child edges; includes indexed archived roots |
| Claude Code | Prompt/tool/child/permission/compaction events | Public response blocks, request IDs, model/usage, tools, and explicit agent assignment/results; asynchronous launch acknowledgments remain starts |
| Pi and OMP | Provider request payload, model response/usage/cost, tools, children and supported compaction events | Exact linked root and observed child files, native response/tool IDs and usage |
| Antigravity | Prompt/tool/model invocation hooks | Live hooks only; a supplied user request is labeled as such, not as a compiled model request |
| OpenCode v2 | Passive message/step/tool/session/permission events | Live plugin only; step parts provide model outcomes/usage where exposed |

Missing inputs, timings, usage, or public summaries remain unrecorded. Raw
reasoning and encrypted thinking are not presented as exposed summaries.
Historical imports never advance a workflow. Root completion requires the
harness's successful response signal; an error followed by idle is insufficient.

## Storage and limits

SQLite holds compact metadata and previews. Large recorded bodies are saved as
private content-addressed files next to the database. A preview limit reduces
snapshot size without discarding the full recorded body. Native records above
the transport threshold are kept as full JSON and identified as native records
in the inspector. Activity pages and UTF-8 detail pages limit one read, not the
amount that can be inspected.

The default full-detail cache budget is 512 MiB. Running activities, active steps,
and pinned steps are protected, so this is a soft budget while protected data
exceeds it. Closed, unpinned workflow traces expire after 90 days by default;
`retention_days = 0` disables age expiry. Cleanup preserves native harness files
and session/workflow state. Deleted SQLite rows free space for reuse within the
database. Storage usage, pinning, and clearing are available in both view modes.

Observer queues and request deadlines remain bounded to protect interactive
terminals. Observation is best effort if a harness exceeds those queues or lacks
the required hooks. Native recovery uses exact identities or a unique prompt and
time match within the already linked conversation; ambiguous or absent records
remain unavailable. It does not guess from terminal prose or a nearby session.

Regression coverage includes large Unicode input/output and relaunch, more than
10,000 activities, shortened retries, streamed Claude responses, background
launch acknowledgments, complete Codex file-change diffs, interrupted/failed
history, storage protections, observer shutdown/cancellation, OpenCode error/abort/recovery, and desktop inspector flows.
