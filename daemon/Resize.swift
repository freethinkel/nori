// Option+= / Option+- (config: grow-width, shrink-width): the focused window gets wider / narrower by
// resize-step percent of the usable screen width. The width eases over a few frames: each frame sets the size
// through Accessibility and re-centers the strip, so the neighbours slide along.
// ponytail: a 60 Hz main-thread timer driving AX; an app that relayouts slowly steps instead of gliding.

import Cocoa

let resizeDuration = 0.2  // seconds
var resizeTimer: Timer?
var resizeTarget: (id: UInt32, width: CGFloat)?  // repeated presses during an animation add up

func resizeFocused(by percent: CGFloat) {
    let wins = syncColumns().wins
    let index = focusedIndex()
    guard wins.indices.contains(index), let element = axElement(wins[index]) else { return }
    let win = wins[index]
    let usable = CGDisplayBounds(CGMainDisplayID()).width - paddingLeft - paddingRight
    let base = resizeTarget?.id == win.id ? resizeTarget!.width : win.frame.width
    let target = min(max(base + usable * percent / 100, 100), usable)
    resizeTarget = (win.id, target)
    let from = win.frame.width, height = win.frame.height
    let start = ProcessInfo.processInfo.systemUptime
    resizeTimer?.invalidate()
    resizeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
        let t = min(1, (ProcessInfo.processInfo.systemUptime - start) / resizeDuration)
        let eased = 1 - pow(1 - t, 3)  // ease-out cubic
        var size = CGSize(width: from + (target - from) * eased, height: height)
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
        // AX grows the window to the right; keep its center on the screen center instead.
        let now = syncColumns().wins
        if let i = now.firstIndex(where: { $0.id == win.id }) { stripOffset = centers(of: now)[i] }
        layout(immediate: t < 1)
        if t >= 1 {
            timer.invalidate()
            resizeTimer = nil
            resizeTarget = nil  // the next press starts from the real width, which the app may have clamped
        }
    }
}
