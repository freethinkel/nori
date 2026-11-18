// nori daemon: niri-like scrolling columns for macOS. See README.md.
// Hotkeys and mouse-drag release come through the event tap here; the trackpad swipe is in Trackpad.swift.
// Option+1…5 are the system "Switch to Desktop N" shortcuts (com.apple.symbolichotkeys 118–122); the tap catches them
// (and any other press of them) to slide Spaces itself, see switchSpaceAnimated. Every other key is a [bindings] action, Actions.swift.
// Window events come from WindowServer and Accessibility observers (Events.swift); a poll once a second catches what they miss.

import Cocoa

if let args = clientArgs(CommandLine.arguments) { runClient(args) }  // nori query …, see Control.swift
atexit(restoreSystemGesturesOnExit)
startApp()  // menu bar item, SIP check, Accessibility, payload: see App.swift

var swallowMouseUp = false  // a press that began in the overview: its drag and release are the overview's too
var mainTap: CFMachPort?

// Mouse buttons whose press went to a binding, so their release is swallowed too. The tap's thread only.
var swallowedButtons = Set<Int64>()

// Key and mouse button bindings. A bound button's press and release don't reach the app. 3-finger scroll events are swallowed: the swipe is handled from raw touches.
// While the overview is open, clicks pick a Space and Escape closes it; the clicks don't reach apps. Keys: see below.
// The callback runs on the tap's own thread, Tap.swift: it decides from tapState and leaves the work to the main thread.
let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.scrollWheel.rawValue
        | 1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue
        | 1 << CGEventType.leftMouseDragged.rawValue
        | 1 << CGEventType.otherMouseDown.rawValue | 1 << CGEventType.otherMouseUp.rawValue
        | 1 << 29 | 1 << 30 | 1 << 31,  // gesture, magnify and swipe (NSEventTypeGesture, Magnify, Swipe)
    callback: { _, type, event, _ in
        // macOS turns a tap off when a callback runs late (or for secure input); off, macOS gestures fight ours.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let mainTap { CGEvent.tapEnable(tap: mainTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let state = tapState
        if type.rawValue == 29 || type.rawValue == 30 || type.rawValue == 31 {
            // Three and four fingers are ours (strip, Spaces, overview): keep Mission Control and friends from seeing them.
            // A swipe arrives after the fingers lift, when the raw count is already 0, so the latch counts too.
            return swallowSystemGesture(state.swipeFingers) ? nil : Unmanaged.passUnretained(event)
        }
        let point = event.location
        if state.overviewOpen && type == .leftMouseDown {
            onMain { overviewMouseDown(at: point) }
            swallowMouseUp = true
            return nil
        }
        if type == .leftMouseDragged {
            guard swallowMouseUp else { return Unmanaged.passUnretained(event) }
            onMainLatest(point, overviewMouseDragged)
            return nil
        }
        if type == .leftMouseUp && swallowMouseUp {
            swallowMouseUp = false
            onMain { overviewMouseUp(at: point) }
            return nil
        }
        if type == .otherMouseUp {  // the release of a press that went to a binding goes nowhere either
            return swallowedButtons.remove(event.getIntegerValueField(.mouseEventButtonNumber)) == nil ? Unmanaged.passUnretained(event) : nil
        }
        if type == .keyDown && state.recording || type == .otherMouseDown && state.recording {  // the Settings window's shortcut recorder takes the press
            if let press = event.copy() { onMain { settingsModel.record(press) } }
            if type == .otherMouseDown { swallowedButtons.insert(event.getIntegerValueField(.mouseEventButtonNumber)) }
            return nil
        }
        if type == .keyDown, let number = desktopNumber(for: event) {
            if takeDesktopPass() { return Unmanaged.passUnretained(event) }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onMain { switchSpaceAnimated(toDesktop: number) } }
            return nil
        }
        if type == .keyDown || type == .otherMouseDown, let name = boundAction(event, in: state.chords) {  // [bindings] → Actions.swift
            if type == .otherMouseDown { swallowedButtons.insert(event.getIntegerValueField(.mouseEventButtonNumber)) }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 || !noRepeat.contains(name) { onMain { actions[name]?() } }
            return nil
        }
        if type == .keyDown && state.overviewOpen && event.getIntegerValueField(.keyboardEventKeycode) == 53 {  // Escape
            onMain { closeOverview(at: overviewTarget) }
            return nil
        }
        // Overview, plain keys like niri's: H/L or ←/→ move through the centered Space's columns (live in its
        // picture), J/K or ↓/↑ bring the Space below / above to the center, Return picks it. Other keys reach the app.
        if type == .keyDown && state.overviewOpen && event.flags.intersection(chordModifiers).isEmpty {
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 4, 123: onMain { focusColumn(by: -1) }; return nil   // h, ←
            case 37, 124: onMain { focusColumn(by: 1) }; return nil   // l, →
            case 38, 125: onMain { switchSpace(by: 1) }; return nil   // j, ↓
            case 40, 126: onMain { switchSpace(by: -1) }; return nil  // k, ↑
            case 36, 76: onMain { closeOverview(at: overviewTarget) }; return nil  // Return, keypad Enter
            default: break
            }
        }
        if type == .leftMouseDown { return Unmanaged.passUnretained(event) }
        if type == .leftMouseUp {
            // A drag may have ended: send every window back to its slot. The payload eases from where it was dropped.
            // The short delay lets apps that move their own window (Electron, Chrome) apply their last move first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { settleDrop() }
            return Unmanaged.passUnretained(event)
        }
        if type == .scrollWheel {
            // Three fingers scroll the strip, four drive the overview; two-finger scrolling stays the app's.
            return swallowSystemGesture(state.swipeFingers) ? nil : Unmanaged.passUnretained(event)
        }
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
)

