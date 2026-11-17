// Overview, like niri's: every Space of one display, scaled down and stacked vertically, windows live. That is the
// focused display for the key, the one under the pointer for a swipe; the other displays stay as they are.
// A plain Space switch is the same layout at scale 1: the Space at the center slides to the new one.
// The payload animates both on vsync (step_layout in payload.m); the daemon only says where to go with "Y".
// Dock still owns which Space is current: picking another Desktop runs its "Switch to Desktop N" code (pressDesktop),
// a fullscreen Space goes through pressSpace, and Dock's switch runs hidden under ours.
// ponytail: a click picks a Space, not a window. The gap lives in payload.m, the scale goes along with each layout.
// ponytail: niri opens it on all displays. One layout at a time keeps payload.m simple; a click elsewhere just closes it.

import Cocoa

let overviewGap: CGFloat = 48  // same as OVERVIEW_GAP in payload.m, for hit testing

var overviewOpen = false { didSet { updateTapState { $0.overviewOpen = overviewOpen } } }
var overviewDisplay = displays[0]  // the display the Space layout is on
var overviewSpaces: [UInt64] = []  // Spaces of that display, fullscreen ones included, top to bottom
var overviewTarget = 0             // index of the Space at the center once the animation settles

func desktopNumber(for event: CGEvent) -> Int? {
    desktopHotkeys.first { matches(event, $0.chord) }?.number
}

// Every Space switch nori starts goes through here, so subscribers hear of the target before Dock's slide.
// Dock's own code ("V") when the payload found it, about 25 ms sooner than a posted shortcut (docs/WINDOWSERVER.md).
// The shortcut stays for a macOS where it didn't, and for a Dock that lost the payload.
func pressDesktop(_ number: Int) {
    if !desktopsEditable || !send(["V \(number)"]) {
        updateTapState { $0.passDesktopHotkeys += 1 }
        if !postDesktopHotkey(number) {
            updateTapState { $0.passDesktopHotkeys -= 1 }
            fputs("\"Switch to Desktop \(number)\" shortcut is off; enable it in System Settings → Keyboard → Shortcuts → Mission Control\n", stderr)
            switchFailed()
            return
        }
    }
    if let sid = spaces().first(where: { $0.number == number })?.id {
        pendingSpace = (sid, CACurrentMediaTime() + spaceLayoutFallback)
        publishSoon()
    }
}

// No press, so no switch. A layout sent for it comes back: it would end on a Space Dock isn't on, with the current one hidden.
func switchFailed() {
    NSSound.beep()
    checkShortcuts()
    overviewTarget = overviewSpaces.firstIndex(of: CGSGetActiveSpace(cid)) ?? overviewTarget
    if spaceLayoutBusy { sendLayout(open: overviewOpen, spring: overviewOpen) }
}

// Every switch to a Space nori starts. A Desktop: pressDesktop. A fullscreen Space has no number:
// "Move right a space" / "Move left a space" (symbolic hotkeys 81 / 79, Ctrl+→/← by default) as many times as it
// is away in Mission Control order, the same order as displaySpaces. Dock merges quick presses into one switch
// (Desktop 1 to a fullscreen Space four steps away: one switch, 0.77 s). With those shortcuts off, the app is
// brought to the front (bringAppFront), which reaches the Space only if the app's front window is the one there.
func pressSpace(_ sid: UInt64) {
    guard sid != CGSGetActiveSpace(cid) else { return }
    if let number = spaces().first(where: { $0.id == sid })?.number { return pressDesktop(number) }
    refreshDisplays()
    let shown = display(of: sid), stack = stack(on: shown)
    guard let index = stack.ids.firstIndex(of: sid) else { return }
    let steps = index - stack.current
    let focused = shown.spaces.contains(CGSGetActiveSpace(cid))  // those shortcuts act on the display that has focus
    if !focused || !postSymbolicHotkey(steps > 0 ? 81 : 79, times: abs(steps)) {
        if focused {
            fputs("fullscreen Space: turn on \"Move left a space\" and \"Move right a space\" in System Settings → Keyboard → Shortcuts → Mission Control (any keys)\n", stderr)
            checkShortcuts()
        }
        guard let win = listWindows([]).first(where: { $0.spaces == [sid] })?.win else { return switchFailed() }  // not a sticky one
        bringAppFront(win)
    }
    pendingSpace = (sid, CACurrentMediaTime() + spaceLayoutFallback)
    publishSoon()
}

