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
let resizeSettle = 0.4  // seconds; a 300 pt stretch takes about 0.37 s at 60 Hz (a quarter of the rest per frame)
var resizeWork: DispatchWorkItem?

func resizeFocused(by percent: CGFloat) {
    let wins = syncColumns().wins
    let index = focusedIndex()
    guard wins.indices.contains(index) else { return }
    let win = wins[index]  // its width already counts a resize still in flight, so presses add up
    let usable = CGDisplayBounds(CGMainDisplayID()).width - paddingLeft - paddingRight
    let width = min(max(win.frame.width + usable * percent / 100, 100), usable)
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
        DispatchQueue.main.async {
            guard abs(size.width - width) >= 1 else { send(["W \(win.id) \(size.width)"]); return }
            pendingWidths[win.id] = size.width
            send(["R \(win.id) \(size.width)", "W \(win.id) \(size.width)"])
            layout(immediate: false)
        }
    }
    resizeWork = work
    axQueue.asyncAfter(deadline: .now() + resizeSettle, execute: work)
}
