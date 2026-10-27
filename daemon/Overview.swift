// Overview, like niri's: every Space of the display, scaled down and stacked vertically, windows live.
// A plain Space switch is the same layout at scale 1: the Space at the center slides to the new one.
// The payload animates both on vsync (step_layout in payload.m); the daemon only says where to go with "Y".
// Dock still owns which Space is current: picking another Space presses its "Switch to Desktop N" shortcut
// (switchToSpace in Control.swift), and Dock's switch runs hidden under ours.
// ponytail: main display only; a click picks a Space, not a window. Scale and gap live in payload.m.

import Cocoa

let overviewScale: CGFloat = 0.4  // same as OVERVIEW_SCALE and OVERVIEW_GAP in payload.m, for hit testing
let overviewGap: CGFloat = 48

var overviewOpen = false
var overviewSpaces: [UInt64] = []  // desktops of the display, top to bottom
var overviewTarget = 0             // index of the Space at the center once the animation settles
var passDesktopHotkeys = 0  // our own presses of "Switch to Desktop N", let through to Dock

// The "Switch to Desktop N" shortcuts (symbolic hotkeys 118…133), read once at start.
let desktopHotkeys: [(chord: Chord, number: Int)] = {
    let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
    return (1...16).compactMap { number in
        guard let entry = hotkeys[String(117 + number)] as? [String: Any], entry["enabled"] as? Bool == true,
              let keys = (entry["value"] as? [String: Any])?["parameters"] as? [Int], keys.count == 3
        else { return nil }
        return ((Int64(keys[1]), CGEventFlags(rawValue: UInt64(keys[2])).intersection(chordModifiers)), number)
    }
}()

func desktopNumber(for event: CGEvent) -> Int? {
    desktopHotkeys.first { matches(event, $0.chord) }?.number
}

// Every Space switch nori starts goes through here, so subscribers hear of the target before Dock's slide.
func pressDesktop(_ number: Int) {
    passDesktopHotkeys += 1
    if !switchToSpace(number) {
        passDesktopHotkeys -= 1
        fputs("\"Switch to Desktop \(number)\" shortcut is off; enable it in System Settings → Keyboard → Shortcuts → Mission Control\n", stderr)
        return
    }
    if let sid = spaces().first(where: { $0.number == number })?.id {
        pendingSpace = (sid, CACurrentMediaTime() + spaceLayoutFallback)
        publishSoon()
    }
}

