# Solanum on Windows

Work happens on the `windows-compat` branch. The Mac app keeps building and passing its tests at every step.

## How the code is laid out

| Folder | What's in it | Built on |
| --- | --- | --- |
| `Sources/Core` | Logic with no drawing. Foundation only. | Both |
| `Sources` | The Mac app, which moves into the other folders piece by piece. | Mac |
| `Sources/UI` | Interface logic with no drawing calls, such as where the tab bar's parts go. | Windows, and the Mac later |
| `Sources/Windows` | The Windows app. | Windows |

Each system compiles its folders into one module with `swiftc` (`build.sh`, `build.ps1`). Staying in one module means
no `public` on everything in the core, and no cross-module cost in the emulator's per-byte loops.

## Milestones

Each one ends with something that can be checked. GitHub's Windows machines build and test every push to this branch
(`.github/workflows/windows.yml`), so the laptop is only needed from milestone 3.

| # | Goal | Checked by |
| --- | --- | --- |
| 1 | The emulator and its self-tests run on Windows | CI |
| 2 | ConPTY: a real shell's output reaches the emulator, including PowerShell's prompt hook | CI |
| 3 | A window showing a working terminal: typing, colors, resize, copy and paste | Laptop |
| 4 | A shared canvas, with the terminal view, tab bar and status bar drawn from one codebase | Mac snapshots, laptop |
| 5 | Tabs, panes, sessions, shortcuts, the command palette, and choosing a shell for each tab | Laptop |
| 6 | Sidebar, git, Git Changes, Git Graph, project search and links | Laptop |
| 7 | File editor, previews, settings and the theme editor | Laptop |
| 8 | ssh browsing, agents, Quick Terminal, Keep Awake, and an installer with updates | Laptop |

## Choices so far

- **Moving the Mac over:** the tab bar and status bar are drawn on Windows first. The Mac keeps its own until it can move
  across with snapshots to compare, so the app in daily use isn't put at risk along the way.
- **Interface:** Win32, Direct2D and DirectWrite through Swift's `WinSDK` module, with no WinUI dependency. Menus and
  flyouts are drawn by Solanum to match Windows 11, using the sizes and colors from the mock-ups.
