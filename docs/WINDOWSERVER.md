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

### Windows of our own, through SkyLight only

Prototyped from a plain process (macOS 27) for window borders, which were then dropped. CoreGraphics exports the same calls as `CGS…` (`CGSNewWindow`, `CGWindowContextCreate`, …), so Swift needs no SkyLight:
- `SLSNewWindow(cid, 2, x, y, region, &wid)`: `2` buffered, `region` the shape in window coordinates (`CGRegionCreateWithRect(0, 0, w, h)`), `x, y` top-left on screen. Returns 0.
- A new window's **alpha is 0**: nothing shows until `SLSSetWindowAlpha(cid, wid, 1)`. Then `SLSSetWindowOpacity(cid, wid, false)` for a transparent background, `SLSSetWindowResolution(cid, wid, 2)` on Retina.
- Drawing: `SLWindowContextCreate(cid, wid, NULL)` gives a `CGContext` in points, origin bottom-left; draw, `CGContextFlush`, `SLSFlushWindowContentRegion(cid, wid, NULL)`.
- Resizing: `SLSSetWindowShape(cid, wid, 0, 0, region)`, then draw again into the same context at the new size. Verified.
- Click-through: `SLSSetWindowEventShape(cid, wid, CGRegionCreateEmptyRegion())`. Not verified yet.
- `SLSOrderWindow(cid, wid, 1, 0)` shows it; `SLSReleaseWindow` removes it.
- `SLSSetMouseEventEnableFlag` is not exported on macOS 27.
- **Made in Dock, the same window is opaque black** wherever nothing is drawn (inside the stroke, outside the rounded corners); from a plain process, with or without AppKit, it is transparent. Not found why. A window made by a plain process stays transparent when Dock's connection moves and orders it (verified with `M` and `O` through the payload socket). Made by the daemon that way, two borders were on screen in the right place but showed nothing; left there.

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
Measured with 4 Spaces on a 60 Hz display (temporary counters in `step_layout`): no late ticks, a frame's work (ShowSpace + shape + transform for every Space, commit included) 0.1–0.2 ms on average and under 5 ms at worst. Re-committing the whole layout every frame is not what makes the overview stutter.

### Where the overview's stutter is (WindowServer, not the payload)

- **Measuring what reaches the screen:** `SLSGetPerformanceTotalUpdateCount(cid, uint64_t *count, uint64_t *other)` — the first value goes up by one per screen update WindowServer makes. Polled every 0.5 ms from any process, the intervals between changes are the real frame times (17 ms = 60 Hz). A screen recording (`screencapture -v`) is no good for this: encoding a 6K region loads the same GPU and Mission Control stuttered in it too.
- M1 Pro, one 6016×3384 display at 60 Hz, 4 Spaces, Option+O: the first 500 ms (the opening) gave 6–14 updates, median 39–46 ms, worst ~170 ms; the open overview at rest and the closing were at 17 ms. Mission Control opened the same way gave 24–25 updates, median 17 ms.
- Progress driven linearly 0 → 1 over 2 s with "G" (~120 updates possible): 1 Space in the layout 111, 2 Spaces 78, 4 Spaces 70. At progress 0–0.3, where about one Space is on screen, all three were alike. So it is **scaled Spaces on screen while their transform changes** that cost; at rest WindowServer keeps up even with every Space re-committed every frame.
- Not the cause: input timing (a layout run straight from the socket stutters the same), showing the Spaces earlier (the same with them shown off screen for a second before opening), the animated wallpaper (`WallpaperImageExtension` took 22–29% of the GPU even at idle, but stopping it changed nothing), any one window (Telegram, Shepherd, PiP at alpha 0 changed nothing).
- **It is the GPU, and it is the scale itself.** `sudo sample WindowServer` during the opening and in the open overview: the render thread sits in `semaphore_timedwait_trap` (waiting for the GPU), CPU 40–67% of one core; the stacks that do run are plain CA rendering (`CA::OGL::render_layers`, backdrop blurs for vibrancy windows, `create_surface_with_properties`). GPU "Device Utilization %" (`IORegistryEntry` `IOAccelerator` → `PerformanceStatistics`, no root needed) with the layout held through the socket at a fixed progress, screen 6016×3384 @ 60, a PiP video redrawing on the side, M1 Pro:

  | state (all at rest, step_layout committing every frame) | updates/s | GPU |
  |---|---|---|
  | no layout (the video alone) | 34 | 24% |
  | 4 Spaces, progress 0 (scale 1, only our commits) | 61 | 42% |
  | 4 Spaces, progress 0.002 (scale 0.999, same pixels) | 61 | 70% |
  | 4 Spaces, progress 0.5 (scale 0.7) | 64 | 65% |
  | 4 Spaces, progress 1 (scale 0.4, ~2.4 Spaces on screen) | 43 | 67%, gaps up to 85 ms |
  | 1 Space, progress 1 (scale 0.4) | 64 | 56% |
  | 4 on-screen windows at scale 0.999 by `SetWindowTransform3D`, no layout | 42 | 52% |
  | the same windows at scale 0.4 | 39 | 32% |

  A Space with any scale other than 1 costs about as much GPU as a full extra screen composite, and that does not shrink when the Space is drawn small: at 0.4 the overview's 2–3 visible Spaces don't fit in a 16.7 ms frame and the screen updates every 2–5 vsyncs. A translated Space (the slide, `ty` only) is at 60 Hz. A **window** transform costs in proportion to the pixels it draws (0.999 ≈ a full screen, 0.4 ≈ nothing), so Mission Control's way, windows scaled one by one and Spaces never scaled, is the cheap one.
