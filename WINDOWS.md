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
    tab until there are several windows. Later features may claim Ctrl+N, B, F, O, S, Q and G the same way.
  - Programs keep the keys the app doesn't claim, including Ctrl+A, D, E, H, J, K, L, R, U and Z.
  - Ctrl+C copies when something's selected and interrupts otherwise; Ctrl+V pastes, except in full-screen programs and for
    an image going to Claude Code; Ctrl+X cuts a selection in the line being typed; Ctrl+1 to 9 pick a tab.
  - Ctrl+Shift+P is planned as the command palette.
- **Art:** `Tools/MakeWindowsArt.swift` renders the Mac's flower, tab prompt and app icon into `Sources/Windows/ArtData.swift`
  and `Support/Windows/Solanum.ico`, until the drawing itself is shared.
- **Closing the last window:** it saves the session and exits, and the next launch restores it.
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
