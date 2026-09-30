# Twine design

This is the design spec for the macOS app. Treat it like a concept car being turned into a production model: the shapes, proportions, corner radii, typography, and motion below are the brand, and the production app should match them closely. Change a value only when real use demands it, such as long names, many tabs, small windows, light and dark mode, accessibility, or real data. Keep any such change as small as possible and in the same spirit. When a screen isn't covered here, build it from the same parts.

## Principles

- **The terminal is the product.** It gets most of the window. Everything else (tabs, sidebar, traces, footer) stays compact and quiet around it.
- **Native first.** System controls, SF Symbols, system fonts, and semantic colors. The app follows light mode, dark mode, and increased contrast.
- **Calm and dense.** Small type, tight spacing, little chrome. Hierarchy comes from weight, tint, and grouping.
- **Soft, rounded components.** Every panel, card, tile, highlight, and small control has rounded corners.
- **Surfaces connect.** A selected tab is part of the surface below it, not a separate button above it.

## Production rules

- **The terminal follows the system appearance:** light in light mode, dark in dark mode, with matching text tones for each.
- **Colors come from the asset catalog:** the terminal background, ANSI palette, and role colors are named colors with light and dark variants.
- **Real content wins over fixed sizes:** tabs, names, and labels truncate cleanly, tab rows scroll, and panels keep working in small windows.

## Window

- Window background: `windowBackgroundColor`.
- Content margins: 14pt left, right, and top; 11pt bottom.
- Vertical spacing between the terminal block, the Activity panel, and the footer: 13pt.
- The folder toolbar has the sidebar toggle. Close Folder in the File menu returns to the start page.

## Corner radii

| Component | Radius |
|---|---|
| Terminal panel (all corners) | 17 |
| Activity panel | 17 |
| Start page app icon tile | 16 |
| New-tab choices card | 14 |
| Start page empty-recents card | 12 |
| Bento panes | 11 |
| Selected workflow tab (top corners) | 10 |
| Recent folder cards | 10 |
| Workflow choice tiles, selected agent subtab | 9 |
| File row selection, glass icon buttons (`+`) | 8 |
| Trace span pills | 5 |

## Surfaces and materials

- **Panel outline:** a 1pt hairline in the primary color at 12% opacity (8% for the Activity panel).
- **Terminal panel shadow:** black at 8% opacity, radius 12, y offset 4.
- **Glass:** Use Liquid Glass sparingly for important controls and navigation. Let native toolbars and menus adopt the system appearance; prefer the native glass button style for `+`. Sidebar section menus stay borderless on the sidebar material, and the Activity toggle uses a plain chevron. Terminal text, trace lanes, and logs sit on solid backgrounds. Follow Apple's [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) and [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) guidance.
- **Workflow tint:** a workflow with multiple agents fills its selected tab and its subtab strip with `controlBackgroundColor` plus a 12% accent wash. Terminal and single-agent workflows use the terminal background for the selected tab.
- **Secondary surfaces:** start page cards use `controlBackgroundColor`. The trace detail panel uses the same `windowBackgroundColor` as the Activity panel.

## Color

- **Terminal:** Silica colors in dark mode, with a parchment background and darker versions of the same hues in light mode. Dark mode uses background `#0c1013` and text `#e5e1cf`. Light mode uses background `#f7f4e8` and text `#1a2026`. The 16 ANSI slots each have their own color. The prompt marker `❯` is green.
- **Roles and harnesses:** each has one stable color and one SF Symbol, used everywhere it appears: subtabs, trace lanes, span pills, and log entries. Colors are muted: blue (about RGB 110, 150, 224), orange (212, 150, 110), purple (171, 133, 201), and green (102, 153, 122), plus more in the same muted range as needed.
- **Status:** green for running, secondary for complete, orange for needs attention.
- **File selection:** accent at 12% opacity. Folder icons use accent at 80%.

## Typography

| Use | Style |
|---|---|
| Section labels ("WORKFLOWS", "TERMINAL") | caption2, semibold, uppercase, tracking 1.0, secondary |
| Sidebar section labels ("FILES") | caption2, semibold, uppercase, tracking 1.2, secondary |
| Tabs and subtabs | caption; selected is semibold and primary, others regular and secondary |
| Panel titles ("Activity") | 16pt semibold, with a caption2 secondary subtitle |
| Start page title | 30pt semibold |
| Terminal text | 13pt monospaced (12.5pt for dense output) |
| Time axes | 9pt medium monospaced, tertiary |
| Log timestamps and kinds | 10pt medium monospaced |
| Footer | caption2, secondary |