// `nori focus space N --instant`: no slide. Dock switches as usual, but the payload hands its frames identity
// transforms, so the new Space is just there. ponytail: "I 0" after a fixed second, Dock's switch takes ~250 ms.
func switchSpaceInstant(to number: Int) -> Bool {
    guard spaces().contains(where: { $0.number == number }) else { return false }
    send(["I 1"])
    pressDesktop(number)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { send(["I 0"]) }
    return true
}

// The Space layout goes on this display, at the Space it shows.
func useStack(on display: Display) {
    let stack = stack(on: display)
    overviewDisplay = display
    overviewSpaces = stack.ids
    overviewTarget = stack.current
}

// The strip must not look at windows while a Space layout is on (see syncColumns). The payload says when one
// ends ("layout-done", Control.swift); the deadline is only for a payload that doesn't (an old one, or Dock gone).
// ponytail: one flag for all displays, so a slide on one pauses the strips of the others too; per display if that shows.
var spaceLayoutUntil: CFTimeInterval = 0
var spaceLayoutBusy: Bool { overviewOpen || CACurrentMediaTime() < spaceLayoutUntil }
var layoutSeq = 0
let spaceLayoutFallback = 3.0

func spaceLayoutDone(_ seq: Int) {
    guard seq == layoutSeq else { return }  // a later "Y" is still running
    if !overviewOpen { hideBackdrop() }
    spaceLayoutUntil = 0
    pollSoon()
    publishSoon()  // isAnimating, for subscribers
}

// spring: the overview opening and closing; otherwise the windows' ease.
func sendLayout(open: Bool, spring: Bool) {
    guard !payloadLost else { return }  // no payload to end it: the strip stays on, and Dock does its own slide
    spaceLayoutUntil = CACurrentMediaTime() + spaceLayoutFallback
    layoutSeq += 1
    // The Space-changed event lands while the strip is paused; layout-done polls, this is in case it never comes.
    DispatchQueue.main.asyncAfter(deadline: .now() + spaceLayoutFallback + 0.05) { pollSoon() }
    timeAnimations(to: overviewDisplay.id)
    send(displayLines() + ["Q \(layoutSeq)", "Z \(overviewScale)", "Y \(spring ? 1 : 0) \(overviewTarget) \(open ? 1 : 0) " + overviewSpaces.map(String.init).joined(separator: " ")])
    publishSoon()  // isAnimating, for subscribers
    if open { showSpaceButtonsSoon() }
}

// Keys and "Switch to Desktop N" presses land here, and Dock switches under our slide.
func switchSpaceAnimated(toDesktop number: Int) {
    if let sid = spaces().first(where: { $0.number == number })?.id { switchSpaceAnimated(to: sid) }
}

// Option+J/K too, which may land on a fullscreen Space.
func switchSpaceAnimated(to sid: UInt64) {
    if overviewOpen {
        if let index = overviewSpaces.firstIndex(of: sid) { closeOverview(at: index) }
        return
    }
    refreshDisplays()
    let shown = display(of: sid)
    // Dock's slide with separate Spaces off: one Space over all displays, and no layout goes by one of them.
    guard separateSpaces, let index = shown.spaces.firstIndex(of: sid) else { pressSpace(sid); return }
    // Already there, unless a slide away from it is under way: at most focus goes to its display.
    if sid == shown.current && (shown.id != overviewDisplay.id || index == overviewTarget) {
        if sid != CGSGetActiveSpace(cid) { focusDisplay(shown) }
        return
    }
    useStack(on: shown)
    overviewTarget = index
    sendLayout(open: false, spring: false)
    pressSpace(sid)
}

