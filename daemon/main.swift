// nori daemon: niri-like scrolling columns for macOS. See README.md.
// Hotkeys and mouse-drag release come through the event tap here; the trackpad swipe is in Trackpad.swift.
// Option+1…5 are the system "Switch to Desktop N" shortcuts (com.apple.symbolichotkeys 118–122); the tap catches them
// (and any other press of them) to slide Spaces itself, see switchSpaceAnimated. Option+O (config: overview) opens the overview.
// ponytail: polls the window list 4x/s; push window-created events from the payload (SLS notify in Dock) if latency matters.

import Cocoa

var swallowMouseUp = false  // the click that closed the overview

// Ctrl+Opt+Left / Right, Option+h/j/k/l, the overview binding. 3-finger scroll events are swallowed: the swipe is handled from raw touches.
// While the overview is open, clicks pick a Space and Escape closes it; the clicks don't reach apps.
let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.scrollWheel.rawValue
        | 1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue,
    callback: { _, type, event, _ in
        if overviewOpen && type == .leftMouseDown {
            closeOverview(at: overviewIndex(at: event.location) ?? overviewTarget)
            swallowMouseUp = true
            return nil
        }
        if type == .leftMouseUp && swallowMouseUp {
            swallowMouseUp = false
            return nil
        }
        if type == .keyDown, let number = desktopNumber(for: event) {
            if passDesktopHotkeys > 0 {
                passDesktopHotkeys -= 1
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { switchSpaceAnimated(to: number) }
            return nil
        }
        if type == .keyDown && matches(event, overviewChord) {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { toggleOverview() }
            return nil
        }
        if type == .keyDown && matches(event, growChord) { resizeFocused(by: resizeStep); return nil }
        if type == .keyDown && matches(event, shrinkChord) { resizeFocused(by: -resizeStep); return nil }
        if type == .keyDown && overviewOpen && event.getIntegerValueField(.keyboardEventKeycode) == 53 {  // Escape
            closeOverview(at: overviewTarget)
            return nil
        }
        if type == .leftMouseDown { return Unmanaged.passUnretained(event) }
        if type == .leftMouseUp {
            // A drag may have ended: send every window back to its slot. The payload eases from where it was dropped.
            // The short delay lets apps that move their own window (Electron, Chrome) apply their last move first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { layout(immediate: false) }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        if type == .scrollWheel {
            return fingerCount == gestureFingers ? nil : Unmanaged.passUnretained(event)
        }
        guard flags.contains(.maskAlternate) else { return Unmanaged.passUnretained(event) }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if flags.contains(.maskControl) {
            switch key {
            case 123: focusColumn(by: -1); return nil  // left
            case 124: focusColumn(by: 1); return nil   // right
            default: break
            }
        }
        // Option + h/l = previous / next column, Option + j/k = Space below / above (vim keys, keycodes from the US layout).
        switch key {
        case 4: focusColumn(by: -1); return nil   // h
        case 37: focusColumn(by: 1); return nil   // l
        case 38: switchSpace(by: 1); return nil   // j
        case 40: switchSpace(by: -1); return nil  // k
        default: return Unmanaged.passUnretained(event)
        }
    },
    userInfo: nil
)

guard let tap = tap else {
    fputs("event tap failed: grant Accessibility to this binary\n", stderr)
    exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
// The payload turns its Space hooks off once this pid is gone. Repeated so a restarted Dock learns it too.
send(["P \(getpid())"])
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in send(["P \(getpid())"]) }
// Ctrl+C / kill: put Spaces back before quitting. A crash leaves the overview scaled until Dock restarts.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let quitSources = [SIGINT, SIGTERM].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { resetOverview(); exit(0) }
    source.resume()
    return source
}
startControl()
startMultitouch()
layout(immediate: false)
// New window: scroll to it. Window focused by click or Cmd+Tab: scroll to it. Closed window: close the gap.
// ponytail: focus changes are seen by the same 4x/s poll; observe NSWorkspace activation if that feels slow.
var lastFront: UInt32?
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    guard !gestureActive else { return }
    let before = columns
    let sync = syncColumns()
    defer { lastFront = sync.front }
    if let index = sync.inserted {
        focusColumn(at: index)
    } else if sync.front != lastFront, let front = sync.front,
              let index = columns.firstIndex(of: front), index != focusedIndex() {
        focusColumn(at: index)
    } else if columns != before {
        layout(immediate: false)
    }
}
CFRunLoopRun()
