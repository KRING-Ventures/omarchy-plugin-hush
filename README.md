# Hush

Fade a window in place on [Omarchy](https://omarchy.org/). The window keeps
its tile — nothing reflows, nothing moves — it just goes visually quiet. The
same key brings it back.

Too many windows is cognitively expensive, but closing or stashing them means
rearranging everything afterwards. Hush is the middle ground: each press of
your hush key steps the focused window down one level and then back to normal:

```
normal  →  50% (visible, out of your face)  →  10% (blanked)  →  normal
```

A calendar you still want to glance at gets one press. A window you want gone
until later gets two.

## Install

```bash
omarchy plugin add https://github.com/KRING-Ventures/omarchy-plugin-hush.git --enable
```

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + H", "Hush window", "omarchy-shell io.github.kring-ventures.hush toggle")
```

## Use

- **Hush key** — cycles the focused window: normal → 50% → 10% → normal.
- **Focus a hushed window** (click into it, or hover if your `follow_mouse`
  focuses on hover) — it *peeks*: fully visible until the pointer leaves the
  window or focus moves elsewhere, then it fades again. Hushed windows still
  receive input, so a blanked window is still clickable right where it always
  was.
- **Bar widget** — shows an eye-slash and how many windows are hushed
  (hidden when none are). The tooltip lists them; a click restores them all.

Hush survives shell restarts and config reloads. Windows that close while
hushed are forgotten; a compositor restart starts you fresh.

## Settings

Inline on the plugin's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.kring-ventures.hush", "levels": [0.5, 0.1], "peek": true }
```

- `levels` — the opacity steps the key cycles through before returning to
  normal. One entry makes it a plain toggle; `[0.5, 0.25, 0.1]` gives three
  stages. Each value is 0–1, where 0 is fully invisible.
- `peek` — set `false` if focusing a hushed window should not reveal it.

The bar widget also accepts `"alwaysShow": true` to stay visible when nothing
is hushed.

## CLI / scripting

Everything goes through the shell's IPC:

```bash
omarchy-shell io.github.kring-ventures.hush toggle          # cycle the focused window
omarchy-shell io.github.kring-ventures.hush window 0x1234   # cycle a specific window
omarchy-shell io.github.kring-ventures.hush clear           # restore everything
omarchy-shell io.github.kring-ventures.hush list            # JSON of hushed windows
```

## Notes

- Restoring a window sets its opacity prop to `1`. If you use per-window
  opacity rules elsewhere, a restored window comes back fully opaque, not to
  its ruled value (Hyprland offers no way to read the previous prop back).
- State lives in `~/.local/state/omarchy/hush.json`.
- No daemons, no network: the service runs inside the Omarchy shell and talks
  only to Hyprland.

## License

MIT — see [LICENSE](LICENSE).