func toggleOverview() {
    overviewOpen ? closeOverview(at: overviewTarget) : openOverview()
}

func openOverview() {
    guard !overviewOpen, separateSpaces, !payloadLost else { return }
    useStack(on: focusedDisplay())
    overviewOpen = true
    showBackdrop()
    sendLayout(open: true, spring: true)
}

// 4-finger swipe (Trackpad.swift): the overview follows the fingers, then the lift springs it open or closed.
func beginOverviewSwipe() {
    guard !payloadLost else { return }
    if !overviewOpen {
        let under = pointerDisplay()
        if under.id != focusedDisplay().id { focusDisplay(under) }  // keys in the overview go by focus
        useStack(on: under)
        showBackdrop()
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

// 3-finger vertical swipe (Trackpad.swift): the Spaces follow the fingers on nori's layout, in the overview or not,
// on the spring windows glide on. Dock's own swipe (docs/WINDOWSERVER.md) was tried and finished too slowly.
// Returns the index the swipe starts from.
func beginSpaceSwipe() -> CGFloat {
    if !overviewOpen {
        useStack(on: pointerDisplay())
        sendLayout(open: false, spring: false)  // starts the layout if it isn't running
    }
    return CGFloat(overviewTarget)
}

// focus: index of the Space at the center; past the first or last Space it stretches like rubber.
func followSpaceSwipe(focus: CGFloat, velocity: CGFloat) {
    spaceLayoutUntil = CACurrentMediaTime() + spaceLayoutFallback
    let clamped = min(max(focus, 0), CGFloat(overviewSpaces.count - 1))
    send(["F \(clamped + rubberBand(focus - clamped, 0.5)) \(velocity)"])
}

// A flick goes on to the next Space in its direction; a slow lift picks the nearest. Dock then switches to it.
// The flick speed is in Spaces per second: 0.75 is the same finger speed as 1.5 was before a Space took twice the travel.
let spaceFlickSpeed: CGFloat = 0.75

func endSpaceSwipe(focus: CGFloat, velocity: CGFloat) {
    let index = abs(velocity) > spaceFlickSpeed ? Int(focus.rounded(velocity > 0 ? .up : .down)) : Int(focus.rounded())
    overviewTarget = min(max(index, 0), overviewSpaces.count - 1)
    sendLayout(open: overviewOpen, spring: overviewOpen)
    pressSpace(overviewSpaces[overviewTarget])
}

// Zooms into Space `index`, switching to it if it isn't the current one.
func closeOverview(at index: Int) {
    guard overviewOpen else { return }
    overviewOpen = false
    hideSpaceButtons()
    overviewTarget = index
    sendLayout(open: false, spring: true)
    pressSpace(overviewSpaces[index])
}

// Quitting with the overview open would leave Spaces scaled in Dock; the payload finishes closing on its own.
func resetOverview() {
    guard overviewOpen else { return }
    overviewOpen = false
    hideSpaceButtons()
    refreshDisplays()
    overviewTarget = stack(on: display(of: overviewSpaces[overviewTarget])).current
    sendLayout(open: false, spring: false)
}

// overview-background = "blur": the wallpaper, blurred and dimmed by 30%, behind the overview's Spaces. It is a
// window in a Space of its own at absolute level -1, below every desktop (they are at 0), so it shows only around
// and between the scaled Spaces; shown while the overview is open or closing.
// ponytail: the wallpaper as desktopImageURL gives it; one it can't read (a video) leaves black.
@_silgen_name("CGSSpaceCreate") func CGSSpaceCreate(_ cid: Int32, _ flags: Int32, _ options: Int32) -> UInt64
@_silgen_name("CGSSpaceSetAbsoluteLevel") func CGSSpaceSetAbsoluteLevel(_ cid: Int32, _ sid: UInt64, _ level: Int32) -> Int32
@_silgen_name("CGSShowSpaces") func CGSShowSpaces(_ cid: Int32, _ sids: CFArray) -> Int32
@_silgen_name("CGSHideSpaces") func CGSHideSpaces(_ cid: Int32, _ sids: CFArray) -> Int32
@_silgen_name("CGSSpaceAddWindowsAndRemoveFromSpaces")
func CGSSpaceAddWindowsAndRemoveFromSpaces(_ cid: Int32, _ sid: UInt64, _ wids: CFArray, _ mask: Int32) -> Int32

var backdrop: (window: NSWindow, space: UInt64, wallpaper: URL?)?

func showBackdrop() {
    guard overviewBlur, let screen = nsScreen(of: overviewDisplay) else { return }
    if backdrop == nil {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))  // not layer 0: no one lists it as an app window
        window.ignoresMouseEvents = true
        window.contentView!.layer = CALayer()
        window.contentView!.wantsLayer = true
        window.contentView!.layer!.contentsGravity = .resizeAspectFill
        window.contentView!.layer!.opacity = 0.7  // over the black window: a 30% black overlay
        window.orderFrontRegardless()
        let space = CGSSpaceCreate(cid, 1, 0)
        _ = CGSSpaceSetAbsoluteLevel(cid, space, -1)
        _ = CGSSpaceAddWindowsAndRemoveFromSpaces(cid, space, [window.windowNumber] as CFArray, 7)
        backdrop = (window, space, nil)
    }
    let wallpaper = NSWorkspace.shared.desktopImageURL(for: screen)
    if wallpaper != backdrop!.wallpaper {
        backdrop!.wallpaper = wallpaper
        backdrop!.window.contentView!.layer!.contents = wallpaper.flatMap(blurred)
    }
    backdrop!.window.setFrame(screen.frame, display: false)
    // Moved to another display it would have gone to that display's Space.
    _ = CGSSpaceAddWindowsAndRemoveFromSpaces(cid, backdrop!.space, [backdrop!.window.windowNumber] as CFArray, 7)
    _ = CGSShowSpaces(cid, [backdrop!.space] as CFArray)
}

