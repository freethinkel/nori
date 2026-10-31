// Option+J/K (config: focus-space-down, focus-space-up): Space below / above, like niri's workspace down / up.
// Fullscreen Spaces are in the stack where Mission Control has them. The switch itself is Dock's, see pressSpace.
// In the overview they move the centered Space instead, see below.
// ponytail: Desktops 1…16 (the ones that have such a shortcut).

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

// What a display shows. With "Displays have separate Spaces" off there is one entry, for the main display, whatever
// is connected: macOS keeps one list of Spaces, and calls it "Main" (not verified, that takes a logout).
struct Display {
    let id: CGDirectDisplayID
    let uuid: String
    let spaces: [UInt64]  // Desktops and fullscreen Spaces in Mission Control order: the stack the overview shows
    let current: UInt64   // the active Space, on the display that has focus
    var frame: CGRect { CGDisplayBounds(id) }
    var name: String? { nsScreen(of: self)?.localizedName }  // what [[monitor]] tables go by
}

let separateSpaces = NSScreen.screensHaveSeparateSpaces

// Main display first. Read again before each use that needs the current Spaces: macOS tells of no Space changing on a
// display without focus. Kept when macOS lists none, as it may in the middle of a change.
var displays = [Display(id: CGMainDisplayID(), uuid: "", spaces: [], current: 0)]

