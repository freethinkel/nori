// Option+J/K (config: focus-space-down, focus-space-up): Space below / above, like niri's workspace down / up.
// Fullscreen Spaces are in the stack where Mission Control has them. The switch itself is Dock's, see pressSpace.
// In the overview they move the centered Space instead, see below.
// ponytail: main display only, Desktops 1…16 (the ones that have such a shortcut).

import Cocoa

@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>

// Fullscreen Spaces (an app's native fullscreen or Split View) belong to the app: no strip there (windows(on:)), and
// no window moved there. A Space keeps its type for life, so each is looked up once.
private var fullscreenSpaces: [UInt64: Bool] = [:]

func isFullscreen(_ space: UInt64) -> Bool {
    if let known = fullscreenSpaces[space] { return known }
    let displays = CGSCopyManagedDisplaySpaces(cid).takeRetainedValue() as? [[String: Any]] ?? []
    for listed in displays.flatMap({ $0["Spaces"] as? [[String: Any]] ?? [] }) {
        if let id = (listed["id64"] as? NSNumber)?.uint64Value { fullscreenSpaces[id] = listed["type"] as? Int == 4 }
    }
    return fullscreenSpaces[space] ?? false  // not listed (yet): asked again next time
}

// The Desktop number `delta` Desktops below (+) or above (-) the current one on its display, for moving a window
// there; fullscreen Spaces don't count. Past either end: nil, or round to the other end with wrap-around.
func neighbourDesktop(_ delta: Int) -> Int? {
    let all = spaces(), active = CGSGetActiveSpace(cid)
    guard let display = all.first(where: { $0.id == active })?.display else { return nil }
    let desktops = all.filter { $0.display == display && !$0.fullscreen }
    guard let i = desktops.firstIndex(where: { $0.id == active }) else { return nil }
    let j = wrapAround ? (i + delta + desktops.count) % desktops.count : i + delta
    return desktops.indices.contains(j) ? desktops[j].number : nil
}

// The Space `delta` below (+) or above (-) the current one in the display's stack (displaySpaces), fullscreen ones
// included. Past either end: nil, or round to the other end with wrap-around.
func neighbourSpace(_ delta: Int) -> UInt64? {
    let stack = displaySpaces()
    let j = wrapAround ? (stack.current + delta + stack.ids.count) % stack.ids.count : stack.current + delta
    return stack.ids.indices.contains(j) ? stack.ids[j] : nil
}

func switchSpace(by delta: Int) {
    // Overview open: the neighbour slides to the center and becomes the current Space; the overview stays open.
    if overviewOpen {
        let target = overviewTarget + delta
        guard overviewSpaces.indices.contains(target) else { return }
        overviewTarget = target
        sendLayout(open: true, spring: false)
        pressSpace(overviewSpaces[target])
        return
    }
    if let sid = neighbourSpace(delta) { switchSpaceAnimated(to: sid) }
}