func hideBackdrop() {
    if let space = backdrop?.space { _ = CGSHideSpaces(cid, [space] as CFArray) }
}

// Scaled down to 960 px wide first: the blur is cheap there and wipes out the detail anyway.
func blurred(_ url: URL) -> CGImage? {
    guard let image = CIImage(contentsOf: url) else { return nil }
    let small = image.transformed(by: CGAffineTransform(scaleX: 960 / image.extent.width, y: 960 / image.extent.width))
    return CIContext().createCGImage(small.clampedToExtent().applyingGaussianBlur(sigma: 24), from: small.extent)
}

// In the open overview × in the top right corner of each Desktop removes it, and a larger + just below the last one
// adds a Desktop after it and slides there. Each is a window of nori's on that Desktop, so its Space's own transform
// carries and scales it. + is really at the bottom of the display and drawn further down by a window transform: past
// the display's edge the window would go over to the next display (docs/WINDOWSERVER.md). They fade in once the overview has settled and go as it closes. Only pictures: the event tap
// keeps clicks in the overview from reaching anything, and overviewClick goes by the rects. Needs Dock's code (Spaces.swift).
var closeButtons: [UInt64: NSWindow] = [:]
var addButton: (window: NSWindow, space: UInt64)?
let closeButtonSize: CGFloat = 28  // on screen in the overview, like the rest
let addButtonSize: CGFloat = 48
let addButtonOffset: CGFloat = 16  // below the Desktop
let spaceButtonInset: CGFloat = 12

func closeButtonRect(_ i: Int) -> CGRect {
    let picture = overviewRect(i)
    return CGRect(x: picture.maxX - spaceButtonInset - closeButtonSize, y: picture.minY + spaceButtonInset, width: closeButtonSize, height: closeButtonSize)
}

func addButtonRect(_ i: Int) -> CGRect {
    let picture = overviewRect(i)
    return CGRect(x: picture.midX - addButtonSize / 2, y: picture.maxY + addButtonOffset, width: addButtonSize, height: addButtonSize)
}

