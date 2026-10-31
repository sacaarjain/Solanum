# Notes for Claude

## Testing and validation are headless

The user works on this Mac while you test. A test must never put a window, Dock icon or menu bar in front of them,
take keyboard focus, or open another app.

- **Emulator checks:** `~/Applications/Solanum.app/Contents/MacOS/Solanum --selftest` (no UI at all).
- **Anything visual or interactive:** a snapshot run, which is headless (`Headless` in `Sources/DevTools.swift`):
  no Dock icon or menu bar, the app never activates, and every window is transparent and click-through while still
  drawing normally. The PNG is drawn from the views, so it shows exactly what the window would.
  Opening a link or file in another app only prints `headless: open <url>` to stderr.

  ```sh
  SOLANUM_SESSION_FILE=<scratchpad>/session.json SOLANUM_SNAPSHOT=<scratchpad>/shot.png \
  SOLANUM_SNAPSHOT_ACTIONS='split,palette,…' ~/Applications/Solanum.app/Contents/MacOS/Solanum
  ```

  Always point `SOLANUM_SESSION_FILE` at a scratch file. The actions are listed above `SnapshotHelper`.
- **Never** `open` Solanum.app, launch the binary without `SOLANUM_SNAPSHOT`, or set `SOLANUM_SNAPSHOT_VISIBLE`
  (which shows the windows), unless the user asks. A run with `SOLANUM_SNAPSHOT_KEEP` stays running; kill it when done.
- Headless runs are never the active app, so focus-dependent drawing (the solid cursor, key-window state) shows as
  unfocused. If a check truly needs a focused, visible window, ask the user first.
- New UI that orders an `NSWindow` (panels, sheets, popovers) or animates its alpha is hidden automatically.
  Anything that reaches outside the app some other way (another process's UI, `NSWorkspace` calls other than
  `open(_:)`, `runModal`) must check `Headless.active` and skip it.
