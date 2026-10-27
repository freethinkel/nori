// Overview, like niri's: every Space of the display, scaled down and stacked vertically, windows live.
// A plain Space switch is the same layout at scale 1: the Space at the center slides to the new one.
// The payload animates both on vsync (step_layout in payload.m); the daemon only says where to go with "Y".
// Dock still owns which Space is current: picking another Space presses its "Switch to Desktop N" shortcut
// (switchToSpace in Control.swift), and Dock's switch runs hidden under ours.
// ponytail: main display only; a click picks a Space, not a window. Scale and gap live in payload.m.

import Cocoa

let overviewScale: CGFloat = 0.4  // same as OVERVIEW_SCALE and OVERVIEW_GAP in payload.m, for hit testing
let overviewGap: CGFloat = 48

var overviewOpen = false
var overviewSpaces: [UInt64] = []  // desktops of the display, top to bottom
var overviewTarget = 0             // index of the Space at the center once the animation settles
var passDesktopHotkeys = 0  // our own presses of "Switch to Desktop N", let through to Dock

// The "Switch to Desktop N" shortcuts (symbolic hotkeys 118…133), read once at start.
let desktopHotkeys: [(chord: Chord, number: Int)] = {
    let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
    return (1...16).compactMap { number in
        guard let entry = hotkeys[String(117 + number)] as? [String: Any], entry["enabled"] as? Bool == true,
              let keys = (entry["value"] as? [String: Any])?["parameters"] as? [Int], keys.count == 3
        else { return nil }
        return ((Int64(keys[1]), CGEventFlags(rawValue: UInt64(keys[2])).intersection(chordModifiers)), number)
    }
}()

func desktopNumber(for event: CGEvent) -> Int? {
    desktopHotkeys.first { matches(event, $0.chord) }?.number
}

func pressDesktop(_ number: Int) {
    passDesktopHotkeys += 1
    if !switchToSpace(number) {
        passDesktopHotkeys -= 1
        fputs("\"Switch to Desktop \(number)\" shortcut is off; enable it in System Settings → Keyboard → Shortcuts → Mission Control\n", stderr)
    }
}

// Desktops (not full-screen Spaces) of the display that shows the active Space, in Mission Control order.
func desktopSpaces() -> (ids: [UInt64], current: Int) {
    let active = CGSGetActiveSpace(cid)
    let displays = CGSCopyManagedDisplaySpaces(cid).takeRetainedValue() as? [[String: Any]] ?? []
    for display in displays {
        let spaces = (display["Spaces"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? Int == 0 }
            .compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        if let current = spaces.firstIndex(of: active) { return (spaces, current) }
    }
    return ([active], 0)
}

// spring: the overview opening and closing; otherwise the windows' ease.
func sendLayout(open: Bool, spring: Bool) {
    send(["Y \(spring ? 1 : 0) \(overviewTarget) \(open ? 1 : 0) " + overviewSpaces.map(String.init).joined(separator: " ")])
}

// Every "Switch to Desktop N" press lands here (keys, Option+J/K, nori-msg), and Dock switches under our slide.
func switchSpaceAnimated(to number: Int) {
    guard let sid = spaces().first(where: { $0.number == number })?.id else { return }
    if overviewOpen {
        if let index = overviewSpaces.firstIndex(of: sid) { closeOverview(at: index) }
        return
    }
    let desktops = desktopSpaces()
    guard let index = desktops.ids.firstIndex(of: sid) else { pressDesktop(number); return }  // another display: Dock's slide
    guard sid != CGSGetActiveSpace(cid) || index != overviewTarget else { return }
    overviewSpaces = desktops.ids
    overviewTarget = index
    sendLayout(open: false, spring: false)
    pressDesktop(number)
}

func toggleOverview() {
    overviewOpen ? closeOverview(at: overviewTarget) : openOverview()
}

func openOverview() {
    let desktops = desktopSpaces()
    overviewSpaces = desktops.ids
    overviewTarget = desktops.current
    overviewOpen = true
    sendLayout(open: true, spring: true)
}

// Zooms into Space `index`, switching to it if it isn't the current one.
func closeOverview(at index: Int) {
    guard overviewOpen else { return }
    overviewOpen = false
    overviewTarget = index
    sendLayout(open: false, spring: true)
    let sid = overviewSpaces[index]
    if sid != CGSGetActiveSpace(cid), let number = spaces().first(where: { $0.id == sid })?.number { pressDesktop(number) }
}

// Quitting with the overview open would leave Spaces scaled in Dock; the payload finishes closing on its own.
func resetOverview() {
    guard overviewOpen else { return }
    overviewOpen = false
    overviewTarget = overviewSpaces.firstIndex(of: CGSGetActiveSpace(cid)) ?? overviewTarget
    sendLayout(open: false, spring: false)
}

// Where Space i sits in the open overview, in CG coordinates.
func overviewIndex(at point: CGPoint) -> Int? {
    let screen = CGDisplayBounds(CGMainDisplayID())
    let size = CGSize(width: screen.width * overviewScale, height: screen.height * overviewScale)
    return overviewSpaces.indices.first { i in
        let centerY = screen.midY + CGFloat(i - overviewTarget) * (size.height + overviewGap)
        return CGRect(x: screen.midX - size.width / 2, y: centerY - size.height / 2, width: size.width, height: size.height).contains(point)
    }
}
