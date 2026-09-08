# Blueprint: a diagram canvas for every terminal

Blueprint gives each terminal pane its own Excalidraw canvas, opened from a
bubble in the pane's top-right corner as a popup that floats over the
terminal. It is the visual counterpart of the voice agent: the agent running in
that terminal (Claude Code, Codex) draws the design it is working on, and you
sketch on the same canvas and send the result back into the prompt.

Status: beta. Phase 1 shipped the per-terminal canvas, persistence, and every
entrypoint. Phase 2 added the agent side: the `blueprint.*` socket methods,
`cmux blueprint`, the `cmux-blueprint` MCP server the agent wrappers attach,
Mermaid rendering, image export, "Send to Terminal", and events. Phase 3
replaced the drawer below the terminal with the floating popup.

## Enable it

Settings › Beta Features › **Blueprint**. While the toggle is off, the bubble,
the popup, its commands, the tab-bar button, the shortcut, the socket methods,
and the MCP server are all hidden.

The setting is `blueprint.beta.enabled` in `~/.config/cmux/cmux.json`.
`blueprint.autoOpenOnAgentUpdate` (default `true`) controls whether an agent
update opens a closed popup or only badges the bubble. cmux mirrors the
toggle to `~/Library/Application Support/cmux/blueprint/enabled` so the agent
wrappers can check it at launch; agents started before you turned it on need
a new session to get the tools.

## The bubble and the popup

Every terminal pane shows a small round Blueprint bubble in its top-right
corner. Click it (or use any entrypoint below) and the canvas opens as a popup
that floats over that terminal, anchored under the bubble. Every entrypoint
goes through one shared action path (`TabManager.performBlueprintAction`), so
they behave identically:

| Entrypoint | How |
|---|---|
| Bubble | click to open or close; a dot on it means an agent changed the canvas since you last looked |
| Command palette | Toggle Blueprint, Enlarge or Restore Blueprint, Send Blueprint to Terminal |
| View menu | Toggle Blueprint |
| Keyboard shortcut | `toggleTerminalBlueprint` (unbound by default; bind it in Settings › Shortcuts or `cmux.json`) |
| Surface tab bar | the `cmux.toggleBlueprint` built-in button (add it to `surfaceTabBar.buttons` in `cmux.json`) |
| Popup header | Zoom to Fit, Clear Canvas, Send to Terminal, Reset Size, Fill Pane or Restore Size, Close |
| CLI | `cmux blueprint show|hide|send` (`collapse`/`expand` are aliases of hide/show) |
| Socket | `blueprint.show|hide|send_to_terminal` (`collapse`/`expand` aliases) |

**Size.** The popup takes the shape of its pane: by default it covers the pane
minus a buffer on every side (24 points left, right, and bottom; 44 at the
top so the bubble stays visible), so a narrow split column gets a narrow
popup. Drag the popup's left edge, bottom edge, or bottom-left corner to make
it smaller when you want to watch the terminal behind it. That size is stored
as fractions of the pane **for that terminal only**: closing and reopening,
resizing the split, and restarting cmux all bring it back, while every other
terminal keeps the default coverage until you resize it too. "Fill Pane" (the
Enlarge command) covers the whole pane; "Restore Size" goes back to your
remembered size; "Reset Size" forgets it. Escape in the canvas closes the
popup and returns focus to the terminal.

**Send to Terminal** pastes one block into the terminal's prompt: a headline
with the revision and element count, the PNG path (exported next to the stored
document), and the Mermaid source if the canvas was drawn from Mermaid,
otherwise the compact text summary. Nothing is submitted; you press Return.
The CLI and socket forms can add the summary or the raw scene JSON, a prefix
line, and `--submit`.

## Agents draw with Mermaid

When you launch `claude` or `codex` from a cmux terminal with Blueprint on, the
wrapper attaches the `cmux-blueprint` MCP server (`cmux blueprint mcp`), bound
to that terminal. Its tools:

| Tool | What it does |
|---|---|
| `blueprint_state` | Revision, element count, popup visibility, who edited last, and the text summary. Cheap; agents call it before editing. |
| `blueprint_show_mermaid` | Renders Mermaid into the canvas (`replace` or `append`). The preferred way to draw. |
| `blueprint_get` | Reads the canvas as `summary`, `mermaid`, or `json`, including your sketches. |
| `blueprint_update` | Targeted `upsert` / `delete` / `clear` operations on elements. |
| `blueprint_set_scene` | Replaces the scene with raw Excalidraw elements. |
| `blueprint_export_image` | Saves a PNG or SVG to a path (for example into `docs/`). |
| `blueprint_show` / `blueprint_hide` | Drawer visibility; never moves keyboard focus. |

Every mutation takes an optional `base_revision`. If you edited the canvas
since the agent last read it, the call fails with `conflict` and the current
summary, so the agent reads your changes before drawing over them. The bubble
shows a dot when an agent changed a canvas whose popup was closed.

