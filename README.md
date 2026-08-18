# hyprland-dock-minimize-restore

> **For users of the [ML4W dotfiles](https://github.com/mylinuxforwork/dotfiles)** — this patch customizes the ML4W Quickshell dock on Hyprland. It is an independent community contribution, not part of the official ML4W repository.

Windows-style minimize/restore toggle for the ML4W Quickshell dock on Hyprland.

Click an app icon in the dock:

- **Active app** → window minimizes (it moves to a special workspace).
- **Minimized app** → window restores to its **original workspace** and takes focus. The pointer does **not** jump to the window center.
- **Other app** → normal focus/cycle behavior. The pointer does **not** jump to the window center.

Verified on **Hyprland 0.56.2** (Lua config) with the ML4W Quickshell dock on CachyOS, 2026-08-09.

## Why this exists

By default, clicking an active app's icon in the ML4W dock only raises the window and moves the pointer to its center — it never minimizes. Hyprland has no native minimize, so this patch uses a **special workspace** (`special:minimized`) as the minimize container, which is the standard Hyprland pattern.

## Files

```
quickshell/DockApp/DockItem.qml   → ~/.config/quickshell/DockApp/DockItem.qml
hypr/custom.lua                   → ~/.config/hypr/custom.lua
```

The repo mirrors the real config paths so the target location is unambiguous.

## Installation

**1. Snapshot / backup first** (safety net, do not skip):

```bash
# btrfs (CachyOS default): snapper -c root create -d "dock-toggle-pre-patch"
cp ~/.config/quickshell/DockApp/DockItem.qml ~/DockItem.qml.pre-patch.bak
```

**2. Copy the files** (adjust for your user):

```bash
cp quickshell/DockApp/DockItem.qml ~/.config/quickshell/DockApp/DockItem.qml
cp hypr/custom.lua ~/.config/hypr/custom.lua
```

**3. Reload Hyprland config:**

```bash
hyprctl reload
```

Verify the cursor fix took effect:

```bash
hyprctl getoption cursor:no_warps   # → bool: true
```

**4. Restart the dock — REQUIRED.** `ml4w-reload-dock` only re-reads dock settings (dock.json); it never reloads the QML code. Restart the Quickshell instance (or simply reboot / wlogout → re-login):

```bash
killall qs 2>/dev/null
sleep 1.5
setsid qs >/dev/null 2>&1 < /dev/null &
```

(The two companion instances — ML4W settings app and overview — restart the same way they were started by `ml4w-autostart`.)

## Rollback

```bash
cp ~/DockItem.qml.pre-patch.bak ~/.config/quickshell/DockApp/DockItem.qml
killall qs && sleep 1.5 && setsid qs >/dev/null 2>&1 < /dev/null &
```

## How it works

- **Minimize**: `activate()` compares the focused toplevel's `appId` against the dock entry's `appId` (the identity comparison `item.windows[i] === ToplevelManager.activeToplevel` **never matches** in Quickshell — verified empirically — so the original code's single-window path was the only thing ever exercising it). The window's address and original workspace are pushed to `hiddenWindows`, then:

  ```bash
  hyprctl dispatch "hl.dsp.window.move({ workspace = 'special:minimized', window = 'address:0x...', follow = false })"
  ```

- **Restore**: each hidden window is moved back to its recorded workspace and focused:

  ```bash
  hyprctl dispatch "hl.dsp.window.move({ workspace = '<orig>', window = 'address:0x...', follow = false })"
  hyprctl dispatch "hl.dsp.focus({ window = 'address:0x...' })"
  ```

- **Cursor**: Hyprland warps the pointer to the window center on focus changes (`CA::focus` → `warpCursor`). `cursor:no_warps = 1` in `custom.lua` disables non-forced warps.

## Notes / caveats

- **Dispatch syntax is Hyprland-version-dependent.** On ≥0.56 (Lua config), `hyprctl dispatch` evaluates `hl.dispatch(...)` — the old `movetoworkspacesilent special:minimized,address:...` syntax fails with a Lua parse error. This patch targets the `hl.dsp.*` API. On older Hyprland, translate the dispatches to the classic syntax.
- **`Toplevel.minimized = true` is a no-op on Hyprland 0.56.2** (window stays visible). The special workspace is the reliable path — don't fall back to the `minimized` property.
- **ML4W updates overwrite `~/.config/quickshell/`** — reapply the QML patch after every update. `~/.config/hypr/custom.lua` survives by design.
- The dock entry property is `item.entry.appId`, **not** `item.appId` (which is undefined) — a common trap when adapting this patch.

## License

MIT
