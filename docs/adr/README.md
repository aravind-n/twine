# Architecture decision records

Records capture an accepted choice, its reason, consequences, and supporting evidence. Numbering follows documentation order, not the historical order in which older choices were made. Change a decision by adding a superseding record and linking both; do not silently rewrite its history.

| Record | Status | Origin |
| --- | --- | --- |
| [0001: Put workflow navigation in the titlebar and slim the closed bottom area](0001-compact-folder-chrome.md) | Accepted | Approved design, 2026-10-10 |
| [0002: Separate native presentation from the reusable application core](0002-native-ui-and-core-boundary.md) | Accepted | Existing decision, recorded 2026-10-10 |
| [0003: Isolate folder runtimes and retain live terminal surfaces](0003-folder-windows-and-retained-surfaces.md) | Accepted | Existing decision, recorded 2026-10-10 |
| [0004: Use TextKit 2 editing and scoped WebKit previews](0004-native-editor-and-scoped-previews.md) | Accepted | Existing decision, recorded 2026-10-10 |
| [0005: Apply one persisted zoom to native and web presentation](0005-app-wide-zoom.md) | Accepted | Existing decision, recorded 2026-10-10 |
| [0006: Separate observed traces from orchestration and retain full recorded detail](0006-observed-traces-and-detail-retention.md) | Accepted | Existing decision, recorded 2026-10-10 |
| [0007: Model agent coordination explicitly and persist Individual mode](0007-workflow-types-and-individual-followups.md) | Accepted | Existing decision, recorded 2026-10-10 |

The retrospective records were extracted from repository instructions, domain definitions, implementation, the trace audit, and relevant prior project notes. Source and PR links make their evidence reviewable. Their recorded date does not assert an original approval date. Exploratory proposals, obsolete implementation facts, and delivery procedures are not promoted into product decisions. Current code and explicit user-approved specifications take precedence over stale notes.
