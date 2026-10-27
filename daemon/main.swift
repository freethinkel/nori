// niri-mac daemon: niri-like scrolling columns for macOS. See README.md.
// Hotkeys and mouse-drag release come through the event tap here; the trackpad swipe is in Trackpad.swift.
// Option+1…5 switch Spaces through the system "Switch to Desktop N" shortcuts
// (com.apple.symbolichotkeys 118–122), not through this daemon.
// ponytail: polls the window list 4x/s; push window-created events from the payload (SLS notify in Dock) if latency matters.

import Cocoa

// Ctrl+Opt+Left / Right, Option+h/j/k/l. 3-finger scroll events are swallowed: the swipe is handled from raw touches.
let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.scrollWheel.rawValue | 1 << CGEventType.leftMouseUp.rawValue,
    callback: { _, type, event, _ in
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
        // Option + h/k = previous column, Option + l/j = next column (vim keys, keycodes from the US layout).
        switch key {
        case 4, 40: focusColumn(by: -1); return nil   // h, k
        case 37, 38: focusColumn(by: 1); return nil   // l, j
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
