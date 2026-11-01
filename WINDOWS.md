# Solanum on Windows

Work happens on the `windows-compat` branch. The Mac app keeps building and passing its tests at every step.

## How the code is laid out

| Folder | What's in it | Built on |
| --- | --- | --- |
| `Sources/Core` | Logic with no drawing. Foundation only. | Both |
| `Sources` | The Mac app, which moves into the other folders piece by piece. | Mac |
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
| 5 | Tabs, panes, sessions, shortcuts and the command palette | Laptop |
| 6 | Sidebar, git, Git Changes, Git Graph, project search and links | Laptop |
| 7 | File editor, previews, settings and the theme editor | Laptop |
| 8 | ssh browsing, agents, Quick Terminal, Keep Awake, and an installer with updates | Laptop |

## Choices so far

- **Interface:** Win32, Direct2D and DirectWrite through Swift's `WinSDK` module, with no WinUI dependency. Menus and
  flyouts are drawn by Solanum to match Windows 11, using the sizes and colors from the mock-ups.
- **Local scripts:** Git for Windows' `sh.exe` runs the same git and search scripts the Mac uses.
- **Closing the last window:** it saves the session and exits, and the next launch restores it.

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
.\build\windows\Solanum.exe --selftest
```
