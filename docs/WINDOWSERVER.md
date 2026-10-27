# WindowServer / SkyLight: findings

Notes on the private APIs nori uses or could use. Checked on macOS 27 (Darwin 27.0.0), Apple Silicon.
"Verified" = seen with our own eyes; "not verified" = inferred from the disassembler, or a guess.

## How to look

- Payload logs: `/usr/bin/log show --last 1h --predicate 'process == "Dock" AND eventMessage CONTAINS "nori"' --style compact`.
  In zsh plain `log` is a builtin and silently shows nothing. Use the full path `/usr/bin/log`.
- SkyLight exports (it lives in the shared cache, `nm` won't help):
  `dyld_info -exports /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight | awk '{print $NF}' | grep -i <something>`
- Disassembling a SkyLight function without Dock: any binary of our own, `lldb -b ./bin -o "b main" -o run -o 'expr (void*)dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",1)' -o "dis -n <Function>"`.
- Which functions Dock calls during an action: attach to Dock and set auto-continuing breakpoints (with Debugging Restrictions off this works without sudo, and Dock doesn't crash):
  ```
  breakpoint set -n SLSTransactionSetSpaceShape -n SLSTransactionSetSpaceTransform -G1
  breakpoint command add 1
  frame info
  register read x1 x2 x3 d0 d1 d2 d3
  DONE
  process continue
  ```
  `lldb -p $(pgrep -x Dock) -s file.lldb > out &`, then the action (e.g. `osascript -e 'tell application "System Events" to key code 19 using {option down}'`), then `pkill -f "lldb -p"`.
- A window's Space and the active Space from the daemon: `CGSGetActiveSpace(CGSMainConnectionID())`, `CGSCopySpacesForWindows(cid, 7, [wid])` — exported by CoreGraphics, linked from Swift through `@_silgen_name` with no extra flags. Verified.

## Space switching in Dock

Verified with the hook log and lldb. Dock does the switch (Ctrl/Option+N, swipe) itself, frame by frame, about every 16 ms (60 Hz), around 15 frames per switch:

1. `SLSTransactionWillSwitchSpaces`
2. `SLSTransactionShowSpace` for the new Space
3. every frame, for the old and the new Space:
   - `SLSTransactionSetSpaceTransform(transaction, sid, u32 = 4, const CGAffineTransform *)` — a pure translation, `tx` going smoothly from 0 to ±display width in pixels (3072 on this screen); neighbouring Spaces are offset by ±3072.
   - `SLSTransactionSetSpaceShape(transaction, sid, CGRegionRef)` — the Space's clip, a new region every frame. This is what gives the black band when the transform is made vertical but the clip stays horizontal.
   - `SLSTransactionSetSafeApertureSpaceReveal(transaction, sid, d0 = progress 0…1, …)` — something about the notch area (safe aperture). Not explored.
4. `SLSTransactionSetManagedDisplayCurrentSpace`, `SLSTransactionHideSpace` for the old one, `SLSTransactionSetSpaceOrderingWeight`.

A Space transform is 2D affine only: translation and scale work (that's how Mission Control works), perspective does not.
Verified with the disassembler: `SLSTransactionSetSpaceTransform` reads exactly 6 doubles from the pointer (CGAffineTransform); the `u32` is passed as a separate number (a flag, meaning unknown). `SLSSpaceSetTransform` also takes 2D (two q registers = 4 doubles + tx/ty). SkyLight has no exports like `Space…3D` / `Space…Warp`.
`SLSSetSessionSwitchCubeAnimation(bool)` — only the "cube on fast user switching" flag, sent to the server root port. Useless for Spaces.
Conclusion: 3D for a Space only works through its windows — `SetWindowTransform3D` on every window of both Spaces (wallpapers are windows too).

The hook in `payload/payload.m` (`hook`) patches the first 16 bytes of the function in Dock's copy of SkyLight (a jump to our stub; the stub swaps the argument and runs the displaced prologue). Verified for `SLSTransactionSetSpaceTransform`: the horizontal shift becomes vertical, the log says `… hooked (kr=0)`.
Prologues on macOS 27 (both free of PC-relative instructions, so they can be copied into the stub):
- `SLSTransactionSetSpaceTransform`: `pacibsp; stp d9,d8,[sp,#-0x40]!; stp x22,x21,[sp,#0x10]; stp x20,x19,[sp,#0x20]`
- `SLSTransactionSetSpaceShape`: `pacibsp; sub sp,sp,#0x50; stp x22,x21,[sp,#0x20]; stp x20,x19,[sp,#0x30]` (`d503237f d10143ff a90257f6 a9034ff4`)

The `SetSpaceShape` hook turns the slide's horizontal clip vertical: it takes the region's bounding box and maps its x range to y with an H/W factor, like the transform. This should remove the black band. **Not verified**: which coordinates the region is in (screen, or the Space before its transform); so far only an assumption that they match the transform.

The hooks work only while the daemon is alive: the daemon sends `P <pid>` every 2 s, and the hook checks `kill(pid, 0)`. Once the daemon exits or crashes, Dock animates by itself again. The patch itself stays until Dock restarts.

Signatures (disassembler; the arguments are visible in lldb during a switch):
- `SLSTransactionShowSpace(transaction, sid)`, `SLSTransactionHideSpace(transaction, sid)` — 2 arguments each.
- `SLSTransactionSetSpaceShape(transaction, sid, CGRegionRef)`. Dock gives a hidden Space `kCGRegionEmptyRegion`.
- `SLSTransactionSetSpaceOrderingWeight(transaction, sid, int)` — Dock sets 1 on the new one and 0 on the old one.
- Regions: `CGRegionCreateWithRect(CGRect)`, `CGRegionIsEmpty`, `CGSGetRegionBounds(region, CGRect *)` are exported by CoreGraphics.
- `CGSCopyManagedDisplaySpaces(cid)` (links from Swift without SkyLight): an array of displays, each with `"Spaces"` (`id64`, `ManagedSpaceID`, `type`: 0 desktop, 4 fullscreen) and `"Current Space"`. Verified.
- Display 3008×1692 pt, Dock's slide is 3072: Spaces sit 64 pt apart, a Space transform is in points. Direction: Dock gives a Space leaving to the right `tx = −3072`, so a Space transform, like a window's, maps screen → Space.

## System Space shortcuts

"Switch to Desktop 1…N" — `com.apple.symbolichotkeys`, keys 118, 119, 120, 121, 122 (desktops 1–5). Parameters `(character, keycode, modifiers)`, Option = 524288, Ctrl = 262144. Keycodes of digits 1–5 on the US layout: 18, 19, 20, 21, 23.
Turning them on without the UI: `defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 118 '<dict>…</dict>'`, then `/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u`. Right now 118–122 are on, bound to Option+1…5.

## Windows

- Moving (`SLSMoveWindowWithGroup` / transactions, even from Dock) is clamped by WindowServer to the screen edge. Verified: a window sent to y = 3000 landed at y = 1541 (part of it stayed on screen); sent to y = −3000 it landed at y = 0. A window can't be hidden off screen by moving it.
- `SLSSetWindowTransform(cid, wid, CGAffineTransform)` — 2D. The matrix is inverted (screen → window), as in yabai. Not rechecked.
- **`SLSTransactionSetWindowTransform3D(transaction, wid, const double m[16])`** — a 4×4 window transform (CATransform3D layout, 16 doubles in a row). Signature from the disassembler: `x0` transaction, `w1` wid, `x2` pointer, offsets 0x00…0x78 are read. In the payload: the `D wid m11 … m44` command.
  Verified on a live window (Dock, macOS 27):
  - The matrix is **inverted**: screen point → window point. `m41=300, m42=150` shifts the window 300 left and 150 up; `m11=m22=2` shrinks the window by half.
  - Units are points. The origin is the window's **top-left corner** (scaling shrinks the window towards that corner).
  - Row convention, as in CATransform3D: `x_window = x·m11 + y·m21 + m41`, `y_window = x·m12 + y·m22 + m42`, `w = x·m14 + y·m24 + m44`.
  - Screen points lie at z=0, so `m34` does nothing. Perspective goes through `m14/m24`, i.e. it is a 2D homography. Recipe: build the forward homography H (3×3, columns, window-local coordinates → screen), take G = H⁻¹, normalize by G[2][2] and lay it out: `m11,m21,m41 = G[0]`, `m12,m22,m42 = G[1]`, `m14,m24,m44 = G[2]`, `m33 = 1`.
  - Rotation about the vertical axis through the window's center with perspective (θ = ±0.6, d = 1500) works: a live window in 3D, drawn even outside its bounds. Script: H = T(c)·P·T(−c), P = `[[cos θ,0,0],[0,1,0],[sin θ/d,0,1]]`.
  - The identity matrix puts the window back as it was.
- `SLSSetWindowWarp` / `SLSTransactionSetWindowWarp` — mesh warp of a window (the genie effect). Not verified.
- `SLSSetSessionSwitchCubeAnimation` — the fast-user-switching cube. Not explored.
- Also available: `SLSSetWindowTransforms` (batched), `SLSTransactionSetSpaceAlpha`, `SLSCreateGenieWindowAnimation`, `SLSSetWindowAnimationProgress`, `SLSAddWindowFilter` / `SLSNewCIFilterByName` (CI filters on windows).
- **WindowServer notifications don't reach a plain process (macOS 27).** A probe registered every type 100…2000 with `SLSRegisterConnectionNotifyProc(cid, handler, type, NULL)` (all returned 0) and with `SLSRegisterNotifyProc(handler, type, NULL)` (412 types refused), with and without `NSApplicationLoad()`, then opened and closed a Finder window through AppleScript: no callback fired at all. Dock gets these as the universal owner; forwarding them from the payload would need a channel from Dock back to the daemon. The daemon uses Accessibility observers per app plus NSWorkspace notifications instead (`daemon/Events.swift`). Not verified that the Finder window really opened during the probe.
- **`CGWindowListCopyWindowInfo` reports window bounds after the Space transform.** Verified: with the overview open (scale 0.4) a 1512×1567 window at (748, 40) was listed as 692×188 at (1158, 825), and windows of the other shown Spaces became "on screen" with negative y. While a Space has a transform, CGWindowList frames can't be trusted: the daemon's strip keeps the frames from its last normal poll then (`syncColumns`, `spaceLayoutBusy`). Otherwise windows really move and shrink (the resize took its width from such a frame).
- `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` shows only windows of the current Space; a window on another Space may have bounds (0, 0) in `.optionAll`.

### Moving a window to another Space (macOS 27)

- From Dock's connection (the payload's `X wid sid`): `SLSMoveWindowsToManagedSpace(cid, [wid], sid)` works. Verified: a test window of a separate process moved from Space 157 to 5.
- From an ordinary process (the daemon's own connection): `SLSMoveWindowsToManagedSpace` and yabai's compat-ID trick (`SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace` + reset) do nothing (see `daemon/Move.swift`).
- **But the bridged operation works from an ordinary process**, also on another process's window:
  `[[SLSBridgedMoveWindowsToManagedSpaceOperation alloc] initWithWindows:@[@(wid)] spaceID:sid]`, then `-performWithWMBridgeDelegate`. Verified with a test window of a separate process: moved to another Space and back, about immediately (checked after 0.7 s with `SLSCopySpacesForWindows`).
  yabai calls `SLSPerformAsynchronousBridgedWindowManagementOperation(op)`, which SkyLight no longer exports on macOS 27; the classes are still there. `SLSAsynchronousBridgedWindowManagementOperation` (the superclass) has `-performWithWMBridgeDelegate` and `-invokeFallback`; the fallback was not needed, not checked what it does.
  nori moves windows through the payload anyway; this is the way to do it without Dock.

## Ideas, not done yet

- Our own effect for switching real Spaces: keep Dock's switch itself (its state: Mission Control, the menu bar), and replace the transform and shape of both Spaces in the hook; for a cube, zero out the Space transform and rotate the windows of both Spaces through `SetWindowTransform3D`, taking progress from Dock's `tx`.
- The overview and our own switching are done, see "Our own Space animation". According to the user, the overview shows the Spaces, so ShowSpace of a non-current Space and the transform formula work.

## Our own Space animation: overview and switching

`step_layout` in `payload/payload.m`, command `Y spring target goal sid0 sid1 …`. The overview and a Space switch are one layout: the display's Spaces one under another, `focus` is the index at the center, `progress` 0 is normal Spaces, 1 is the overview (scale 0.4, gap 48). The payload moves it on every `CVDisplayLink` tick: the overview with a spring (response 0.28, damping 0.78, in real time), a switch like windows (a quarter of the remaining distance per frame). One transaction per frame: ShowSpace + a shape covering the whole display + SetSpaceTransform for every Space; the same transforms are handed to the hook in place of Dock's values.
At first the daemon computed frames on a `Timer` and sent one over the socket per frame — **it stuttered** (the timer isn't aligned with vsync, frames got lost or arrived in pairs). Space animations must live in the payload, like window animations.
The daemon (`daemon/Overview.swift`) intercepts every "Switch to Desktop N" in the event tap (from `com.apple.symbolichotkeys`, read at start), sends `Y` and presses the same shortcut again (it lets its own press through by the `passDesktopHotkeys` counter) so that Dock changes the current Space. The layout finishes only once it is back at progress 0 and `SLSGetActiveSpace` is the target Space (or after 1 s): then the target Space has no transform, the others are hidden, and the hooks let Dock through again.

## Payload → daemon

The payload reports back on the daemon's control socket (`/tmp/nori-ctl_$USER.socket`, the one `nori query/focus` uses), one request per connection, tab-separated: `payload<TAB>layout-done<TAB><seq>` when a Space layout ends (seq from the `Q` line sent before its `Y`, so an older layout's end doesn't unpause a newer one) and `payload<TAB>resize-settled<TAB><wid><TAB><width>` when a width stretch reaches its goal. The daemon unpauses the strip and runs the app's AX resize on these instead of fixed delays; the delays (3 s, 0.8 s) stay only as fallbacks. The payload reads the (empty) reply to EOF before closing, so the daemon never writes to a closed socket. Not yet verified live.
