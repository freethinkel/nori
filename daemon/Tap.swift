// Every key and click of the system waits for the event tap that sees it. On the main thread a tap let anything slow
// there hold up typing everywhere: 0.25 s per Accessibility call to a hung app, a Dock that doesn't take its socket.
// So each tap has a thread of its own. It decides what is nori's from the copy below and leaves the work to the main
// thread; only a press with mouse-modifier waits for it, as whether that is nori's depends on the window under it.

import Cocoa

// What the taps need of the main thread's state. Bindings and swipes come from the config, the rest as it changes.
struct TapState {
    var chords: [(chord: Chord, action: String)] = []
    var swipeFingers: Set<Int32> = []
    var mouseModifier: CGEventFlags = .maskAlternate
    var overviewOpen = false
    var recording = false       // a shortcut recorder in the Settings window waits for a key press
    var passDesktopHotkeys = 0  // our own presses of "Switch to Desktop N", let through to Dock
}

private let tapLock = NSLock()
private var state = TapState()
private var latestDrag: CGPoint?

var tapState: TapState {
    tapLock.lock()
    defer { tapLock.unlock() }
    return state
}

func updateTapState(_ change: (inout TapState) -> Void) {
    tapLock.lock()
    defer { tapLock.unlock() }
    change(&state)
}

func tapConfigChanged() {
    let chords = boundChords(), fingers = swipeFingers(), modifier = mouseModifier
    updateTapState {
        $0.chords = chords
        $0.swipeFingers = fingers
        $0.mouseModifier = modifier
    }
}

// True when this press is one of nori's own, and uses that pass up.
func takeDesktopPass() -> Bool {
    tapLock.lock()
    defer { tapLock.unlock() }
    guard state.passDesktopHotkeys > 0 else { return false }
    state.passDesktopHotkeys -= 1
    return true
}

func onMain(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }

// For a drag: a main thread that can't keep up skips points instead of working through a queue of them. What is queued
// runs before a later onMain, so the release comes after the drag's last point.
func onMainLatest(_ point: CGPoint, _ work: @escaping (CGPoint) -> Void) {
    tapLock.lock()
    let queued = latestDrag != nil
    latestDrag = point
    tapLock.unlock()
    guard !queued else { return }
    onMain {
        tapLock.lock()
        let latest = latestDrag
        latestDrag = nil
        tapLock.unlock()
        if let latest { work(latest) }
    }
}

func runTap(_ tap: CFMachPort) {
    let thread = Thread {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CFRunLoopRun()
    }
    thread.qualityOfService = .userInteractive
    thread.start()
}
