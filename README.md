# hyprland-dock-minimize-restore

> **For users of the [ML4W dotfiles](https://github.com/mylinuxforwork/dotfiles)** — this patch customizes the ML4W Quickshell dock on Hyprland. It is an independent community contribution, not part of the official ML4W repository.

Windows-style minimize/restore toggle for the ML4W Quickshell dock on Hyprland.

Click an app icon in the dock:

- **Active app** → window minimizes (it moves to a special workspace).
- **Minimized app** → window restores to its **original workspace** and takes focus. The pointer does **not** jump to the window center.
- **Other app** → normal focus/cycle behavior. The pointer does **not** jump to the window center.

Verified on **Hyprland 0.56.2** (Lua config), **Quickshell 0.3.1**, ML4W dotfiles **v2.16**, and the ML4W dock repository on CachyOS, 2026-09-25.

## Why this exists

By default, clicking an active app's icon in the ML4W dock only raises the window and moves the pointer to its center — it never minimizes. Hyprland has no native minimize, so this patch uses a **special workspace** (`special:minimized`) as the minimize container, which is the standard Hyprland pattern.

## Files

```
quickshell/DockApp/DockItem.qml   → ~/.local/share/ml4w-dock/DockApp/DockItem.qml
hypr/custom.lua                   → ~/.config/hypr/custom.lua
```

The repo mirrors the real config paths so the target location is unambiguous.

## Installation

**1. Snapshot / backup first** (safety net, do not skip):

```bash
# btrfs (CachyOS default): snapper -c root create -d "dock-toggle-pre-patch"
cp ~/.local/share/ml4w-dock/DockApp/DockItem.qml ~/DockItem.qml.pre-patch.bak
```

**2. Copy the files** (adjust for your user):

```bash
cp quickshell/DockApp/DockItem.qml ~/.local/share/ml4w-dock/DockApp/DockItem.qml
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

**4. Restart the dock — REQUIRED, and inside the graphical session.** `ml4w-dock reload` only re-reads `config.json`; it does not reload the QML code. Restart only the dock, so the ML4W Settings and Overview Quickshell instances remain untouched:

```bash
ml4w-dock restart
```

Run this from a terminal **inside the session** (or just re-login). A dock started from a bare SSH shell — or any environment without the session variables — does **not** inherit `QS_ICON_THEME=kora`, so Quickshell resolves icons against `hicolor` only: SVG-only theme icons (Thunar, Vivaldi, Signal) then fall back to the generic placeholder and appear broken.

## Rollback

```bash
cp ~/DockItem.qml.pre-patch.bak ~/.local/share/ml4w-dock/DockApp/DockItem.qml
ml4w-dock restart
```

## How it works

- **Minimize**: `activate()` compares the normalized dock key returned by `DockWindow.entryKey()` with the focused toplevel's app ID. This avoids failures with pinned executable names and desktop-entry aliases. The focused window's address and original workspace are pushed to `hiddenWindows`, then moved with the Hyprland 0.56 Lua dispatcher API:

  ```bash
  hyprctl dispatch "hl.dsp.window.move({ workspace = 'special:minimized', window = 'address:0x...', follow = false })"
  ```

- **Restore**: each hidden window is moved back to its recorded workspace and focused. Dispatches are passed directly to `hyprctl`, without a shell pipeline:

  ```bash
  hyprctl dispatch "hl.dsp.window.move({ workspace = '<orig>', window = 'address:0x...', follow = false })"
  hyprctl dispatch "hl.dsp.focus({ window = 'address:0x...' })"
  ```

- **Address safety**: the patch normalizes the `0x` prefix and escapes workspace names embedded in Hyprland's Lua expression.

- **Cursor**: Hyprland warps the pointer to the window center on focus changes (`CA::focus` → `warpCursor`). `cursor:no_warps = 1` in `custom.lua` disables non-forced warps.

## Notes / caveats

- **Dispatch syntax is Hyprland-version-dependent.** On ≥0.56 (Lua config), `hyprctl dispatch` evaluates `hl.dispatch(...)` — the old `movetoworkspacesilent special:minimized,address:...` syntax fails with a Lua parse error. This patch targets the `hl.dsp.*` API. On older Hyprland, translate the dispatches to the classic syntax.
- **`Toplevel.minimized = true` is a no-op on Hyprland 0.56.2** (window stays visible). The special workspace is the reliable path — don't fall back to the `minimized` property.
- **ML4W updates can replace `~/.local/share/ml4w-dock/`** — reapply this QML patch after every dock update. `~/.config/hypr/custom.lua` survives by design.
- The dock entry property is `item.entry.appId`; use `DockWindow.entryKey()` when comparing an active window to a dock item. Comparing against `item.appId` is incorrect because that property is undefined.
- **Restart the dock from inside the session.** Quickshell reads the icon theme from `QS_ICON_THEME` (set by `ml4w-autostart` to `kora`). A dock launched from a bare SSH shell loses it, resolves icons against `hicolor` only, and shows generic placeholders for SVG-only icons (Thunar, Vivaldi, Signal). Same reasoning applies to locale and `PATH`.
- `hiddenWindows` is intentionally in memory. Restarting the dock while windows are minimized clears the restore list; restore them before restarting, or move any remaining windows out of `special:minimized` manually.

## License

MIT
