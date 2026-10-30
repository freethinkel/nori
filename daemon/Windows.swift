// Windows come from CGWindowList, moves go through the payload, resizes through Accessibility.

import Cocoa

typealias Win = (id: UInt32, pid: pid_t, frame: CGRect)
typealias Listed = (win: Win, spaces: [UInt64], info: [String: Any])

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace") func CGSGetActiveSpace(_ cid: Int32) -> UInt64
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?
let cid = CGSMainConnectionID()

// The rule for a window (Rules.swift). The title comes from CGWindowList where macOS gives it (Screen Recording), else
// from Accessibility, which reaches the current Space only.
// ponytail: a title rule costs an AX round trip per window of that app and poll; cache titles by id if that shows.
func rule(for listed: Listed, in rules: [Rule]) -> Rule? {
    ruleMatching(appNames(listed.win.pid), title: { listedTitle(listed) ?? axTitle(listed.win) }, in: rules)
}

func rule(for win: Win, in rules: [Rule]) -> Rule? {
    ruleMatching(appNames(win.pid), title: { axTitle(win) }, in: rules)
}

// Name and bundle id by pid, looked up once per app: every window goes through the rules on every poll.
// Dropped when the app quits (Events.swift), since macOS reuses pids.
var appNamesCache: [pid_t: [String]] = [:]

func appNames(_ pid: pid_t) -> [String] {
    if let names = appNamesCache[pid] { return names }
    guard let app = NSRunningApplication(processIdentifier: pid) else { return [] }
    let names = [app.localizedName, app.bundleIdentifier].compactMap { $0 }
    if !names.isEmpty { appNamesCache[pid] = names }
    return names
}

func listedTitle(_ listed: Listed) -> String? {
    (listed.info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
}

// Windows from other apps that are on some Space, front to back, normal layer only, with their Spaces.
// Skips invisible and tiny helper windows, and windows with an ignore rule.
func listWindows(_ options: CGWindowListOption) -> [Listed] {
    let list = CGWindowListCopyWindowInfo(options.union(.excludeDesktopElements), kCGNullWindowID) as? [[String: Any]] ?? []
    let current = rules
    return list.compactMap { info in
        guard info[kCGWindowLayer as String] as? Int == 0,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let id = info[kCGWindowNumber as String] as? UInt32,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),  // the Settings window
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width >= 50, frame.height >= 50,
              let spaces = CGSCopySpacesForWindows(cid, 7, [id] as CFArray)?.takeRetainedValue() as? [UInt64],
              !spaces.isEmpty
        else { return nil }
        let listed: Listed = ((id, pid, frame), spaces, info)
        return rule(for: listed, in: current)?.ignore == true ? nil : listed
    }
}

// On-screen windows of one Space that belong in the strip: floating rules and non-standard windows keep theirs out.
// The Space check matters during a Space switch, when both Spaces' windows are on screen.
// A fullscreen Space has no strip: its window already fills the screen, and laid out as a column it slid down below
// padding-top and was resized to the strip's height.
func windows(on space: UInt64) -> [Win] {
    guard !isFullscreen(space) else { return [] }
    let current = rules
    return listWindows(.optionOnScreenOnly)
        .filter { $0.spaces.contains(space) && floatingByHand[$0.win.id] == nil && rule(for: $0, in: current)?.floating != true && isStandard($0.win) }
        .map(\.win)
}

// Only an app's standard windows go in the strip, as in OmniWM: dialogs, floating panels, and what isn't among the
// app's windows at all (sheets, browser popups and bubbles, permission prompts) stay where the app puts them.
// Asked once per window. An app that doesn't answer keeps its windows in, so a hung app doesn't lose its columns.
// ponytail: the cache keeps one entry per window ever seen; prune by the live list if that ever shows.
private var standardWindows: [UInt32: Bool] = [:]

func isStandard(_ win: Win) -> Bool {
    if let known = standardWindows[win.id] { return known }
    guard let axWindows = axWindows(win.pid) else { return true }
    guard let element = axWindows.first(where: { axID($0) == win.id }) else { return false }  // asked again while it lasts
    var subrole: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success else { return true }
    let standard = [kAXStandardWindowSubrole, "AXFullScreenWindow"].contains(subrole as? String)
    standardWindows[win.id] = standard
    return standard
}

// Resize goes through Accessibility: SLS in Dock can move a window, but an app only relayouts when it resizes itself.
@_silgen_name("_AXUIElementGetWindow")
func axWindowID(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

// Apps list only their windows of the current Space here, and no sheets or child windows.
func axWindows(_ pid: pid_t) -> [AXUIElement]? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)  // a hung app must not stall the daemon
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return nil }
    return value as? [AXUIElement]
}

