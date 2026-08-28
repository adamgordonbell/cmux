# agb-main — what this fork changes

A personal fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux), daily-driven
as `/Applications/cmux DEV.app`. Everything lives on the **`agb-main`** branch;
`main` tracks upstream untouched.

The through-line: I run several Claude Code sessions side by side all day, and the
things that broke were never the terminal — they were the surfaces *around* it. Markdown
previews that rendered blank. No way to jump to a workspace by number. Clicking a path an
agent printed and getting nothing. Each change below started as one of those.

```
42 files changed, 2836 insertions(+), 98 deletions(-)
```

Six files are new; the rest are small edits to upstream files, deliberately kept small so
rebases stay cheap.

## The changes

### Markdown panels — the reason the fork exists

Previews went blank and edits went missing. Most of the "blank" reports turned out to be
measurement artifacts (an occluded window doesn't composite its WebView; probing opacity
inside `updateNSView` reads stale alpha), but one was real and 100% reproducible: opening
a markdown surface and immediately moving it into another pane whose source pane
collapses. SwiftUI can host two representables for the same tab in one transaction, and
handing both the *same* WKWebView lets the dying host's teardown rip it out of the
survivor's hierarchy for good.

- **Per-representable container hosting** — `makeNSView` returns a throwaway container and
  the coordinator solely owns webview parenting. This is the actual fix, and it's what
  upstream PR [#7398](https://github.com/manaflow-ai/cmux/pull/7398) proposes (+126/−21).
- **Mid-load detach recovery** — the residual hole in the above: a surface reparented
  *while still loading* never set `shellWasHealthyWhenDetached`. Exactly the cold-open
  timing a preview tool hits.
- **Stalled-load and orphaned-webview watchdogs.**
- **The eye button never wrote to disk** — edits made in preview mode were silently lost
  against a parallel editor. Fixed, with a dirty-state affordance.
- **`toggleMarkdownEditMode`**, default ⌃⌥E — a real rebindable action with save-on-exit,
  replacing a Hammerspoon AX script that poked at the UI from outside.

CLI surface, so an external previewer stops guessing:

| | |
|---|---|
| `markdown open --pane <id>` | open into an existing pane instead of splitting then moving |
| `markdown set-mode preview\|text\|toggle` | |
| `markdown.rendered` event | published on WebKit `didFinish`, so callers await instead of sleeping |

### Workspace slots — ⌘0–9

Upstream has ⌘1–9 for tabs. I wanted them for *workspaces*, addressed the way the sidebar
shows them.

- **⌘0 / ⌘1** resolve `planning` by name — two slots on the planning workspace. Both
  **self-heal**: if nothing live is on the surface's tty, relaunch in place rather than
  typing into whatever is there.
- **⌘2–9** = the Nth workspace **in sidebar display order**, so what you see is what you
  get by construction. Past the end creates a scratch workspace.
- **⌘⇧⌫** nuke focused (refuses `planning`, and refuses the workspace it was invoked from).
- **⌘⇧B / ⌘⇧U** banish into a collapsed group, and bring everything back.
- **⌘/** toggles a native hotkey legend that generates its rows from live shortcut
  settings, so rebinding updates it. External hotkeys owned by other tools appear as
  dimmed static rows.

Every slot action has a CLI twin (`cmux slot <0-9>|nuke|banish|unbanish`), which is how
all of it gets tested without touching a key.

### `surface.reveal`

Show a tab **without moving keyboard focus** — so a preview can appear beside the terminal
you're typing in and not steal the cursor. Needed a new `revealTab` primitive in the
vendored bonsplit submodule, pinned to a fork branch.

### Clicking paths that agents print

Ghostty links any token with a slash in it, but resolution assumed the token was relative
to the surface cwd. Agent output doesn't work that way — it spells paths from the
repository root while your shell is three directories deep, or from a project directory
the terminal has never heard of. Clicks silently fell through to `NSWorkspace.open`.

- Resolve repo-relative paths from a nested cwd, walking cwd → repository root.
- **Suffix search** when no base accounts for the path at all.
- Route clicked **`file://`** links through cmux's own viewers. Every entry point rejected
  scheme-bearing text — correct for `https://`, wrong here — so a hyperlinked path opened
  in whatever app owns `.md`, while the *same path unlinked* opened correctly in cmux.

### Files sidebar

- **`right-sidebar set-root <path|auto>`** — pin the files panel from the CLI, so an agent
  can point it at the repo it's editing. Resolves the **caller's** workspace, not the
  focused one.
- **"Set as Root" + a header breadcrumb** — the UI counterpart. Right-click a folder to
  narrow; click the header for any ancestor, or "Follow Shell Directory" to clear.
- **Files panes are independent trees** — opening Files as a pane used to focus the one
  that already existed and mirror the sidebar's directory, which made a second one
  pointless. Now any number can coexist, each with its own root, and the header
  breadcrumb writes to whichever root the panel it lives in owns. (Previously a
  breadcrumb click inside a *pane* silently repinned the *sidebar*.) Find and Vault keep
  the old focus-the-existing-one behavior: they have no per-pane state to tell two copies
  apart.
- **`right-sidebar open-pane <files|find|vault>`** — the CLI twin, with `--pane` (any
  handle form `move-surface` takes) and `--focus`. Prints the new surface's handles as
  JSON so a wrapper can chain off it.
- Keyboard focus tracks explorer hosts as an ordered, most-recently-focused registry
  rather than one slot per mode, so a second Files view can't quietly become the one
  ⌘-shortcuts reach.

### Build and dev loop

- **Shared zig toolchain resolution** (`scripts/zig-toolchain.sh`) — Homebrew moved to zig
  0.16.0 while Ghostty's `build.zig` hard-requires 0.15.2, which broke the helper build
  and the GhosttyKit build in two different places. One version-checked search, used by
  both.
- **`reload.sh --no-quit`** — build a new version while still working in the running app.
- **`reload.sh` refuses to quit the app it is running inside** — the fork's tag is a
  daily driver, not a throwaway build, so the upstream "quit after build" step would
  SIGKILL its own caller. Detected by walking the caller's process ancestors and
  matching bundle ids, so building a *different* tag from inside the daily driver is
  still allowed. `cmux-dev-update` passes `--allow-self-quit` because it has already
  detached by the time it builds.
- **Build commit in the dev-build banner** — after an unattended auto-update, know which
  build you're on without asking a terminal.

## Staying rebasable

Everything user-visible is gated on `~/.config/cmux/slots.json`. With `enabled: false` the
fork behaves exactly like upstream. That's what keeps it merge-cheap and keeps me honest
about which upstream files I'm allowed to touch — the sealed-group logic, for instance, is
three one-line guards in an upstream file delegating into `WorkspaceSlots.swift`, rather
than logic spread through the sidebar.

New behavior goes in new files wherever it can. Upstream edits are call sites.

## State

| | |
|---|---|
| Fork point | `34cc2ba511` (2026-07-19) |
| Behind upstream | ~2,265 commits — **a rebase is due before new feature work** |
| Upstreamed | PR #7398 (markdown container hosting), open |

Rebases are done in a throwaway worktree so `agb-main` stays daily-drivable, with a
`backup/agb-main-*` branch pushed first. The last one replayed 25/25 commits across ~6,300
upstream commits; the conflicts that mattered were semantic — upstream had *relocated* a
declaration between files, where a naive keep-both would have produced a duplicate or
silently dropped it.

## Build

```bash
./scripts/reload.sh --tag DEV --launch
```

`MarkdownPanelTests` needs Xcode — the test host crashes headless and reports 0 tests
executed, which reads as a pass if you aren't looking.