- The first scaled frame is a hitch of its own: the layout held at progress 0 for 1.5 s (all Spaces shown) and then jumped to 1 gave a 109 ms gap on the first frame, then 50–70 ms ones. WindowServer sets the scaled path up (offscreen surfaces) when the scale first becomes non-1, however the Spaces were shown before.
- Side note from the same numbers: with the layout held settled, `step_layout` still commits every frame and WindowServer redraws the whole screen each time (61 updates/s against 34 with nothing going on). Harmless for the stutter, wasted work at rest.
- Measuring: `SLSGetPerformanceTotalUpdateCount` polled every 0.5 ms for the update rate and gaps; the IOAccelerator statistics for the GPU; `top -l N -s 1 -pid <WindowServer>` for its CPU (`proc_pid_rusage` on it needs root). The layout was driven straight through `/tmp/nori_$USER.socket` (`Q`, `Y 1 target 0 sids…`, then `G progress 0` to hold it) with the daemon stopped (`kill -STOP`) so the strip didn't act on transformed frames, and Option+O was pressed with `osascript … key code 31 using option down` when the real path was wanted.

### How Dock animates (static reading of Dock and SkyLight, macOS 27)

- Dock commits almost every transaction with `SLSTransactionCommitUsingMethod(t, 4)`. Methods 1/2 are `SLSTransactionCommit(t, 1/0)`; 3/4 go to `sls_transaction_commit_ca(t, bool)`, which puts the encoded transaction on the connection's fencing context (`SLSTransactionGetFencingContext`, `setPayload:`), so it lands in WindowServer with Core Animation's commit, in the same frame as Dock's layer changes.
- No `CVDisplayLink` in Dock: dispatch timers and `SLSDisplayGetTiming`. It also calls `SLSTransactionSetManagedDisplayIsAnimating` around its animations.
- Mission Control is Core Animation in Dock's own `CAContext`: `CAPortalLayer` (live window content), `CASpringAnimation`, and snapshots for windows on other Spaces (log string "Returning snapshot-backed miniLayer for window %x on space %s"). It never scales whole Spaces.
- `SLSTransactionSetSpaceTransform`'s `u32` is only encoded and sent; what WindowServer does with it is not known. `SLSTransactionSetWindowResolution` is used by Dock only when it creates its own windows.

### Sticky windows (on every Space)