// On Space `sid`. The frame is in the Space's coordinates: scaled down with it, a button comes out at its size.
// below: how far under its frame it is drawn, in those coordinates.
func spaceButton(_ symbol: String, frame: NSRect, on sid: UInt64, below: CGFloat = 0) -> NSWindow {
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.level = .statusBar  // over the strip's windows, and not layer 0: no one lists it as an app window
    window.ignoresMouseEvents = true
    window.alphaValue = 0
    let view = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
    view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: frame.height * 0.42, weight: .semibold)
    view.contentTintColor = .white
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
    view.layer?.cornerRadius = frame.height / 2
    window.contentView = view
    window.orderFrontRegardless()
    fadeIn(window, on: sid, below: below)
    return window
}

// AppKit orders a window in a moment later and on the current Space, undoing a move and a transform made before that.
// It has no Space until then (docs/WINDOWSERVER.md).
func fadeIn(_ window: NSWindow, on sid: UInt64, below: CGFloat) {
    guard window.isVisible else { return }  // the overview closed meanwhile
    let wids = [window.windowNumber] as CFArray
    guard (CGSCopySpacesForWindows(cid, 7, wids)?.takeRetainedValue() as? [UInt64])?.isEmpty == false else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { fadeIn(window, on: sid, below: below) }
        return
    }
    _ = CGSSpaceAddWindowsAndRemoveFromSpaces(cid, sid, wids, 7)
    if below != 0 { send(["D \(window.windowNumber) 1 0 0 0 0 1 0 0 0 0 1 0 0 \(-below) 0 1"]) }
    window.animator().alphaValue = 1
}

func showSpaceButtons() {
    guard desktopsEditable, let screen = nsScreen(of: overviewDisplay) else { return }
    watchHover()
    let desktops = overviewSpaces.filter { !isFullscreen($0) }
    let removable = desktops.count > 1 ? desktops : []  // a display's last Desktop stays
    for sid in Array(closeButtons.keys) where !removable.contains(sid) { closeButtons.removeValue(forKey: sid)?.orderOut(nil) }
    let inset = spaceButtonInset / overviewScale, close = closeButtonSize / overviewScale, add = addButtonSize / overviewScale
    for sid in removable where closeButtons[sid] == nil {
        closeButtons[sid] = spaceButton("xmark", frame: NSRect(x: screen.frame.maxX - inset - close, y: screen.frame.maxY - inset - close, width: close, height: close), on: sid)
    }
    guard let last = desktops.last, addButton?.space != last else { return }
    addButton?.window.orderOut(nil)
    let window = spaceButton("plus", frame: NSRect(x: screen.frame.midX - add / 2, y: screen.frame.minY + inset, width: add, height: add), on: last, below: inset + add + addButtonOffset / overviewScale)
    addButton = (window, last)
}

// ponytail: a fixed wait for the overview's spring, as an open overview sends no "layout-done"; on a slow frame they
// come a little early, and they are on their Spaces anyway.
var spaceButtonsSoon: DispatchWorkItem?

func showSpaceButtonsSoon() {
    spaceButtonsSoon?.cancel()
    let work = DispatchWorkItem { if overviewOpen { showSpaceButtons() } }
    spaceButtonsSoon = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
}

func hideSpaceButtons() {
    stopWatchingHover()
    for window in closeButtons.values { window.orderOut(nil) }
    closeButtons = [:]
    addButton?.window.orderOut(nil)
    addButton = nil
}

func closeButtonSpace(at point: CGPoint) -> UInt64? {
    overviewSpaces.enumerated().first { closeButtons[$0.element] != nil && closeButtonRect($0.offset).contains(point) }?.element
}

func isOverAddButton(_ point: CGPoint) -> Bool {
    guard let sid = addButton?.space, let i = overviewSpaces.firstIndex(of: sid) else { return false }
    return addButtonRect(i).contains(point)
}

func pressSpaceButton(at point: CGPoint) -> Bool {
    if let sid = closeButtonSpace(at: point) {
        removeDesktop(sid)
        return true
    }
    guard isOverAddButton(point) else { return false }
    addDesktopInOverview()
    return true
}

