# Solanum

A native macOS terminal with a file sidebar, a built-in editor, ssh file browsing and first-class support for
[Claude Code](https://claude.com/claude-code). It's written in Swift against AppKit only, with no third-party
dependencies, and themed after the planets of *Outer Wilds*.

## Features

**Terminal**
- Fast xterm-compatible emulator with scrollback reflow, ligatures, true color and synchronized output.
- Command blocks (via shell integration for bash and zsh): select, copy, re-run, collapse or jump between commands.
- Split panes, tabs, tab groups (named, colored, collapsible) and a split window with two independent columns.
- Command palette (⇧⌘P), searchable history (⌃H), snippets and aliases.
- A quick-terminal drop-down available from any app (⌃` by default).
- Session restore: windows, tabs, splits, groups, open files and recent output come back on launch, or are offered
  in the corner for a minute if you'd rather start fresh.
- A corner notice when a long command finishes in a tab you're not looking at.

**Claude Code**
- Each prompt and its response is a turn: step through them (⌘↑ / ⌘↓), jump to one (⌘J), copy or collapse it.
- The tab and sidebar show whether Claude is working, waiting for you, done or failed, and a corner notice appears
  when it finishes or needs input in a background tab.
- Code blocks and tables in Claude's replies get a Copy button.
- Session restore relaunches Claude Code where it was running, continuing the conversation (your alias for
  `claude`, if you have one, with `-c`).
- Selecting text in Claude's input box stays on that text while Claude prints above it; ⌫ / ⌘⌫ delete the selection.

**Files**
- A file sidebar (⌘B, plus a second one per column when split) that follows the terminal's folder, on this Mac or,
  inside an ssh session, on the remote host. Pin a folder per tab to keep it in place. Folders you open stay open
  when you switch tabs or folders and come back.
- Git status in the sidebar: U / A / M / D / R / C letters on changed files and folders, with muted row tints.
  Right-click a changed file › Open Working Tree for its changes side by side, as in VS Code.
- A Git Graph of every branch's history (the status bar's branch picker, or Show Git Graph in the command palette):
  colored lanes, branch and tag labels, and a card with each commit's author, date, message and size on hover.
- A plain-text editor above the terminal, with syntax colors for JSON, YAML and XML, and previews for images, PDFs,
  video and audio.
- Drag and drop or copy/paste between this Mac and ssh hosts (or between two hosts). Transfers stream over the existing
  ssh connection, so there's no second login, and they never overwrite: a taken name gets " copy".
- The status bar shows each column's folder as clickable breadcrumbs and its git branch, sync state and changes.

## Requirements

- macOS 14 (Sonoma) or later on Apple silicon.
- The Swift compiler from Xcode or the Command Line Tools (`xcode-select --install`).

## Building

```sh
./build.sh            # release build, installed to ~/Applications/Solanum.app
./build.sh --debug    # debug build
```

The build signs the app with a code-signing certificate named **Solanum Local** if your keychain has one, and
ad-hoc otherwise. Ad-hoc signatures change with every build, so macOS forgets privacy permissions (Full Disk Access,
folder access) each time. To keep them, create a self-signed code-signing certificate in Keychain Access
(Certificate Assistant › Create a Certificate…, type *Code Signing*) named `Solanum Local`, or point
`SOLANUM_SIGN_ID` at an existing one.

## Shortcuts

| Keys | Action |
|---|---|
| ⇧⌘P | Command palette (every command, theme and snippet) |
| ⌃` | Quick terminal (change in Settings) |
| ⌘T / ⌘N / ⌘W | New tab / new window / close pane |
| ⌘D / ⇧⌘D | Split right / split down |
| ⌘] ⌘[ · ⌥⌘ arrows | Next / previous pane · move between panes |
| ⇧⌘] ⇧⌘[ · ⌃Tab · ⌘1…9 | Switch tabs |
| ⌘↑ / ⌘↓ | Previous / next command block (or Claude prompt) |
| ⌘J | Jump to a Claude prompt |
| ⇧⌘C / ⌥⌘C / ⌥⌘R | Copy command / copy output / re-run |
| ⇧⌘E | Collapse or expand a block's output |
| ⌘F, ⌘G, ⇧⌘G | Find in scrollback |
| ⌘K | Clear the buffer (keeps the prompt) |
| ⌘B / ⇧⌘B | File sidebar / pin its folder |
| ⌘+ / ⌘− / ⌘0 | Font size |
| ⌘, | Settings (also the flower at the top right, or `settings` at a prompt) |

Click a command block to select it and right-click it for more. Right-click a group's chip to rename it.

## Configuration

Everything lives in `~/.config/solanum/`. Settings edits the same files, and changes apply live.

| File | Contents |
|---|---|
| `config` | All preferences, as commented `key = value` lines |
| `themes/*.json` | Custom themes |
| `aliases.json` | Aliases (Settings › Aliases); open tabs pick them up at their next prompt |
| `snippets.json` | Command palette snippets |
| `session.json` | The saved session (kept private to your user) |

### Custom themes

Create one in Settings › Appearance, or drop a JSON file into `~/.config/solanum/themes/`:

```json
{
  "name": "My Theme",
  "background": "#101218", "background2": "#05060A",
  "foreground": "#E6E6E6", "accent": "#5AB0FF", "cursor": "#5AB0FF",
  "ansi": ["#000000","#FF5555","#50FA7B","#F1FA8C","#BD93F9","#FF79C6","#8BE9FD","#BBBBBB",
           "#555555","#FF6E6E","#69FF94","#FFFFA5","#D6ACFF","#FF92DF","#A4FFFF","#FFFFFF"]
}
```

`background2` is optional and gives a vertical gradient. The built-in themes are in `Sources/Theme.swift`.

## Development

- **Self-tests:** `~/Applications/Solanum.app/Contents/MacOS/Solanum --selftest` runs the emulator checks.
- **Snapshots:** `SOLANUM_SNAPSHOT=/tmp/shot.png` renders the first window to a PNG after a few seconds and quits.
  `SOLANUM_SNAPSHOT_ACTIONS` scripts what happens first (splits, tabs, typing, clicks…). The full list is at the top of
  `SnapshotHelper` in `Sources/DevTools.swift`. Set `SOLANUM_SESSION_FILE` to a scratch file so test runs never touch
  your real session.

## Code map

| File | What's in it |
|---|---|
| `Terminal.swift`, `Cell.swift` | The VT/xterm emulator: parser, screen, scrollback, reflow, OSC 133 blocks |
| `TerminalView.swift`, `TerminalInput.swift`, `TerminalActions.swift` | Rendering, keyboard and mouse, block and search actions |
| `PTY.swift` | Pseudo-terminal, plus the bash and zsh shell integration scripts |
| `AgentStatus.swift`, `AgentTurns.swift`, `CodeBoxes.swift` | Claude Code (and other agent) detection, turns, copyable code blocks |
| `Tabs.swift`, `TabColumn.swift` | Windows, tab bar and groups, split panes and columns, status bar |
| `FileSidebar.swift`, `Files.swift`, `GitStatus.swift` | File sidebar, local and ssh file access, transfers, git |
| `FileEditor.swift`, `EditorArea.swift`, `MediaPreview.swift` | Editor and media previews above the terminal |
| `Syntax.swift`, `Diff.swift`, `GitGraph.swift` | JSON / YAML / XML syntax colors, the working tree diff, the git graph |
| `Settings.swift`, `ThemeEditor.swift`, `Theme.swift`, `Config.swift` | Settings window, themes, preferences |
| `Session.swift`, `Notices.swift` | Session save and restore, corner notices |
| `CommandPalette.swift`, `QuickTerminal.swift`, `History.swift`, `Aliases.swift`, `SSHHosts.swift` | The UI around the terminal |
| `DevTools.swift` | Self-tests and the snapshot tool |
| `SolanumArt.swift`, `Tools/MakeIcon.swift` | The flower, drawn in code, and the app icon generator |

---

*Solanum is a fan project and isn't affiliated with Mobius Digital or Annapurna Interactive, the makers of Outer Wilds.*