A window with `canJoinAllSpaces` (a status bar, JankyBorders, PiP) is listed on every Space by `SLSCopySpacesForWindows(cid, 7, [wid])`, but WindowServer draws it with **one** Space's transform.
- Dock's own slide (hooks off, macOS 27): it slides out with the old Space and appears on the new one only when the switch ends. Verified on a screen recording, with the status bar and with a test window (`canJoinAllSpaces | stationary`, floating level). Dock does nothing to keep them in place, so there is nothing to copy from it.
- `CGWindowListCopyWindowInfo` reports their frame with that Space's transform applied (and with a window transform, if any).
- Holding them in place: a window transform that undoes the Space transform. For a Space transform `t` (screen → Space, `a = d`, `b = c = 0`) and a window at origin `o`: `m11 = 1/a`, `m22 = 1/d`, `m41 = (o.x − tx)/a − o.x`, `m42 = (o.y − ty)/d − o.y`, the rest identity. Verified with the overview open (a = 2.5): the test window was back at its own place and size, drawn over the overview.
- **Which Space: the one that last went from hidden to shown**, and they stay with it while it is shown. `ShowSpace` on a Space already shown changes nothing; `HideSpace` + `ShowSpace` in one transaction counts as becoming shown and doesn't blink. Verified with the overview through the payload socket (current Space 157, list `5 157 165 180`): opened on 5 or 165 (hidden before) the status bar stayed put; opened on 157 it went with 5, the last of the others to become shown; with hide + show of the target every frame it stayed put in all of these.
- **Except during Dock's own switch** (from its first frame until the current Space changes): then they go with the current Space, whatever was shown last. That is why they slide out with the old Space in Dock's slide. Seen: with the target held, the status bar sat a screen away (y = −1692) from the end of our slide until `SLSGetActiveSpace` turned to the target, about 250 ms.
- A fractional slide made them shake by about a pixel (the Space transform and the window transform are rounded to pixels separately); a whole-point `ty` doesn't.
- In the payload: `held_space()` is the target, or the current Space once Dock's frames have come in during the layout; `step_layout` hides and shows it again after the others every frame, and the `SetSpaceTransform` hook undoes its transform, in our transactions and in Dock's. Sticky windows are listed when a layout starts and added to on every `Y` (on screen, layer ≥ 0, on more than one Space, centered on the main display); their origins are re-read every frame.
- `SLSGetWindowBounds` gives a window's own frame: no Space transform, no window transform. Verified in the overview: a held status bar and an unheld sticky window both came back with their real frames, while `CGWindowListCopyWindowInfo` had the unheld one scaled and moved.
- JankyBorders' border windows are each on one Space, the one of the window they frame (five of them, all on the current Space, `SLSCopySpacesForWindows`), so they slide with it and are not held.
- Wrong turns, for the record: undoing whichever Space a transaction transforms last (they shook: Dock's frames transform both Spaces and show nothing); showing the target last without hiding it (they stayed with another Space when the target was already shown); a larger `SetSpaceShape` (changed nothing); skipping Dock's `SetSafeApertureSpaceReveal` (changed nothing).
- `SLSTransactionSetSafeApertureSpaceReveal(transaction, sid, double)`: Dock calls it every frame of its switch for both Spaces, the old one going 1 → 0, the new one 0 → 1 (logged). Prologue `pacibsp; stp d9,d8,[sp,#-0x30]!; stp x20,x19,[sp,#0x10]; stp x29,x30,[sp,#0x20]`.
- **The sticky windows still vanish for the ~200 ms between the end of our slide and the Space change** (held = the current Space then, its undo in place), and with them the status bar "cut off" and PiP "blinking" on a switch. Traced on a screen recording (`screencapture -v`, 30 fps, split with ffmpeg) with a diagnostic factor on the undo during `dock_switching`: the bar is in the on-screen window list the whole time, alpha 1, reported at its place, so neither the app nor the model hides it. Undo × 1.5 (the bar lands at y = 0.5 × height): **drawn, on top of the new Space** — so both the Space transform and the window transform apply and nothing covers it. Undo × 1.06 (y ≈ 100 pt): drawn, during the whole slide. Undo × 1.02 (y ≈ 34) and × 1 (y = 0): gone. So during Dock's own switch a top band of the current Space, somewhere between 68 and 100 pt tall, is not drawn, and the sticky windows in it go with it: the status bar (0–34) entirely, the PiP (from y 68) its top. **The band is the system menu bar, window level 24**, drawn over the top of the screen for the whole of Dock's switch even though it is auto-hidden (`_HIHideMenuBar`; transparent on macOS 27, so the wallpaper shows through it). Shown with three sticky, stationary test windows 34 pt tall at y = 0 (`canJoinAllSpaces | stationary`): level 23 (the status bar's) is gone for the usual 6–7 frames, levels 25 and 1000 stay, except for one frame right at the Space change (the handoff of the sticky windows to the new Space; that single frame is the PiP's "blink"). Not it, each hooked the same way as the Space transform and checked on a recording: `SetSafeApertureSpaceReveal` forced to 1 or to 0 for the layout's Spaces (its third argument is a double, `frintm d0, d8` in the prologue), and `SLSTransactionSetMenuBarSystemOverrideAlpha(transaction, id, float)`, which Dock doesn't even call during a switch; `CGWindowListCopyWindowInfo` doesn't list the menu bar window either. So the undo transform is right and nothing in the payload can lift the sticky windows above the menu bar; a status bar wants level ≥ 25 (`NSStatusWindowLevel`), and a PiP at level 3 keeps losing its top band for those frames. (Later: narrow panels at levels 3 and 26 lost nothing once the current-Space change was handled, see below; what still took the bar out at level 25 was its full width.)
- **A window spanning the top edge of the screen from side to side is hidden during Dock's switch, whatever its level.** That is what kept taking the status bar out (7–15 frames per switch, from the middle of the slide), long after it moved to level 25. Recorded with sticky test panels 34 pt tall (`canJoinAllSpaces`), one at a time, on normal switches: full width at y = 0, level 26: gone for 10 frames, like the bar; 3000 wide at x = 4, y = 0: none lost; full width at y = 2: none lost; full width 1 pt above the screen (y = −1, 35 tall): none lost; 1 pt past both sides (x = −1, 3010 wide): none lost. The same status bar app run a second time one bar lower (`STATUSBAR_STACK=1`, y = 34) lost nothing, and a narrow level-25 panel under the bar showed exactly while the bar was gone; a panel redrawn every 50 ms and one ordered front every 100 ms behaved like still ones. So it is the frame, not the app or the level: a full-width status bar wants to be 1 pt wider than the screen on each side (or 1 pt taller, above it). Nothing in the payload changes this; it goes by the window's frame.
- **The last frame lost by every sticky window was the current-Space change**, which mostly falls in the middle of our slide (motion in frames 91–103, the change at 98 or 99). Dock makes the target current with `SLSTransactionSetManagedDisplayCurrentSpace(transaction, CFStringRef display uuid, uint64_t sid)` (prologue `pacibsp; stp x22,x21,[sp,#-0x30]!; stp x20,x19,[sp,#0x10]; stp x29,x30,[sp,#0x20]`). The windows go over to the new current Space when that transaction is committed, but `SLSGetActiveSpace` answers the old one until then, so the undo set in the same transaction (the `SetSpaceTransform` hook) was the old Space's: one frame off screen, until the next `step_layout`. The payload hooks it (`nori_current_space`): the new Space's undo goes into that transaction, and `held_space()` uses that Space from then on. After that: four switches, up and down, with a level-26 panel at y = 0 and a level-3 one at y = 40 (where a PiP sits): no frame lost.
- Also in place, not seen to matter on its own because the change comes before our slide ends: once our slide is over and Dock's switch isn't, the old Space is put where the target is (under it), so that a late change goes between two untransformed Spaces.
- How it was measured: `screencapture -x -v -R0,0,3008,120 -V 6 out.mov` (it starts about 2.3 s late; switch about 3.2 s in), `nori focus space N`, then per frame at 30 fps (`ffmpeg -vf fps=30,crop=…`): for the bar, the mean difference of its icon area against frame 0 (> 5 means gone: the brightness of the band alone misses it when a light window shows through); for test panels, whether their color channel dominates. 4096 px of video are 3008 pt.
- Apps that judge windows by `CGWindowListCopyWindowInfo` frames get them transformed during a Space animation. The status bar (dotfiles `statusbar`) went blank mid-switch while its window was held in place and test windows at the same spot and level stayed; most likely its fullscreen check (`Fullscreen.swift`: a full-width layer-0 window at the top edge) caught a window of the sliding Space and ordered the bar out. From the code, not traced.
- **Fullscreen Spaces (type 4) don't take the sticky windows in Dock's switch.** `SLSSpaceGetType(cid, sid)` gives the type (0 desktop, 4 fullscreen; 3 for an unknown id). The status bar is listed on the fullscreen Space too (`SLSCopySpacesForWindows`), but leaving one for a Desktop it was drawn with the target Desktop from the start of Dock's switch, while `SLSGetActiveSpace` still answered the fullscreen Space: a whole Space off (y = −1692, or −725 in the overview, one slot) for ~0.3 s, until the change; 4 of 4 runs, plain and in the overview. Between two Desktops the same overview move was off for 1–3 frames only. `held_space()` holds the target then. Entering a fullscreen Space the bar jumped once, 0.12 s, to y = −3384 right after the change; held with the Desktop the switch came from now, not traced further. (Measured by polling the bar's `CGWindowListCopyWindowInfo` frame and the active Space every 5 ms.)
- **In the overview the sticky windows changed Space a frame after the payload's undo did**, at both handoffs of a move between two Desktops (Desktop 3 → 2; 2 → 3 was clean): Dock's first switch frame (the undo went to the current Space, the bar was still drawn with the target: −725, one slot) and the current-Space change (undo for the new one, bar still with the old one: +724). One frame each, 4 ms polling. Now Dock's first switch transaction still undoes the target, and the change's transaction hides and shows the new current Space, so it is the one that last became shown in the commit the undo is in. Not yet verified live.
- **`SLSGetWindowBounds` leaves window transforms out, and shows an app's resize the frame it lands.** Own test window: 600 wide under a 1.5× stretch (`SetWindowTransform3D`), 900 about 12 ms after `-setFrame:` to 900. The width stretch ("R") now drops itself when the window's own width reaches the goal, checked every millisecond while it waits for the app, instead of waiting for "W", which comes an AX round trip later: each frame between was drawn stretched twice.
- **Dock hides the Space it leaves in the transaction that ends its switch, and entering a fullscreen Space it hides every Desktop.** Mid-layout that blanked them for a frame until `step_layout` showed them again: in the overview, one sample (~8 ms) with the old Space's windows, or every Desktop's, missing from the on-screen list. The payload hooks `SLSTransactionHideSpace(transaction, sid)` (prologue `pacibsp; stp x20,x19,[sp,#-0x20]!; stp x29,x30,[sp,#0x10]; add x29,sp,#0x10`, `d503237f a9be4ff4 a9017bfd 910043fd`) and drops Dock's hides of the layout's Spaces while it runs; its own hides go through. Not yet verified live.