## Motion

All ease-in-out, all tied to a user action.

| Change | Duration | Animation |
|---|---|---|
| Tab close button on hover | 0.12s | fade in, replacing the tab's icon |
| Scroll to the selected tab | 0.18s | scroll |
| Activity collapse and expand | 0.18s | height change |
| Trace detail panel | 0.22s | slide in from the trailing edge with a fade |
| Typing in a new tab turns it into a Terminal | 0.32s | choices card fades out in place |
| New-tab choices card appears | default | fade in from 96% scale |

## Screens

### Start page

- Centered column, 560pt max width, 44pt padding, on the window background.
- App icon: 29pt medium symbol in the accent tint, on a 62×62 glass tile; 27pt below it.
- Title "Welcome to Twine", 30pt semibold; 9pt below it. One line of subheadline secondary text; 28pt below it.
- Open Folder: a prominent bordered button with a folder symbol, 35pt tall.
- 35pt below it a divider, then 22pt below that "Recent Folders" as a headline, 11pt above the list.
- Recent folders: rounded cards 57pt tall with 4pt between them, 15pt horizontal padding, on `controlBackgroundColor`. Each has an 18pt accent folder icon (26pt wide column), the folder name (subheadline medium), its path (caption secondary, `~`-abbreviated, middle-truncated), and a trailing tertiary chevron.
- With no recents: one card with 22pt vertical and 18pt horizontal padding saying opened folders appear here.

### Workflow tabs

- A 42pt row directly above the terminal panel, with no horizontal divider beneath the tabs.
- "WORKFLOWS" label first, 12pt from the tabs, 11pt above the baseline.
- Tabs are 6pt apart, each with a 15pt-wide icon and the title (180pt max, then truncated), with 12pt horizontal padding.
- The selected tab is 35pt tall; others are 29pt. The selected tab has 10pt rounded top corners, a hairline outline on its top and sides, and the same fill as the panel below, so tab and panel read as one shape. The terminal panel keeps its rounded side and bottom outline, with no horizontal top stroke.
- On hover, the icon is replaced by a close button (9pt semibold `xmark`, 20×23 hit area, 9pt from the leading edge).
- `+` button: an 11pt semibold symbol in a 26×26 glass square, 5pt above the baseline, immediately after the tabs. When tabs overflow, it stays visible at the trailing edge of the scroll area.
- The row scrolls horizontally when tabs overflow and keeps the selected tab in view.

### Terminal panel and agent subtabs

- The terminal panel has a 17pt radius on all four corners, with a hairline outline along its curved corners, sides, and bottom, and a shadow. The tab row sits directly above it.
- Workflows with more than one agent get a 43pt subtab strip at the top of the panel, with 18pt horizontal padding and the workflow tint. It starts with a "TERMINAL" label (13pt after it), then subtabs 5pt apart: the role's colored symbol and name, 10pt horizontal padding, 29pt tall. The selected subtab is semibold on a 9pt-radius glass capsule. The Tabs and Bento control sits at the trailing edge.
- Terminal content has about 24pt padding.

### Bento panes

