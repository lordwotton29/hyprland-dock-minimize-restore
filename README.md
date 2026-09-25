# hyprland-dock-minimize-restore

> **For users of the [ML4W dotfiles](https://github.com/mylinuxforwork/dotfiles)** — this patch customizes the ML4W Quickshell dock on Hyprland. It is an independent community contribution, not part of the official ML4W repository.

Windows-style minimize/restore toggle for the ML4W Quickshell dock on Hyprland.

Click an app icon in the dock:

- **Active app** → window minimizes (it moves to a special workspace).
- **Minimized app** → window restores to its **original workspace and the slot it had in the layout**, and takes focus. The pointer does **not** jump to the window center.
- **Other app** → normal focus/cycle behavior. The pointer does **not** jump to the window center.

Verified on **Hyprland 0.56.2** (Lua config), **Quickshell 0.3.1**, ML4W dotfiles **v2.16**, and the ML4W dock repository on CachyOS, 2026-09-25.

## Why this exists

By default, clicking an active app's icon in the ML4W dock only raises the window and moves the pointer to its center — it never minimizes. Hyprland has no native minimize, so this patch uses a **special workspace** (`special:minimized`) as the minimize container, which is the standard Hyprland pattern.

Restoring is the second half of the problem: Hyprland re-inserts a window at the end of its workspace layout, so a restored window loses its **slot** (its left/right position among its neighbours). Since v1.2.0 the window is swapped back into the slot it had before it was minimized.

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
cp ~/.config/hypr/custom.lua ~/custom.lua.pre-patch.bak 2>/dev/null || true
```

**2. Copy the files** (adjust for your user):

```bash
cp quickshell/DockApp/DockItem.qml ~/.local/share/ml4w-dock/DockApp/DockItem.qml
```

**`~/.config/hypr/custom.lua` is personal configuration — never overwrite it blindly.** ML4W ships it, and most users put their own bindings in it. Two cases:

- **You have no `~/.config/hypr/custom.lua` yet, or it is still the ML4W default** — copy the file:

  ```bash
  cp hypr/custom.lua ~/.config/hypr/custom.lua
  ```

- **You already customized it** — copy only the QML above and *append* this block, or merge these two lines into the `hl.config` call you already have:

  ```bash
  cat >> ~/.config/hypr/custom.lua <<'EOF'

  -- hyprland-dock-toggle: disable cursor warp on focus change.
  hl.config({
      cursor = {
          no_warps = 1,
      },
  })
  EOF
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
cp ~/custom.lua.pre-patch.bak ~/.config/hypr/custom.lua   # only if you replaced the whole file
ml4w-dock restart
```

If you appended the block instead, just delete those lines from `~/.config/hypr/custom.lua` and run `hyprctl reload`.

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

- **Position (slot) restore** — v1.2.0: before hiding, the window's geometry is read from the compositor with `hyprctl -j clients` (run through a Quickshell `Process` from `Quickshell.Io`, because the dock's Wayland toplevels carry no geometry of their own). After the restore, the recorded slot is compared with the slot the window actually got and the window is focused and stepped back with `hl.dsp.window.swap({ direction = 'left' | 'right' | 'up' | 'down' })`. Each round re-reads the compositor and starts 150 ms after the previous one, and the loop stops after 3 rounds, so it converges instead of fighting the layout. The reorder is **skipped** when the window's size or monitor changed: the layout is no longer the one the slot was recorded from.

- **Address safety**: the patch normalizes the `0x` prefix and escapes workspace names embedded in Hyprland's Lua expression.

- **Cursor**: Hyprland warps the pointer to the window center on focus changes (`CA::focus` → `warpCursor`). `cursor:no_warps = 1` in `custom.lua` disables non-forced warps.

## Requirements

- Hyprland **0.56+** with the Lua config (`hl.dsp.*` dispatcher API) — older releases need the classic syntax, see below.
- Quickshell with the `Io` module (standard part of Quickshell ≥ 0.3) and `hyprctl` in `PATH` — needed for the slot restore.
- The ML4W dock at `~/.local/share/ml4w-dock/` (ML4W dotfiles v2.16 and later). On older ML4W the dock lived at `~/.config/quickshell` — use tag **v1.0.0**.

## Notes / caveats

- **Dispatch syntax is Hyprland-version-dependent.** On ≥0.56 (Lua config), `hyprctl dispatch` evaluates `hl.dispatch(...)` — the old `movetoworkspacesilent special:minimized,address:...` syntax fails with a Lua parse error. This patch targets the `hl.dsp.*` API. On older Hyprland, translate the dispatches to the classic syntax.
- **`Toplevel.minimized = true` is a no-op on Hyprland 0.56.2** (window stays visible). The special workspace is the reliable path — don't fall back to the `minimized` property.
- **ML4W updates can replace `~/.local/share/ml4w-dock/`** — reapply this QML patch after every dock update. `~/.config/hypr/custom.lua` survives by design.
- The dock entry property is `item.entry.appId`; use `DockWindow.entryKey()` when comparing an active window to a dock item. Comparing against `item.appId` is incorrect because that property is undefined.
- **Restart the dock from inside the session.** Quickshell reads the icon theme from `QS_ICON_THEME` (set by `ml4w-autostart` to `kora`). A dock launched from a bare SSH shell loses it, resolves icons against `hicolor` only, and shows generic placeholders for SVG-only icons (Thunar, Vivaldi, Signal). Same reasoning applies to locale and `PATH`.
- The slot restore steps through the layout with swaps: it assumes the window is on a layout the swaps act on (dwindle/master). On floating or scrolling layouts the recorded slot may not apply, in which case the reorder simply stops after its rounds and leaves the window where Hyprland put it.
- `hiddenWindows` is intentionally in memory. Restarting the dock while windows are minimized clears the restore list; restore them before restarting, or move any remaining windows out of `special:minimized` manually.

## License

MIT
