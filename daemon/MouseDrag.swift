// Option + left drag moves a window, Option + right drag resizes it, like niri's Mod+LMB / Mod+RMB.
// Move: the window follows the pointer and trades places with a neighbour once it passes that neighbour's center;
// on release it eases into its column and takes focus. Resize: the window under the pointer takes focus and its width
// follows the pointer: both edges at once when it is centered, else the right one, as its left edge stays put
// (center-focused-column); the app resizes once the drag stops (Resize.swift).
// The clicks themselves don't reach the app. The modifier is `mouse-modifier` in the config, Option by default.
// ponytail: an own event tap, so main.swift's stays as it is.

import Cocoa

var drag: (id: UInt32, grab: CGPoint, origin: CGPoint, width: CGFloat)?
var dragging = false  // the tap's own: this press was a grab, so its drag and release are ours too

// Topmost strip window under the point. On-screen windows come front to back.
func stripWindow(at point: CGPoint) -> Win? {
    windows(on: CGSGetActiveSpace(cid)).first { $0.frame.contains(point) && columns.contains($0.id) }
}

// A press with the modifier. False, and it goes on to the app, when no strip window is under it.
func grab(_ type: CGEventType, at p: CGPoint) -> Bool {
    guard let win = stripWindow(at: p) else { return false }
    if type == .rightMouseDown, let i = columns.firstIndex(of: win.id) { focusColumn(at: i) } else { focus(win) }
    drag = (win.id, p, win.frame.origin, win.frame.width)
    return true
}

func startMouseDrag() {
    let events: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp]
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: events.reduce(0) { $0 | 1 << $1.rawValue },
        callback: { proxy, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = mouseTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let p = event.location
            switch type {
            case .leftMouseDown, .rightMouseDown:
                let state = tapState
                guard !state.overviewOpen, event.flags.intersection(chordModifiers) == state.mouseModifier,
                      DispatchQueue.main.sync(execute: { grab(type, at: p) }) else { return Unmanaged.passUnretained(event) }
                dragging = true
                return nil
            case .leftMouseDragged:
                guard dragging else { return Unmanaged.passUnretained(event) }
                onMainLatest(p) { p in if let d = drag { moveDragged(d, to: p) } }
                return nil
            case .rightMouseDragged:
                guard dragging else { return Unmanaged.passUnretained(event) }
                onMainLatest(p) { p in
                    guard let d = drag else { return }
                    let wins = syncColumns().wins
                    if let i = wins.firstIndex(where: { $0.id == d.id }) {
                        resizeFocused(wins[i], at: i, to: d.width + (scroll(wins).centering ? 2 : 1) * (p.x - d.grab.x))
                    }
                }
                return nil
            case .leftMouseUp, .rightMouseUp:
                guard dragging else { return Unmanaged.passUnretained(event) }
                dragging = false
                onMain {
                    guard let d = drag else { return }
                    drag = nil
                    if type == .leftMouseUp, let i = columns.firstIndex(of: d.id) { focusColumn(at: i) }
                }
                return nil
            default:
                return Unmanaged.passUnretained(event)
            }
        },
        userInfo: nil
    ) else {
        fputs("mouse tap failed: modifier + drag disabled\n", stderr)
        return
    }
    mouseTap = tap
    CGEvent.tapEnable(tap: tap, enable: true)
    runTap(tap)
}
var mouseTap: CFMachPort?

func moveDragged(_ d: (id: UInt32, grab: CGPoint, origin: CGPoint, width: CGFloat), to p: CGPoint) {
    let x = d.origin.x + p.x - d.grab.x, y = d.origin.y + p.y - d.grab.y
    // Past a neighbour's center: swap columns; the neighbour eases into the freed slot, the strip doesn't scroll.
    let wins = syncColumns().wins
    if let i = wins.firstIndex(where: { $0.id == d.id }) {
        let screen = CGDisplayBounds(CGMainDisplayID())
        let centerX = screen.minX + paddingLeft + (screen.width - paddingLeft - paddingRight) / 2
        let onScreen = { (k: Int) in centerX + columnCenters[k] - stripOffset }
        let center = x + wins[i].frame.width / 2
        let j = i > 0 && center < onScreen(i - 1) ? i - 1 : i + 1 < wins.count && center > onScreen(i + 1) ? i + 1 : i
        if j != i, columnCenters.indices.contains(max(i, j)) {
            columns.swapAt(i, j)
            layout(immediate: false)
        }
    }
    send(["M \(d.id) \(x) \(y)"])  // after the layout: M drops the ease its S just started for this window
}