guard let tap = tap else {
    restoreSystemGestures()
    fputs("event tap failed: grant Accessibility to this binary\n", stderr)
    exit(1)
}
mainTap = tap
tapConfigChanged()
CGEvent.tapEnable(tap: tap, enable: true)
runTap(tap)
// Secure input turns the tap off, and the gesture that arrives while it is off goes to Mission Control. Retry, since
// the disable event itself is only delivered with the next event.
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
}
// A peer gone mid-write (Dock restarting under the payload socket, a subscriber) must not kill the daemon: EPIPE instead.
signal(SIGPIPE, SIG_IGN)
// The payload turns its Space hooks off once this pid is gone. Repeated so a restarted Dock learns it too.
tellPayload()
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in tellPayload() }
// Ctrl+C / kill: put Spaces and windows back before quitting. A crash leaves the overview scaled until Dock restarts.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let quitSources = [SIGINT, SIGTERM].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { resetOverview(); restoreWindows(); restoreSystemGestures(); exit(0) }
    source.resume()
    return source
}
startControl()
startMultitouch()
startMouseDrag()
watchPointer()
startAnalytics()
loadStrips()
layoutAll()
// New window: scroll to it. Window focused by click or Cmd+Tab: scroll to it. Closed window: close the gap.
// Runs on every app / window / Space event (Events.swift), and once a second for whatever those miss.
var lastFront: UInt32?
func poll() {
    defer { publishSoon() }  // subscribers, Control.swift: a Space switch or a window on another Space counts too
    dropClosedBorders()
    guard !gestureActive, !spaceLayoutBusy else { return }
    pollDisplays()
    let before = columns
    let sync = syncColumns()
    defer { lastFront = sync.front }
    // Focus that came without a focusColumn: the focused window of the Space just switched to, an app brought back.
    if sync.front != lastFront, let index = sync.wins.firstIndex(where: { $0.id == sync.front }), index == focusedIndex() { warpMouse(to: sync.wins, index) }
    if let index = sync.inserted {
        focusColumn(at: index)
    } else if sync.front != lastFront, let front = sync.front,
              let index = columns.firstIndex(of: front), index != focusedIndex() {
        focusColumn(at: index)
    } else if columns != before {
        layout(immediate: false)
    }
}
startEvents()
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in poll() }
NSApp.run()