func refreshDisplays() {
    let active = CGSGetActiveSpace(cid)
    let list = CGSCopyManagedDisplaySpaces(cid).takeRetainedValue() as? [[String: Any]] ?? []
    let read = list.map { entry -> Display in
        let uuid = entry["Display Identifier"] as? String ?? ""
        // "Main" parses as a zero UUID, which gives display 1: no such display.
        let id = CFUUIDCreateFromString(nil, uuid as CFString).map { CGDisplayGetDisplayIDFromUUID($0) } ?? 0
        let spaces = (entry["Spaces"] as? [[String: Any]] ?? [])
            .filter { [0, 4].contains($0["type"] as? Int) }  // 0 desktop, 4 fullscreen
            .compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        let listed = ((entry["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? spaces.first ?? 0
        return Display(id: CGDisplayIsOnline(id) != 0 ? id : CGMainDisplayID(), uuid: uuid, spaces: spaces, current: spaces.contains(active) ? active : listed)
    }
    if !read.isEmpty { displays = read.filter { $0.id == CGMainDisplayID() } + read.filter { $0.id != CGMainDisplayID() } }
}

func display(of space: UInt64) -> Display { displays.first { $0.spaces.contains(space) } ?? displays[0] }

// The display that has focus, and the one under the pointer, as of now.
func focusedDisplay() -> Display {
    refreshDisplays()
    return display(of: CGSGetActiveSpace(cid))
}

func pointerDisplay() -> Display {
    refreshDisplays()
    return displays[displayIndex(at: CGEvent(source: nil)?.location ?? .zero, in: displays.map(\.frame)) ?? 0]
}

func nsScreen(of display: Display) -> NSScreen? {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id }
}

// Focus goes to a display: to the focused column of its strip, to its fullscreen app, or with no window there to the
// display itself, which pressing the shortcut of the Desktop it shows does.
func focusDisplay(_ target: Display) {
    let space = target.current
    if isFullscreen(space), let win = listWindows(.optionOnScreenOnly).first(where: { $0.spaces.contains(space) })?.win { return focus(win) }
    // ponytail: an empty Desktop can't take focus, nothing there can be key (docs/WINDOWSERVER.md). The display gets it
    // with the first window there, moved or opened.
    onStrip(space) { if !syncColumns().wins.isEmpty { focusColumn(at: focusedIndex()) } }
}

// The payload's table of displays ("B"), which it doesn't need with one.
func displayLines() -> [String] {
    refreshDisplays()
    return ["B"] + (displays.count > 1 ? displays.map { display in
        let frame = display.frame
        return "B \(frame.minX) \(frame.minY) \(frame.width) \(frame.height) \(display.uuid) " + display.spaces.map(String.init).joined(separator: " ")
    } : [])
}

// The stack a display's Spaces slide through, and the index of the one it shows.
func stack(on display: Display) -> (ids: [UInt64], current: Int) {
    display.spaces.isEmpty ? ([display.current], 0) : (display.spaces, display.spaces.firstIndex(of: display.current) ?? 0)
}

// Whether the payload found Dock's code for adding and removing Desktops. It tells at the start.
var desktopsEditable = false

func addDesktop(on display: Display) { send(["N \(display.id)"]) }

// Dock's list changes a moment after "N" and "C". Then gives the display's Spaces as they are.
func whenSpaces(of display: Display, differFrom ids: [UInt64], tries: Int = 40, then: @escaping ([UInt64]) -> Void) {
    refreshDisplays()
    let now = displays.first { $0.id == display.id }?.spaces ?? ids
    guard now == ids, tries > 0 else { return then(now) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { whenSpaces(of: display, differFrom: ids, tries: tries - 1, then: then) }
}

// Dock sends its windows to the display's first Desktop. It isn't removed while on screen: first the display goes to
// the Desktop before it, or after it if it is the first.
func removeDesktop(_ sid: UInt64) {
    refreshDisplays()
    let shown = display(of: sid), desktops = shown.spaces.filter { !isFullscreen($0) }
    guard desktops.count > 1, desktops.contains(sid) else { return }
    let remove = {
        send(["C \(sid)"])
        whenSpaces(of: shown, differFrom: shown.spaces) { _ in overviewRefresh() }
    }
    guard sid == shown.current else { return remove() }
    let other = desktops[desktops[0] == sid ? 1 : desktops.firstIndex(of: sid)! - 1]
    if overviewOpen, let index = overviewSpaces.firstIndex(of: other) {
        overviewTarget = index
        sendLayout(open: true, spring: false)
        pressSpace(other)
    } else {
        switchSpaceAnimated(to: other)
    }
    whenSpaceChanges(from: sid, then: remove)
}

// The Desktops of the display that has focus, fullscreen Spaces left out.
func desktopsHere() -> [(id: UInt64, number: Int?, displayNumber: Int?, display: String, fullscreen: Bool, visible: Bool)] {
    let all = spaces(), active = CGSGetActiveSpace(cid)
    guard let display = all.first(where: { $0.id == active })?.display else { return [] }
    return all.filter { $0.display == display && !$0.fullscreen }
}

// Desktop n of the display that has focus, as Mission Control labels it and like niri's workspaces, given as the number
// across displays that everything else goes by.
func desktopHere(_ n: Int) -> Int? {
    let desktops = desktopsHere()
    return desktops.indices.contains(n - 1) ? desktops[n - 1].number : nil
}

// The Desktop number `delta` Desktops below (+) or above (-) the current one on its display, for moving a window
// there; fullscreen Spaces don't count. Past either end: nil, or round to the other end with wrap-around.
func neighbourDesktop(_ delta: Int) -> Int? {
    let desktops = desktopsHere(), active = CGSGetActiveSpace(cid)
    guard let i = desktops.firstIndex(where: { $0.id == active }) else { return nil }
    let j = wrapAround ? (i + delta + desktops.count) % desktops.count : i + delta
    return desktops.indices.contains(j) ? desktops[j].number : nil
}

// The Space `delta` below (+) or above (-) the current one in the focused display's stack, fullscreen ones included.
// Past either end: nil, or round to the other end with wrap-around.
func neighbourSpace(_ delta: Int) -> UInt64? {
    let stack = stack(on: focusedDisplay())
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
    // Past the last Space of its display, focus goes on to the display on that side, if there is one.
    if let sid = neighbourSpace(delta) { switchSpaceAnimated(to: sid) } else { focusMonitor(delta > 0 ? "down" : "up") }
}