- A workflow with more than one agent can show its agents side by side. A small segmented control (Tabs, Bento) at the trailing edge of the subtab strip switches modes.
- Bento mode shows up to four agents: two side by side, three as one pane beside two stacked, four as a grid. The panes sit on the workflow tint inside the terminal panel, 6pt apart and 6pt from its edges.
- Each pane is a rounded solid panel with an 11pt radius, the panel's 17pt less the gutter so the corners stay concentric, on the terminal background with a hairline outline. Its 28pt header, with 10pt horizontal padding, shows the role's colored symbol, name, and a menu chevron. The menu picks the pane's agent, swapping panes with the agent's current one.
- The pane with the keyboard has a 2pt outline in the keyboard focus color (secondary while the window is inactive) and a semibold, primary header title. Clicking a pane, ⌘], and ⌘[ move the keyboard between panes; in tab mode, ⌘] and ⌘[ switch subtabs.
- Dragging the gutters resizes columns and rows. Panes keep at least 260 × 150pt; a smaller panel shows fewer panes, first one per column, then only the focused pane, which fills the panel as in tab mode.
- Terminal content in a pane has 12pt padding.

### New-tab surface

- A draft tab shows the terminal prompt, and a choices card centered over the terminal.
- Card: 740pt max width, 16pt padding, 14pt radius, and a hairline outline. Use the named `WorkflowChoicesBackground` color: a dark blue-gray fill (RGB 35, 40, 43), with a light variant. Title is 14pt bold, with a caption medium secondary line 10pt below it; leave 14pt before the grid.
- Choice tiles in an adaptive grid (160pt minimum width, 8pt spacing): 64pt minimum height, 10pt padding, 9pt radius, and a hairline outline. Use the named `WorkflowChoiceBackground` color: a lighter dark fill (RGB 50, 55, 58), with a light variant. Each has a 16pt symbol aligned with its caption semibold title, and a caption medium secondary description capped at two lines. Choices that open a menu, such as picking a harness, show a small chevron.

### Activity panel

- A separate rounded panel below the terminal: 48pt collapsed, about 272pt expanded.
- The panel shows the window background through its border; it has no terminal-colored fill.
- Header, 21pt horizontal padding: "Activity" (16pt semibold) with the subtitle "Steps in start order" when expanded, then a caption2 secondary count of steps and agents, then a plain chevron in a 26×26 area (11pt semibold). Clicking anywhere on the header toggles the panel.
- Overview: 18pt tracks, one per agent or shell, labeled with the role's colored symbol and name in a 126pt column (104pt with details, symbol only in narrow windows). Tracks scroll vertically when needed.
- All steps share one X axis ordered by start timestamp. Exact ties use stable track ID priority, then span ID. Every step occupies its own column; gaps and durations never affect spacing. A 14pt axis shows sequence numbers for the loaded history.
- Overview points: 7pt role-colored dots, with a selected ring, a running ring, and an orange failure symbol. Columns are 22–32pt wide and scroll horizontally. A subtle accent band marks the focused range.
- Focus: seven consecutive steps, centered on the selection when possible, or the latest seven before a selection. A 24pt header shows the range and previous/next buttons. The single rail below is 102pt tall, with numbered 10pt points, two-line titles, agent names, and duration/status metadata. Cells fit the available width from 84–116pt and scroll horizontally in narrow panels. Both views reveal the selected step after selection, refresh, or resize.
- A 28pt hint row at the bottom, in caption2 secondary text, with Older activity when history is paginated.
- Detail panel: 40% of the panel width, clamped between 280 and 440pt, on the same `windowBackgroundColor` as the Activity panel, separated by a divider. It has a 48pt header (role symbol, span title as subheadline semibold, role and duration as caption2), glass copy and close buttons, a status line with the state's symbol and a one-line summary, then a scrolling log. Each log row has a monospaced timestamp and kind (the kind in the role color), the message as caption text, 8pt vertical padding, and faint dividers.

### Sidebar

- Hidden initially. Width 245 to 325pt, ideal 285.
- Background: native sidebar material, with frosted translucency and a tone distinct from the window's solid content area. Follow the window's active state and system appearance.
- Section header: 48pt tall, 17pt horizontal padding, the section label, and a trailing borderless ellipsis menu.
- Files is the first section. Its root directory uses the same row as other directories, starts expanded, and has its children indented one level below it. Collapsing the root clears descendant expansion; Collapse All leaves the root collapsed. Row content has a 10pt horizontal inset.
- File rows: 27pt tall, 12.5pt text, indented 13pt plus 15pt per level, a 9pt tertiary disclosure chevron (11pt wide), a 12pt file symbol (16pt wide), and a rounded (8pt) accent-tinted selection.
- Sessions follow the same row and header design as files.

### Status footer

- A 22pt plain-text row below the Activity panel, with 4pt horizontal padding and 8pt spacing, in caption2 secondary text; not a card.
- Contents: the Git branch with a branch symbol, and the selected workflow's status and elapsed time, separated by a 10pt-tall divider when both are present.

### Empty states

Use the system's standard unavailable-content view with an SF Symbol and one line of guidance, for example "No activity yet" or "No open tabs".

### Other screens

The file viewer, HTML preview, workflow graph, launch form, and workflow designer are built from the same parts: rounded solid panels (17pt radius) with hairline outlines on the window background, small uppercase section labels, caption-sized controls, role colors and symbols wherever a role appears, and glass only on small controls.