// Desktops (not full-screen Spaces) of the display that shows the active Space, in Mission Control order.
func desktopSpaces() -> (ids: [UInt64], current: Int) {
    let active = CGSGetActiveSpace(cid)
    let displays = CGSCopyManagedDisplaySpaces(cid).takeRetainedValue() as? [[String: Any]] ?? []
    for display in displays {
        let spaces = (display["Spaces"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? Int == 0 }
            .compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        if let current = spaces.firstIndex(of: active) { return (spaces, current) }
    }
    return ([active], 0)
}

// The strip must not look at windows while a Space layout is on (see syncColumns). The payload says when one
// ends ("layout-done", Control.swift); the deadline is only for a payload that doesn't (an old one, or Dock gone).
var spaceLayoutUntil: CFTimeInterval = 0
var spaceLayoutBusy: Bool { overviewOpen || CACurrentMediaTime() < spaceLayoutUntil }
var layoutSeq = 0
let spaceLayoutFallback = 3.0

func spaceLayoutDone(_ seq: Int) {
    guard seq == layoutSeq else { return }  // a later "Y" is still running
    spaceLayoutUntil = 0
    pollSoon()
}

// spring: the overview opening and closing; otherwise the windows' ease.
func sendLayout(open: Bool, spring: Bool) {
    spaceLayoutUntil = CACurrentMediaTime() + spaceLayoutFallback
    layoutSeq += 1
    // The Space-changed event lands while the strip is paused; layout-done polls, this is in case it never comes.
    DispatchQueue.main.asyncAfter(deadline: .now() + spaceLayoutFallback + 0.05) { pollSoon() }
    send(["Q \(layoutSeq)", "Y \(spring ? 1 : 0) \(overviewTarget) \(open ? 1 : 0) " + overviewSpaces.map(String.init).joined(separator: " ")])
}

// Every "Switch to Desktop N" press lands here (keys, Option+J/K, nori focus space), and Dock switches under our slide.
func switchSpaceAnimated(to number: Int) {
    guard let sid = spaces().first(where: { $0.number == number })?.id else { return }
    if overviewOpen {
        if let index = overviewSpaces.firstIndex(of: sid) { closeOverview(at: index) }
        return
    }
    let desktops = desktopSpaces()
    guard let index = desktops.ids.firstIndex(of: sid) else { pressDesktop(number); return }  // another display: Dock's slide
    guard sid != CGSGetActiveSpace(cid) || index != overviewTarget else { return }
    overviewSpaces = desktops.ids
    overviewTarget = index
    sendLayout(open: false, spring: false)
    pressDesktop(number)
}

func toggleOverview() {
    overviewOpen ? closeOverview(at: overviewTarget) : openOverview()
}

func openOverview() {
    guard !overviewOpen else { return }
    let desktops = desktopSpaces()
    overviewSpaces = desktops.ids
    overviewTarget = desktops.current
    overviewOpen = true
    sendLayout(open: true, spring: true)
}

// 4-finger swipe (Trackpad.swift): the overview follows the fingers, then the lift springs it open or closed.
func beginOverviewSwipe() {
    if !overviewOpen {
        let desktops = desktopSpaces()
        overviewSpaces = desktops.ids
        overviewTarget = desktops.current
    }
    sendLayout(open: overviewOpen, spring: true)  // starts the layout if it isn't running
    overviewOpen = true  // the strip stays off its windows while the Spaces are transformed
}

// progress: 0 closed, 1 open, past either end it stretches like rubber. velocity: progress per second.
func followOverviewSwipe(progress: CGFloat, velocity: CGFloat) {
    let clamped = min(max(progress, 0), 1)
    spaceLayoutUntil = CACurrentMediaTime() + spaceLayoutFallback
    send(["G \(clamped + rubberBand(progress - clamped, 0.5)) \(velocity)"])
}

func endOverviewSwipe(open: Bool) {
    if open { sendLayout(open: true, spring: true) } else { closeOverview(at: overviewTarget) }
}

// 3-finger vertical swipe (Trackpad.swift): the Spaces follow the fingers, in the overview or not.
// Returns the index the swipe starts from.
func beginSpaceSwipe() -> CGFloat {
    if !overviewOpen {
        let desktops = desktopSpaces()
        overviewSpaces = desktops.ids
        overviewTarget = desktops.current
        sendLayout(open: false, spring: false)  // starts the layout if it isn't running
    }
    return CGFloat(overviewTarget)
}

// focus: index of the Space at the center; past the first or last Space it stretches like rubber.
func followSpaceSwipe(focus: CGFloat, velocity: CGFloat) {
    let clamped = min(max(focus, 0), CGFloat(overviewSpaces.count - 1))
    spaceLayoutUntil = CACurrentMediaTime() + spaceLayoutFallback
    send(["F \(clamped + rubberBand(focus - clamped, 0.5)) \(velocity)"])
}

// A flick goes on to the next Space in its direction; a slow lift picks the nearest. Dock then switches to it.
// The flick speed is in Spaces per second: 0.75 is the same finger speed as 1.5 was before a Space took twice the travel.
let spaceFlickSpeed: CGFloat = 0.75

func endSpaceSwipe(focus: CGFloat, velocity: CGFloat) {
    let index = abs(velocity) > spaceFlickSpeed ? Int(focus.rounded(velocity > 0 ? .up : .down)) : Int(focus.rounded())
    overviewTarget = min(max(index, 0), overviewSpaces.count - 1)
    sendLayout(open: overviewOpen, spring: overviewOpen)
    let sid = overviewSpaces[overviewTarget]
    if sid != CGSGetActiveSpace(cid), let number = spaces().first(where: { $0.id == sid })?.number { pressDesktop(number) }
}

// Zooms into Space `index`, switching to it if it isn't the current one.
func closeOverview(at index: Int) {
    guard overviewOpen else { return }
    overviewOpen = false
    overviewTarget = index
    sendLayout(open: false, spring: true)
    let sid = overviewSpaces[index]
    if sid != CGSGetActiveSpace(cid), let number = spaces().first(where: { $0.id == sid })?.number { pressDesktop(number) }
}

// Quitting with the overview open would leave Spaces scaled in Dock; the payload finishes closing on its own.
func resetOverview() {
    guard overviewOpen else { return }
    overviewOpen = false
    overviewTarget = overviewSpaces.firstIndex(of: CGSGetActiveSpace(cid)) ?? overviewTarget
    sendLayout(open: false, spring: false)
}

// Where Space i sits in the open overview, in CG coordinates.
func overviewRect(_ i: Int) -> CGRect {
    let screen = CGDisplayBounds(CGMainDisplayID())
    let size = CGSize(width: screen.width * overviewScale, height: screen.height * overviewScale)
    let centerY = screen.midY + CGFloat(i - overviewTarget) * (size.height + overviewGap)
    return CGRect(x: screen.midX - size.width / 2, y: centerY - size.height / 2, width: size.width, height: size.height)
}

func overviewIndex(at point: CGPoint) -> Int? {
    overviewSpaces.indices.first { overviewRect($0).contains(point) }
}

// The Space under the point and the window there, if any. CGWindowList shows windows transformed now, so frames
// come from the strips as last seen; a Space the daemon hasn't been on yet has no windows to hit.
func overviewHit(at point: CGPoint) -> (space: Int, window: UInt32?)? {
    guard let i = overviewIndex(at: point) else { return nil }
    let screen = CGDisplayBounds(CGMainDisplayID()), rect = overviewRect(i)
    let unscaled = CGPoint(x: screen.midX + (point.x - rect.midX) / overviewScale, y: screen.midY + (point.y - rect.midY) / overviewScale)
    let sid = overviewSpaces[i]
    let ids = sid == currentSpace ? columns : savedStrips[sid]?.columns ?? []
    return (i, ids.first { lastSeen[$0]?.frame.contains(unscaled) == true })
}

// Mouse in the open overview (the event tap sends it here and keeps it from apps). A click picks a Space, and the
// window under it if any. A drag moves a window: it follows the pointer inside its own Space and, dropped on
// another Space, goes there and joins that Space's strip when it is next shown.
// ponytail: the dragged window is clipped to its own Space while dragged; moving it into the other Space's
// picture would need a transform on the window.
var overviewDrag: (window: UInt32, from: Int, start: CGPoint, origin: CGPoint, moved: Bool)?

func overviewMouseDown(at point: CGPoint) {
    overviewDrag = overviewHit(at: point).flatMap { hit in
        hit.window.flatMap { id in lastSeen[id].map { (id, hit.space, point, $0.frame.origin, false) } }
    }
}

func overviewMouseDragged(at point: CGPoint) {
    guard var drag = overviewDrag else { return }
    let dx = point.x - drag.start.x, dy = point.y - drag.start.y
    guard drag.moved || hypot(dx, dy) >= 6 else { return }
    drag.moved = true
    overviewDrag = drag
    send(["M \(drag.window) \(drag.origin.x + dx / overviewScale) \(drag.origin.y + dy / overviewScale)"])
}

func overviewMouseUp(at point: CGPoint) {
    defer { overviewDrag = nil }
    guard overviewOpen else { return }
    guard let drag = overviewDrag, drag.moved else { return overviewClick(at: point) }
    send(["M \(drag.window) \(drag.origin.x) \(drag.origin.y)"])  // back in its slot, or where it lands elsewhere
    guard let to = overviewIndex(at: point), to != drag.from else { return }
    let sid = overviewSpaces[to]
    movedAway.insert(drag.window)  // Move.swift: out of this strip until CGWindowList agrees
    send(["X \(drag.window) \(sid)"])
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { movedAway.remove(drag.window) }
}

func overviewClick(at point: CGPoint) {
    guard let hit = overviewHit(at: point) else { return closeOverview(at: overviewTarget) }
    closeOverview(at: hit.space)
    guard let window = hit.window else { return }
    // Once Dock has switched (if it had to), the strip there is the current one: focus that window's column.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        _ = syncColumns()
        if let index = columns.firstIndex(of: window) { focusColumn(at: index) }
    }
}
