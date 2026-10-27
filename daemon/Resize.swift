// Option+= / Option+- (config: grow-width, shrink-width): the focused window gets wider / narrower by
// resize-step percent of the usable screen width. The payload ("R") animates the drawn width on vsync by stretching
// the window with a transform, on the same curve and in the same transaction as the neighbours' moves. The app is
// left alone meanwhile, so a slow app can't stall the motion: it gets its new size once, through Accessibility, when
// the presses stop and the stretch has settled. AX returns once the app has applied it; then "W" tells the payload
// the real width, and it drops the stretch.
// ponytail: content is stretched for the animation; a fixed delay stands in for "the payload says it settled".

import Cocoa

// Widths the apps were just given but CGWindowList doesn't show yet, so the layout already makes room for them.
var pendingWidths: [UInt32: CGFloat] = [:]

func withPendingWidths(_ wins: [Win]) -> [Win] {
    wins.map { win in
        guard let width = pendingWidths[win.id] else { return win }
        if abs(win.frame.width - width) < 1 { pendingWidths[win.id] = nil; return win }
        var win = win
        win.frame.size.width = width
        return win
    }
}

let axQueue = DispatchQueue(label: "nori.ax", qos: .userInteractive)
// The payload says when the stretch has settled ("resize-settled", Control.swift), and the app is resized then.
// The delay is a fallback for a payload that doesn't; a 300 pt stretch takes about 0.37 s at 60 Hz.
let resizeSettle = 0.8
var resizeWork: DispatchWorkItem?
var resizeWorkFor: (window: UInt32, width: CGFloat)?

// Main thread. Runs the pending AX resize once, whichever comes first: the payload's word or the fallback.
func runResize(_ work: DispatchWorkItem) {
    guard resizeWork === work else { return }
    resizeWork = nil
    resizeWorkFor = nil
    axQueue.async(execute: work)
}

func resizeSettled(_ window: UInt32, _ width: CGFloat) {
    guard let work = resizeWork, let pending = resizeWorkFor, pending.window == window, abs(pending.width - width) < 1 else { return }
    runResize(work)
}

var usableWidth: CGFloat { CGDisplayBounds(CGMainDisplayID()).width - paddingLeft - paddingRight }

func resizeFocused(by percent: CGFloat) {
    let wins = syncColumns().wins
    let index = focusedIndex()
    guard wins.indices.contains(index) else { return }
    let win = wins[index]  // its width already counts a resize still in flight, so presses add up
    resizeFocused(win, at: index, to: win.frame.width + usableWidth * percent / 100)
}

// The focused window (column `index`) eases to `width`; also driven by Option + right drag, see MouseDrag.swift.
func resizeFocused(_ win: Win, at index: Int, to width: CGFloat) {
    let width = min(max(width, 100), usableWidth)
    guard abs(width - win.frame.width) >= 1 else { return }
    pendingWidths[win.id] = width
    stripOffset = centers(of: syncColumns().wins)[index]
    send(["R \(win.id) \(width)"])  // before the layout, so its S for this window moves the resize's center
    layout(immediate: false)
    resizeWork?.cancel()  // repeated presses: the app relayouts once, after the last
    let work = DispatchWorkItem {
        guard let element = axElement(win) else { return }
        var size = CGSize(width: width, height: win.frame.height)
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        // The app may clamp the width (min/max size): aim the animation and the layout at what it took.
        var taken: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &taken) == .success, let taken {
            AXValueGetValue(taken as! AXValue, .cgSize, &size)
        }
        // Straight from here: every hop before the payload hears "W" is a frame drawn stretched twice.
        if abs(size.width - width) < 1 { send(["W \(win.id) \(size.width)"]); return }
        DispatchQueue.main.async {
            pendingWidths[win.id] = size.width
            send(["R \(win.id) \(size.width)", "W \(win.id) \(size.width)"])
            layout(immediate: false)
        }
    }
    resizeWork = work
    resizeWorkFor = (win.id, width)
    DispatchQueue.main.asyncAfter(deadline: .now() + resizeSettle) { runResize(work) }
}
