# ADR 0008: Limit Git status to each repository's default worktree

- Recorded: 2026-10-10
- Status: Accepted
- Provenance: Explicit user decision during TWINE-62 design exploration, 2026-10-10.
- Issue: [TWINE-62: Git Management](https://linear.app/twine-dev/issue/TWINE-62/git-management)

## Context

TWINE-62 introduces Git status in the file sidebar. The opened folder may be a
repository or may contain several independent repositories and ordinary files.
Earlier design exploration included discovering and navigating multiple worktrees
for each repository.

The shared-folder constraint on agents in a collaborative workflow does not itself
prohibit independent agents from running in parallel in separate checkouts.
Nevertheless, worktree management adds scope beyond displaying Git changes. The
user has chosen to defer it and show changes in the default worktree for now.
After reviewing the prototype, the user also selected the existing Files view
alone, deferring the proposed Repositories and Changes navigation tabs.

## Decision

Show Git changes for each repository's default (primary) worktree only. Use the
branch currently checked out there; "default worktree" does not mean the default
branch, and viewing status must never switch branches.

Keep support for multiple repositories within an opened folder:

- Use the hierarchy **opened folder → repository → file**, without a worktree
  selection level. A folder that is itself a repository follows the same model.
- Associate each file's status with its repository root and repository-relative
  path. Independent clones remain separate even when they share a name or remote.
- Show each repository's branch and local changes independently. Ordinary files
  outside Git have no Git badge; the enclosing non-Git folder has no shared branch.
- Preserve staged, unstaged, untracked, deleted, renamed, and conflicted states.
  A file with staged and unstaged changes counts once and exposes both states.
- Present status directly in the existing Files tree. Keep repository folders at
  their actual locations within the opened folder, with badges on their files and
  a status summary on each repository root. Ordinary folders inside a repository
  may indicate changes in their descendants; folders outside Git have no Git state.
- Keep deleted tracked paths discoverable in that tree as muted, struck-through
  rows with a deleted badge. Selecting one shows its deletion state, not an editor
  for a file that no longer exists.
- Keep local changes distinct from ahead/behind information. Clean does not mean
  synchronized with an upstream, and unavailable status does not mean clean.
- Browsing another repository changes file navigation only. Sessions, workflows,
  and running agents retain their existing folder and working directory.

Defer discovery, grouping, selection, creation, removal, and switching of additional
linked worktrees, including navigation to related worktrees outside the opened
folder. Do not automatically redirect from a linked worktree to a primary checkout
elsewhere. Ordinary file browsing remains available in folders outside this Git
status scope. Revisit linked-worktree behavior in a later decision.

Use one Files view, without Files/Repositories/Changes navigation tabs or a
changes-only filter. Repository status details may open from a root's summary;
they do not introduce another navigation view. This scope concerns sidebar
navigation; existing workflow and editor navigation stays in place.
The user approved implementation of this Files-only scope on 2026-10-11. Staging, committing, merging, and assigning
agents to checkouts are separate scope.

## Consequences

The first Git status experience has one Git context per repository and works when
the opened folder contains several repositories. The existing file hierarchy
provides navigation, with no worktree picker, separate repository browser, or
cross-worktree status aggregation.

Git status reflects the checkout's combined state. It does not attribute changes
to an agent or isolate concurrent edits. Agents sharing that checkout still need
coordination when changing overlapping files. Deferring worktree support does not
introduce a restriction on independent parallel workflows.

Additional linked worktrees do not participate in this iteration's Git status
view. Supporting them later requires an explicit scope and navigation decision.

## Implementation constraints

- Follow the current native window layout and the [core boundary](../../AGENTS.md#architecture).
  Main reverted the earlier compact-chrome change before this implementation;
  this feature does not reinstate it.
- Discover repositories without following directory symlinks. Skip Git internals,
  dependency and build directories by default. Bound discovery depth and size;
  report incomplete discovery and allow opening a smaller folder.
- Run bounded, read-only Git status processes on a dedicated worker. Git scanning
  must not hold application locks or block file reading and terminal activity.
- Keep the core's snapshot, bridge representation, native badges, and live updates
  covered by core tests and end-to-end UI tests with real temporary repositories.