// The pointer is a hand over a button. They are pictures, so this goes by the rects too. The app below sets its own
// cursor a moment after a move and on entering its views, so moves over a button don't reach it, and the hand is set
// again while the pointer stays. This tap is on only while the buttons are up: the main one would see every move, always.
// nori is a background app, and macOS ignores its cursor without the connection property.
@_silgen_name("CGSSetConnectionProperty") func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

var hoverTap: CFMachPort?
var handTimer: Timer?

func watchHover() {
    if hoverTap == nil {
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        hoverTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.mouseMoved.rawValue,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout && overviewOpen { watchHover() }
                return type == .mouseMoved && hover(at: event.location) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )
        if let hoverTap { CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, hoverTap, 0), .commonModes) }
    }
    if let hoverTap { CGEvent.tapEnable(tap: hoverTap, enable: true) }
}

func stopWatchingHover() {
    if let hoverTap { CGEvent.tapEnable(tap: hoverTap, enable: false) }
    showHand(false)
}

// Whether the point is over a button.
func hover(at point: CGPoint) -> Bool {
    let over = closeButtonSpace(at: point) != nil || isOverAddButton(point)
    showHand(over)
    return over
}

func showHand(_ show: Bool) {
    guard show != (handTimer != nil) else { return }
    handTimer?.invalidate()
    handTimer = show ? .scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in NSCursor.pointingHand.set() } : nil
    (show ? NSCursor.pointingHand : NSCursor.arrow).set()
}

func addDesktopInOverview() {
    let shown = overviewDisplay
    addDesktop(on: shown)
    whenSpaces(of: shown, differFrom: shown.spaces) { ids in
        overviewRefresh()
        guard overviewOpen, let new = ids.first(where: { !shown.spaces.contains($0) }), let index = overviewSpaces.firstIndex(of: new) else { return }
        overviewTarget = index
        sendLayout(open: true, spring: false)
        pressSpace(new)
    }
}

// The open overview after Desktops came or went.
func overviewRefresh() {
    guard overviewOpen else { return }
    let target = overviewSpaces[overviewTarget]
    useStack(on: displays.first { $0.id == overviewDisplay.id } ?? overviewDisplay)  // the target may be the Desktop that went
    if let index = overviewSpaces.firstIndex(of: target) { overviewTarget = index }
    sendLayout(open: true, spring: false)
}

// Where Space i sits in the open overview, in CG coordinates.
func overviewRect(_ i: Int) -> CGRect {
    let screen = overviewDisplay.frame
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
    let screen = overviewDisplay.frame, rect = overviewRect(i)
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
    send(["M \(drag.window) \(drag.origin.x + dx / overviewScale) \(drag.origin.y + dy / overviewScale)\(moveLimits(lastSeen[drag.window]?.frame.width ?? 0, on: overviewDisplay.frame))"])
}

func overviewMouseUp(at point: CGPoint) {
    defer { overviewDrag = nil }
    guard overviewOpen else { return }
    guard let drag = overviewDrag, drag.moved else { return overviewClick(at: point) }
    send(["M \(drag.window) \(drag.origin.x) \(drag.origin.y)\(moveLimits(lastSeen[drag.window]?.frame.width ?? 0, on: overviewDisplay.frame))"])  // back in its slot, or where it lands elsewhere
    guard let to = overviewIndex(at: point), to != drag.from, !isFullscreen(overviewSpaces[to]) else { return }
    let sid = overviewSpaces[to]
    movedAway.insert(drag.window)  // Move.swift: out of this strip until CGWindowList agrees
    send(["X \(drag.window) \(sid)"])
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { movedAway.remove(drag.window) }
}

func overviewClick(at point: CGPoint) {
    if pressSpaceButton(at: point) { return }
    guard let hit = overviewHit(at: point) else { return closeOverview(at: overviewTarget) }
    closeOverview(at: hit.space)
    guard let window = hit.window else { return }
    // Once Dock has switched (if it had to), the strip there is the current one: focus that window's column.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        _ = syncColumns()
        if let index = columns.firstIndex(of: window) { focusColumn(at: index) }
    }
}