- **Local scripts:** Git for Windows' `sh.exe` runs the same git and search scripts the Mac uses.
- **Shortcuts:** Windows' Ctrl is the Mac's Command, Alt is Option, and Shift is Shift. There's no key for the Mac's Control
  beside it, because Fn can't be detected.
  - A key the app claims is the app's, whatever's running, Claude Code included. A program can't get that key, by choice:
    Ctrl+T new tab, Ctrl+Shift+T reopen a closed tab, Ctrl+W close tab (no confirmation yet), Ctrl+Shift+W also closes the
    tab until there are several windows. Later features may claim Ctrl+N, B, O, S, Q and G the same way (Ctrl+F finds in a file or the terminal, Ctrl+H
    replaces in a file that has the keyboard).
  - Programs keep the keys the app doesn't claim, including Ctrl+A, D, E, H, J, K, L, R, U and Z.
  - Ctrl+C copies when something's selected and interrupts otherwise; Ctrl+V pastes, except in full-screen programs and for
    an image going to Claude Code; Ctrl+X cuts a selection in the line being typed; Ctrl+1 to 9 pick a tab.
  - Ctrl+Shift+P is the command palette, which stands in for the Mac's menu bar.
  - Ctrl+B and Ctrl+Alt+B show the left and right sidebars, and Ctrl+Shift+B pins the left one to its folder.
  - Splits: Ctrl+Alt+D splits right, Ctrl+Shift+D moves a tab to the other column, Ctrl+Alt+W closes the split. Ctrl+D
    stays the shell's (end of input), unlike the Mac's ⌘D.
  - Ctrl+Shift+O is Go to Folder, Ctrl+Shift+F Search in Project Folder, Ctrl+Shift+G Git Graph and Ctrl+Shift+S Git Changes (the Mac's
    ⌃⌘G and ⌃⌘S), Ctrl+Shift+R restarts, and Ctrl+click opens
    a link.
  - In a sidebar, the Mac's and Explorer's keys: Enter or F2 renames, Space or Ctrl+Down shows the file, Delete sends to
    the Recycle Bin, Ctrl+C, X and V copy, cut and paste (with Explorer too), Ctrl+Shift+C copies the path and
    Ctrl+Shift+N makes a folder. A click shows a file above the terminal; a double click opens it in its app.
  - Commands, as the Mac's ⌘↑ ⌘↓ ⌘J ⇧⌘C ⌥⌘C ⌥⌘R: Ctrl+Up and Down step through finished commands (and each prompt of a
    Claude Code session), Ctrl+J searches the prompts sent and commands run, Ctrl+Shift+C copies the command (a
    selection, when there is one), Ctrl+Alt+C copies it with its output, and Ctrl+Alt+R runs it again. Shift+Enter makes
    a new line in Claude Code and at a shell's prompt, sending the line feed Ctrl+J used to.
  - More of the Mac's: Ctrl+Shift+E collapses the picked (or last) command's output to "⋯ N lines hidden" (a click shows it
    again; the palette collapses or expands them all), Ctrl+Shift+K clears the buffer (⌘K), Ctrl+Shift+H searches the
    shell's history and what's been run (⌃H: Enter puts one at the prompt, Ctrl+Enter runs it), Ctrl+= Ctrl+- and Ctrl+0
    size the text, and F11 is full screen. Snippets are in the palette (Enter to edit one, Ctrl+Enter to run it), with
    Save Command as Snippet and Edit Snippets, in the Mac's snippets.json; Refresh Tab has the program redraw.
  - Keep Awake (Ctrl+Shift+A, the Mac's ⇧⌘A): Windows has no caffeinate, so Solanum asks Windows itself to keep the PC
    and display awake for Settings' length (8 hours to start with). The status bar shows the time left; a click there,
    or the shortcut again, ends it, as does quitting Solanum.
  - Send to Chat (Ctrl+Alt+S, the Mac's ⌥⌘S): the picked (or last) command and its output go to a coding agent's chat,
    one running in any tab or a new one with an agent found on the PATH, as a paste that waits in its input box. When
    it can't be pasted safely it goes on the clipboard, with a card saying so. Settings › Preferences › Continue Agents
    has the command that continues each agent on restore (continue-command-<agent>, as on the Mac).
  - In a file, as the Mac's ⌘F and VS Code's: Ctrl+F finds and Ctrl+H replaces ("3 of 12", every match shaded), Enter
    or F3 steps on and Shift with them back, Alt+C, Alt+W and Alt+R match case, whole words and regular expressions
    ($1 and the like in the replacement), Tab moves to the Replace field, Ctrl+Enter there replaces all, and Esc closes
    it with the match selected.
  - In the terminal, Ctrl+F is the Mac's ⌘F bar at its top right: All, Commands or Output, "3/12", Enter and
    Shift+Enter to step, matches in yellow and the current one in orange. From a sidebar it finds in the file showing.
- **Search in Project Folder** (Ctrl+Shift+F, or a sidebar's magnifying glass for its folder), as on the Mac: each file a header with its matching lines under it, a
  count of results and files, 20 seconds at most, and a result opens its file (on this PC or the ssh host) with the
  query selected on its line.
- **Logs**, as on the Mac: `.log` files, and any file with a logger's color codes in it, are colored by level, time,
  thread, logger, stack trace and the message's numbers, strings and paths; error and warning entries are tinted, stack
  traces and all, and color codes are hidden and shown as the colors they ask for. The header's palette button picks
  the format (Automatic, the built-in one or an imported logging config) and the colors of each level and field, and
  adds markers: text picked out wherever it appears, such as `[FAIL]` (the selection is offered). They're kept in
  `%APPDATA%\Solanum\log-formats`, in the Mac's rules files. A custom color is a hex in the rules file for now.
- **Pages above the terminal:** as on the Mac, Git Graph, Git Changes, a commit's changes and files open in sub-tabs above
  the tab's terminal, which stays below (the line between drags, and the strip's terminal button hides it). Clicking
  them gives them the keyboard and clicking the terminal takes it back; Ctrl+W closes the page that has it. In Git
  Graph, resting on a commit shows its card and clicking it opens its changes. Files are previews for now (text and
  images); editing comes with milestone 7.
- **Shared with the Mac, in `Sources/Core`:** syntax for JSON, YAML and XML (`Syntax.swift`: the Mac colors it in
  AppKit, Windows draws it), Beautify (`Prettifier.swift`: XML through Foundation's XMLDocument on the Mac, re-indented
  elsewhere), the kinds of file for icons (`FileKind.swift`), VS Code's languages by file name (`VSCodeLanguages.swift`),
  git's models, Markdown parsing, find in a file (`EditorFind.swift`), project search (`SearchModel.swift`), log
  coloring and its formats and markers (`LogFormat.swift`, `LogFormatStore.swift`), and the emulator. The Mac's own
  files keep only what draws.
- **Art:** `Tools/MakeWindowsArt.swift` renders the Mac's flower, tab prompt and app icon into `Sources/Windows/ArtData.swift`
  and `Support/Windows/Solanum.ico`, until the drawing itself is shared.
- **Closing the last window:** it saves the session (`%APPDATA%\Solanum\session.json`: tabs, their folders, names, groups
  and recent output, the split and the window's frame) and exits, and the next launch restores it. Closing the tabs one
  by one starts over. ssh tabs come back on this PC, with what they showed.
- **Restarting:** Ctrl+Shift+R restarts into the newest build with everything back (Ctrl+Alt+Shift+R starts fresh), as the
  Mac's ⇧⌘R and ⌥⇧⌘R. `build.ps1` builds while Solanum runs, moving the running `Solanum.exe` aside, and
  `.\build.ps1 -Restart` restarts it into the new build when done.
- **Shells:** Solanum finds PowerShell 7, Windows PowerShell, Command Prompt, Git Bash and each WSL distribution, and
  also takes a custom command. New Tab opens the default shell, a menu beside it opens any other, and Settings picks the
  default. A restored tab comes back in the shell it was using. Blocks and folder tracking use each shell's own hook:
  PowerShell's is done, Git Bash and WSL reuse the bash hook, and Command Prompt gets what its `PROMPT` can report (no
  exit status or command start).

## Setting up the laptop (from milestone 3)

```powershell
winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64"
winget install --id Swift.Toolchain --exact
winget install --id Git.Git --exact
```

Then, in a new terminal:

```powershell
git clone -b windows-compat https://github.com/sacaarjain/Solanum.git
cd Solanum
.\build.ps1
.\build\windows\Solanum-test.exe --selftest
```
