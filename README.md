<img src="assets/icon.svg" width="128" alt="">

# nori

A window manager prototype for macOS in the spirit of [niri](https://github.com/YaLTeR/niri): windows stand in a row of horizontal columns, the strip scrolls, and the focused window is always centered on screen.

Windows are moved not by Accessibility but by WindowServer itself: a dylib loaded into Dock moves them smoothly through private SkyLight calls. So the animation runs on vsync and does not depend on the apps.

## Features

- Every window of the current Space is its own column. The focused window is centered, the rest sit left and right of it, `gap` apart.
- A new window opens right of the focused one, and the strip scrolls to it. A closed window drops out and the gap closes.
- Clicking a window or Cmd+Tab scrolls the strip to that window.
- Windows are stretched to the full screen height when they join the strip.
- A horizontal three-finger swipe drags the strip along with the fingers. On lift the strip settles on the nearest column, and stretches like rubber at the ends. A vertical three-finger swipe moves through Spaces the same way: they follow the fingers (rubber past the first and last), and on lift the nearest one, or the next for a flick, slides to the center. macOS's own three-finger gestures are swallowed.
- A window dragged with the mouse eases back into its column on release.
- Every Space has its own strip.
- Spaces switch vertically, on the same curve as windows. The daemon intercepts every "Switch to Desktop N" press (keys, Opt+J/K, `nori-msg`): Dock switches the Space and the payload draws the picture. If the daemon is off or has crashed, Dock goes back to its own horizontal animation.
- An overview like niri's: all Spaces of the display, scaled down and stacked vertically, with live windows. A four-finger swipe drives it: the overview follows the fingers (stretching like rubber past fully open or closed) and on lift springs open or closed, thrown by the finger speed. macOS's own four-finger gestures are swallowed meanwhile.

## Setup

nori runs on macOS 14 or newer on Apple Silicon (checked on macOS 27). It loads its own dylib into Dock, which macOS only allows with System Integrity Protection partly off. This lowers the security of the whole machine: do it on your own machine only, and see [Undo](#undo) to turn it back on. The steps are the same as for [yabai](https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection).

### 1. Turn off part of SIP (once, from Recovery)

This is the one step the app can't do for you; if it is missing, the app shows these steps and copies the command.

1. Shut the Mac down. Press and hold the power button until "Loading startup options" appears, then click Options → Continue and log in.
2. In the menu bar choose Utilities → Terminal and run:
   ```sh
   csrutil enable --without fs --without debug --without nvram
   ```
   It prints a warning about an unsupported configuration; that is expected.
3. Restart.

This turns off Filesystem Protections, Debugging Restrictions (so the loader can call `task_for_pid` on Dock) and NVRAM Protections (so the boot argument below can be set). The rest of SIP stays on.

### 2. Build and open the app

```sh
make app
open build/Nori.app     # or copy it to /Applications first
```

On launch the app checks and sets up the rest, asking for your password where root is needed:

1. **Boot argument.** Dock is an arm64e process and loads a third-party arm64e dylib only with `-arm64e_preview_abi` in `boot-args`. If it is missing, the app adds it (password) and asks you to restart the Mac.
2. **Accessibility**, for the event tap and for resizing windows. macOS shows its prompt; allow nori in System Settings → Privacy & Security → Accessibility, and the app goes on by itself. The app is signed ad hoc, so after a rebuild macOS may ask again: remove the old nori entry and allow the new one.
3. **Payload.** If Dock doesn't have it yet (first launch, after a reboot or a Dock restart), the app restarts Dock and loads it (password).

Then nori lives in the menu bar:

| Menu item | What it does |
|---|---|
| Open Config | opens `~/.config/nori/config.toml` in the text editor, creating it if needed |
| Reload Config (⌘R) | reads the config again and lays the windows out with it |
| Restart Dock and Reload Payload | after a rebuild, so Dock runs the new payload |
| Quit nori (⌘Q) | puts Spaces back and quits; the payload stays in Dock but goes idle |

### 3. macOS settings

- **Desktop shortcuts.** Turn on "Switch to Desktop 1…N" in System Settings → Keyboard → Keyboard Shortcuts → Mission Control. Opt+J/K, the overview and `nori-msg focus space` switch Spaces through them.
- **Trackpad.** In System Settings → Trackpad → More Gestures, set "Swipe between full-screen applications" to four fingers or turn it off, otherwise macOS flips Spaces along with the strip.
- **yabai.** If it is installed, while nori runs: `yabai -m config layout float` or `yabai --stop-service`.

### Check by hand

```sh
csrutil status     # "unknown (Custom Configuration)" with Filesystem Protections,
                   # Debugging Restrictions and NVRAM Protections: disabled
nvram boot-args    # boot-args	-arm64e_preview_abi
/usr/bin/log show --last 5m --predicate 'process == "Dock" AND eventMessage CONTAINS "nori"' --style compact   # payload log
```

### Running from a terminal

For development the daemon also runs without the bundle; it shows the same menu bar item and does the same checks.

```sh
make        # builds everything into build/
make run    # stops a running daemon, restarts Dock, loads the payload (sudo), runs the daemon in this terminal
```

Ctrl+C stops it. If only the daemon changed, Dock needs no restart: Ctrl+C and `build/nori`.

### Undo

1. In a normal Terminal, while NVRAM Protections are still off: `sudo nvram -d boot-args`.
2. Boot into Recovery as in step 1 and run `csrutil enable`, then restart.

A repair at Apple or an authorized service provider may turn SIP back on as well; then repeat step 1.

## Keys

| Keys | Action |
|---|---|
| Ctrl+Opt+← / → | column to the left / right |
| Opt+H / Opt+L | column to the left / right |
| Opt+J / Opt+K | Space below / above (through the system "Switch to Desktop N" shortcuts, which must be on); in the overview the neighbour slides to the center and becomes current, the overview stays open |
| Opt+= / Opt+- | focused window wider / narrower by `resize-step` (animated) |
| Opt+Shift+H / Opt+Shift+L (`move-left`, `move-right`) | move the focused window one column left / right |
| Opt+Shift+1…9 (`move-to-space-N`) | send the focused window to Desktop N; focus stays on this Space |
| Opt + left drag | move the window under the pointer; it trades places with a neighbour once past its center |
| Opt + right drag | resize the window under the pointer (it takes focus, both edges follow the pointer) |
| Opt+1…5 | Space 1…5. These are the system "Switch to Desktop N" shortcuts: the daemon intercepts them and animates the switch itself |
| Opt+O (`overview`) | overview: all Spaces scaled down and stacked; a click picks a Space and the window under it, dragging a window onto another Space moves it there, Esc or Opt+O closes it |
| 4 fingers up / down | the overview follows the swipe and settles open / closed on lift (overrides Mission Control on four fingers) |

## Config

`~/.config/nori/config.toml`, in [TOML](https://toml.io). It is read at start and again on "Reload Config" in the menu bar. A key nori doesn't know, or a value of the wrong kind, is reported to stderr and skipped; the rest still applies.

```toml
gap = 16                  # between windows, points
padding-top = 40          # from the menu bar
padding-bottom = 0        # from the Dock / bottom of the screen
padding-left = 24
padding-right = 24
resize-step = 10          # width step, % of screen width (default 10)
launch-at-login = true    # start Nori.app at login (default false)

[bindings]
overview = "option+o"     # overview of all Spaces
grow-width = "option+="
shrink-width = "option+-"
move-left = "option+shift+h"
move-right = "option+shift+l"
move-to-space-1 = "option+shift+1"   # … up to move-to-space-9

[[rule]]
app = "Telegram"
space = 3
```

Numbers default to 0 except `resize-step`. A binding missing from `[bindings]` keeps its default (the values above). A binding is modifiers and one key joined by `+`: `option`/`alt`, `ctrl`, `cmd`, `shift` and a letter, a digit, `-` or `=` (the physical key of the US layout).

`launch-at-login` adds or removes Nori.app in System Settings → General → Login Items, at launch and on "Reload Config". It works only for the app, not for `build/nori` run from a terminal. Move the app where it will stay (e.g. /Applications) before turning it on: the login item points at the bundle's current path.

The TOML reader is nori's own and covers what this file needs: comments, plain keys, `"strings"` and `'literal strings'`, numbers, `true`/`false`, `[tables]` and `[[arrays of tables]]`. Dotted or quoted keys, arrays, inline tables, multi-line strings and dates are reported and skipped.

### App rules

One `[[rule]]` table per app. `app` is the app's name or bundle id, any case; the first rule that matches an app wins, and one rule can have several actions.

```toml
[[rule]]
app = "Telegram"
space = 3              # a new Telegram window goes to Desktop 3

[[rule]]
app = "com.apple.finder"
floating = true        # Finder windows stay out of the strip, where you put them

[[rule]]
app = "Raycast"
ignore = true          # nori neither moves nor lists Raycast's windows
```

- `space = N` places a window once, when nori first sees it (also the windows already open when nori starts), so you can still move it elsewhere by hand. Focus stays on the current Space unless the strip there is empty.
- `floating = true`: the windows aren't columns; nori doesn't move or resize them, and they show in `nori-msg query windows` with `"isFloating": true`.
- `ignore = true` hides the app's windows from nori completely, `nori-msg` included.
- "Reload Config" applies changed `floating` and `ignore` rules to open windows right away; `space` rules only affect windows nori hasn't seen yet.

## CLI

`bin/nori-msg` asks the running daemon about Spaces and windows and controls it. Queries answer in JSON, handy with `jq`. Actions print nothing on success. On error `nori-msg` writes `error: …` to stderr and exits with 1.

```sh
nori-msg query spaces [--current]           # Spaces: number, windows, apps with their windows, column order
nori-msg query windows [--space N] [--current] [--app NAME] [--id WID] [--focused]
nori-msg focus left|right                   # column to the left / right
nori-msg focus column N                     # column N on the current Space, from 1
nori-msg focus space N                      # Desktop N through the system "Switch to Desktop N" shortcut
nori-msg focus window WID                   # window by id; if it is on another Space, goes there first

nori-msg query windows --space 2 | jq -r '.[].app'
nori-msg focus window "$(nori-msg query windows --app Telegram | jq '.[0].id')"
```

Window fields: `id`, `pid`, `app`, `bundleId`, `title`, `space` (Desktop number), `spaceId`, `column` (from 1, if the window is in the strip), `isFocused`, `isOnScreen`, `isFloating`, `frame`. `--app` matches the app name or bundle id, case-insensitive. Desktops are numbered from 1 across all displays, like the system shortcuts. Fullscreen Spaces have no number; their `type` is `fullscreen`.

Titles of windows on other Spaces are visible only if the terminal running the daemon has Screen Recording permission. For windows of the current Space the title comes from Accessibility.

Socket: `/tmp/nori-ctl_$USER.socket`, owner only. One request per connection: the arguments joined by tabs, on one line.

## Layout

```
daemon/          Swift daemon, one process
  main.swift       event tap (keys, mouse release), startup, window poll 4 times a second
  Strip.swift      the strip: columns, focus, layout, rubber band, Spaces
  Overview.swift   Spaces overview, its clicks and drags, Space switches
  Events.swift     Accessibility and NSWorkspace notifications that trigger the window sync
  Persist.swift    column order of every Space kept across restarts
  Trackpad.swift   three-finger strip / Space swipes and four-finger overview swipe from raw MultitouchSupport touches
  Windows.swift    window list (CGWindowList), resize (Accessibility)
  Spaces.swift     Option+J/K: neighbouring Space through the system shortcut
  Resize.swift     Option+=/-: animated width change of the focused window
  Config.swift     config reading
  TOML.swift       the TOML subset the config is written in
  Rules.swift      app rules from the config: space, floating, ignore
  Payload.swift    sending commands to the payload
  Control.swift    socket for bin/nori-msg: queries and actions
  App.swift        menu bar item and the setup on launch: SIP, boot-args, Accessibility, payload
app/Info.plist     Nori.app bundle info (make app)
assets/            icon.svg and AppIcon.icns built from it (make icon)
bin/nori-msg       CLI
test/main.swift    checks of the TOML reader (make test)
payload/payload.m  dylib inside Dock: socket, window animation on CVDisplayLink, vertical Space switching
loader/loader.m    loads the payload into Dock (from yabai, MIT, loader/LICENSE)
docs/PLAN.md       the original PoC plan
docs/WINDOWSERVER.md  findings about private WindowServer/Dock APIs and how to explore them
```

The daemon sends lines like `S <wid> <x> <y>` (move the window smoothly) or `M <wid> <x> <y>` (move right away, while fingers are on the trackpad) to `/tmp/nori_$USER.socket`. The full protocol is in the header of `payload/payload.m`.

## Limitations

- One window per column; column widths can't be changed.
- New windows and focus changes come from Accessibility and NSWorkspace notifications; a window closing without a focus change is only seen by the once-a-second poll.
- Main display only.
- Original window sizes are not restored on exit.

## License

MIT, see [LICENSE](LICENSE). `loader/loader.m` comes from [yabai](https://github.com/koekeishiya/yabai) and keeps its MIT license, see [loader/LICENSE](loader/LICENSE).
