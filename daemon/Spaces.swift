// Option+J/K (config: focus-space-down, focus-space-up): Space below / above, like niri's workspace down / up. The daemon
// presses the system "Switch to Desktop N" shortcut (com.apple.symbolichotkeys 118 + N - 1), so the switch itself is Dock's.
// In the overview they move the centered Space instead, see below.
// ponytail: main display only, Desktops 1…16 (the ones that have such a shortcut).

import Cocoa

@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>

// The Desktop number `delta` Desktops below (+) or above (-) the current one on its display; fullscreen Spaces don't
// count. Past either end: nil, or round to the other end with wrap-around.
func neighbourDesktop(_ delta: Int) -> Int? {
    let all = spaces(), active = CGSGetActiveSpace(cid)
    guard let display = all.first(where: { $0.id == active })?.display else { return nil }
    let desktops = all.filter { $0.display == display && !$0.fullscreen }
    guard let i = desktops.firstIndex(where: { $0.id == active }) else { return nil }
    let j = wrapAround ? (i + delta + desktops.count) % desktops.count : i + delta
    return desktops.indices.contains(j) ? desktops[j].number : nil
}

func switchSpace(by delta: Int) {
    // Overview open: the neighbour slides to the center and becomes the current Space; the overview stays open.
    if overviewOpen {
        let target = overviewTarget + delta
        guard overviewSpaces.indices.contains(target) else { return }
        overviewTarget = target
        sendLayout(open: true, spring: false)
        if let number = spaces().first(where: { $0.id == overviewSpaces[target] })?.number { pressDesktop(number) }
        return
    }
    guard let number = neighbourDesktop(delta), !switchToSpace(number) else { return }
    fputs("Desktop \(number): turn on \"Switch to Desktop \(number)\" in System Settings → Keyboard → Shortcuts → Mission Control\n", stderr)
}