The daemon (`daemon/Overview.swift`) intercepts every "Switch to Desktop N" in the event tap (from `com.apple.symbolichotkeys`, read at start), sends `Y` and presses the same shortcut again (it lets its own press through by the `passDesktopHotkeys` counter) so that Dock changes the current Space. The layout finishes only once it is back at progress 0 and `SLSGetActiveSpace` is the target Space (or after 1 s): then the target Space has no transform, the others are hidden, and the hooks let Dock through again.

### Something behind the overview's Spaces

Between and around the scaled Spaces the screen is black: nothing is below them. A window can't go there by itself: a Space is composited as one layer, so even a window at the lowest level, sticky or not, is drawn with its Space (a sticky one with the held Space, on top of the others). Inferred from the sticky-window findings above, not tried.
- **A Space of our own at a negative absolute level is.** From the daemon's connection, no Dock needed: `CGSSpaceCreate(cid, 1, 0)`, `CGSSpaceSetAbsoluteLevel(cid, sid, -1)`, `CGSSpaceAddWindowsAndRemoveFromSpaces(cid, sid, [wid], 7)`, then `CGSShowSpaces`/`CGSHideSpaces(cid, [sid])` to show or hide it. The desktops are at absolute level 0 (`CGSSpaceGetAbsoluteLevel`). Verified with a full-screen red window and the overview open: at level 0 it covered every Space's wallpaper (drawn above it, below the apps' windows); at -1 and at -1000 it was only around the Spaces, wallpapers whole.
- The window there is on screen only while its Space is shown (`CGWindowListCopyWindowInfo` on-screen lists it then, not after `HideSpaces`), and `CopySpacesForWindows` gives just that Space, so the payload's sticky list leaves it alone. At layer 0 it would look like an app window to anything that lists them; at the desktop level it doesn't, and in a Space of its own the level changes nothing on screen.
- This is `overview-background = "blur"` (`showBackdrop` in `daemon/Overview.swift`).

## Payload → daemon

The payload reports back on the daemon's control socket (`/tmp/nori-ctl_$USER.socket`, the one `nori query/focus` uses), one request per connection, tab-separated: `payload<TAB>layout-done<TAB><seq>` when a Space layout ends (seq from the `Q` line sent before its `Y`, so an older layout's end doesn't unpause a newer one) and `payload<TAB>resize-settled<TAB><wid><TAB><width>` when a width stretch reaches its goal. The daemon unpauses the strip and runs the app's AX resize on these instead of fixed delays; the delays (3 s, 0.8 s) stay only as fallbacks. The payload reads the (empty) reply to EOF before closing, so the daemon never writes to a closed socket. Not yet verified live.