func axID(_ element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    return axWindowID(element, &id) == .success ? id : nil
}

func axElement(_ win: Win) -> AXUIElement? { axWindows(win.pid)?.first { axID($0) == win.id } }

// Position first: macOS stops a growing window at the bottom of the screen, going by where the app thinks the window
// is, and the payload's moves don't tell it. Position again last: an app may keep a window on screen by moving it as it grows.
// Returns the size the app took (it may clamp), or nil if it didn't answer.
@discardableResult
func setFrame(_ win: Win, _ frame: CGRect) -> CGSize? {
    guard let element = axElement(win) else { return nil }
    var size = frame.size, origin = frame.origin
    guard let position = AXValueCreate(.cgPoint, &origin), let axSize = AXValueCreate(.cgSize, &size) else { return nil }
    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axSize)
    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
    var taken: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &taken) == .success, let taken,
          AXValueGetValue(taken as! AXValue, .cgSize, &size) else { return nil }
    return size
}

// Raises this window, then activates its app: activating alone brings up the app's last used window instead.
func focus(_ win: Win) {
    if let element = axElement(win) { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
    NSRunningApplication(processIdentifier: win.pid)?.activate()
}

// Brings the app of a window on another Space to the front with all its windows, and Dock switches to the Space of
// the app's front window: pressSpace's way to a fullscreen Space when "Move left/right a space" is off.
// NSRunningApplication.activate() doesn't switch Spaces (macOS 27: the app came to the front, the Space stayed), and
// does nothing when the app is frontmost already; _SLPSSetFrontProcessWithOptions(psn, 0, kCPSAllWindows) switched
// every time. But to the app's front window: one with a window on a Desktop too (Finder) may go there instead.
// Raising the window first doesn't help: Accessibility lists only the current Space's windows, and the remote-token
// search (AltTab's) found the window in 2 of 6 tries; ordering it front from Dock or making it key changed nothing.
func bringAppFront(_ win: Win) {
    var psn = ProcessSerialNumber()
    guard let setFront = SkyLight.setFrontProcess, GetProcessForPID(win.pid, &psn) == noErr else { return focus(win) }
    _ = setFront(&psn, 0, 0x100)  // 0x100: kCPSAllWindows
    makeKey(win, &psn)
}

@_silgen_name("GetProcessForPID") func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

// SkyLight's process calls, looked up at run time: the daemon doesn't link SkyLight, AppKit has it loaded.
enum SkyLight {
    typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    typealias PostEvent = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    static let setFrontProcess = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_SLPSSetFrontProcessWithOptions")
        .map { unsafeBitCast($0, to: SetFront.self) }  // -2: RTLD_DEFAULT
    static let postEventRecord = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLPSPostEventRecordTo")
        .map { unsafeBitCast($0, to: PostEvent.self) }
}

// The event records that make a window its app's key window (as yabai and AltTab send them).
private func makeKey(_ win: Win, _ psn: inout ProcessSerialNumber) {
    guard let post = SkyLight.postEventRecord else { return }
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    withUnsafeBytes(of: win.id) { for i in 0..<4 { bytes[0x3c + i] = $0[i] } }
    for i in 0x20..<0x30 { bytes[i] = 0xff }
    for kind: UInt8 in [1, 2] {
        bytes[0x08] = kind
        _ = post(&psn, &bytes)
    }
}

// Every window of the current Space outside the strip (floating rules, dialogs, panels, PiP) above the strip's, in the
// order they had among themselves. Through the payload: Dock may order any app's window, and focus stays put.
func showFloating() {
    let space = CGSGetActiveSpace(cid)
    let floating = listWindows(.optionOnScreenOnly).filter { $0.spaces.contains(space) && !columns.contains($0.win.id) }
    send(floating.reversed().map { "O \($0.win.id) 1 0" })  // back to front, each above all: the frontmost ends on top
}

// Title without Screen Recording permission, which CGWindowList needs for kCGWindowName. Current Space only.
func axTitle(_ win: Win) -> String? {
    var value: CFTypeRef?
    guard let element = axElement(win),
          AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return nil }
    return value as? String
}

// The focused window of the frontmost app. A non-activating panel (Raycast, Spotlight) leaves it as it was.
func focusedWindowID() -> UInt32? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return axID(value as! AXUIElement)
}