Disable the attachment per session with `CMUX_BLUEPRINT_MCP_DISABLED=1`. The
wrapper also skips it for `--strict-mcp-config`, under a managed Claude
sideload policy, and when the terminal has no live cmux socket. The
`cmux-blueprint` skill (`skills/cmux-blueprint`) tells agents when to draw.

## CLI

```bash
cmux blueprint state                                  # revision, popup, summary
cmux blueprint mermaid diagram.mmd                    # render a file
echo 'flowchart LR; A-->B' | cmux blueprint mermaid - # or stdin; --append adds below
cmux blueprint get --format mermaid                   # the last Mermaid source
cmux blueprint export --format png --out docs/arch.png
cmux blueprint send --formats png,summary --prefix "Review this:"
cmux blueprint show --surface surface:2               # open the popup of any terminal, no focus change
```

The target defaults to the calling terminal. `--base-revision N` makes
`set`, `mermaid`, and `ops` fail with `conflict` when the canvas changed.
`cmux blueprint --help` lists every subcommand; `docs/cli-contract.md` has the
socket mapping and limits.

## Socket

| Method | Params | Result |
|---|---|---|
| `blueprint.state` | routing | `visible`, `revision`, `element_count`, `updated_by`, `unseen_agent_update`, `canvas_ready`, `has_mermaid`, `summary` |
| `blueprint.get` | routing, `format` | `revision`, `format`, `content` (null when no Mermaid source) |
| `blueprint.set` | routing, `scene` (object or JSON text), `base_revision?`, `source?`, `auto_open?` | revision and popup state |
| `blueprint.apply_ops` | routing, `ops`, `base_revision?`, `auto_open?` | plus `applied` |
| `blueprint.render_mermaid` | routing, `mermaid`, `mode` (`replace`/`append`), `base_revision?`, `auto_open?` | plus `warnings` |
| `blueprint.export` | routing, `format` (`png`/`svg`/`json`/`mermaid`/`summary`), `path?`, `scale?`, `dark?`, `inline?` | `path`+`bytes` (+`width`/`height`, `base64` when inline) or `content` |
| `blueprint.send_to_terminal` | routing, `formats?`, `prompt_prefix?`, `submit?` | `png_path`, `text_length`, `formats` |
| `blueprint.show` / `hide` (aliases `expand` / `collapse`) | routing, `focus?` | popup state, `applied` |

Routing is the usual `surface_id` / `workspace_id` / `window_id` / `pane_id`;
without `surface_id` the workspace's focused terminal is the target. Limits:
scene JSON 1 MiB and 2,000 elements, Mermaid 32 KiB, 500 ops per call. The
verbs that need the canvas page run on the socket worker lane and can take a
few seconds while a closed popup's page loads; they never block the UI.

Events (category `blueprint`, see `docs/events.md`): `blueprint.changed`,
`blueprint.visibility`, `blueprint.sent_to_terminal`.

## Where the drawing lives

Scenes are stored per terminal, keyed by the terminal's restart-stable surface
id, under `~/Library/Application Support/cmux/blueprints-<bundle id>/`. Tagged
dev builds therefore never overwrite the main app's blueprints. PNG exports
without an explicit path land next to the document. The session snapshot only
records whether the popup is open, its remembered size, and the revision, so
the session file stays small; the scene is reloaded from the store on restore.

Every accepted change bumps a revision counter, whoever authored it. Agents use
that revision to notice that you edited the canvas since they last read it.

## How it is built

- The canvas is the bundled `webviews/` React app (`blueprint.html`), served to
  a `WKWebView` through the `cmux-blueprint://app/` custom scheme so the
  build-time deflated chunks can be inflated on the way in.
- `window.cmuxBlueprint` is the page contract (`setScene`, `getScene`,
  `getSummary`, `getMermaid`, `renderMermaid`, `applyOps`, `requestExport`,
  `setTheme`, `zoomToFit`, `clear`), and the page posts `ready`,
  `sceneChanged`, `exportResult`, `exportFailed`, `requestTerminalFocus`, and
  `error` to the `cmuxBlueprint` message handler.
- `TerminalBlueprintState` (owned by `TerminalPanel`) is the single source of
  truth for the popup, its size, the revision, and persistence. Reads (`state`, `get`,
  the summary) come from the Swift-side scene so they work while no page is
  live; Mermaid rendering and image export need the page, so the panel creates
  it offscreen when the popup is closed or its workspace is not on screen.
- The control-socket package owns the synchronous verbs
  (`Coordinator/Blueprint/`); `TerminalController+ControlBlueprintCommands`
  owns the worker-lane verbs; `CLI/CMUXCLI+Blueprint*` owns the CLI and the
  MCP server.

## Privacy

Everything stays on this Mac. No scene, image, or text leaves the app unless
"Send to Terminal" puts it into your prompt, which you or an agent tool call
triggers; the MCP server only talks to the local cmux socket.
