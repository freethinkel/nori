// Windows come from CGWindowList, moves go through the payload, resizes through Accessibility.

import Cocoa

typealias Win = (id: UInt32, pid: pid_t, frame: CGRect)
typealias Listed = (win: Win, spaces: [UInt64], info: [String: Any])

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace") func CGSGetActiveSpace(_ cid: Int32) -> UInt64
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?
let cid = CGSMainConnectionID()

// Windows from other apps that are on some Space, front to back, normal layer only, with their Spaces.
// Skips invisible and tiny helper windows, and apps with an ignore rule.
func listWindows(_ options: CGWindowListOption) -> [Listed] {
    let list = CGWindowListCopyWindowInfo(options.union(.excludeDesktopElements), kCGNullWindowID) as? [[String: Any]] ?? []
    let current = rules
    return list.compactMap { info in
        guard info[kCGWindowLayer as String] as? Int == 0,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let id = info[kCGWindowNumber as String] as? UInt32,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width >= 50, frame.height >= 50,
              let spaces = CGSCopySpacesForWindows(cid, 7, [id] as CFArray)?.takeRetainedValue() as? [UInt64],
              !spaces.isEmpty,
              rule(for: pid, in: current)?.ignore != true
        else { return nil }
        return ((id, pid, frame), spaces, info)
    }
}

// On-screen windows of one Space that belong in the strip: floating rules keep theirs out.
// The Space check matters during a Space switch, when both Spaces' windows are on screen.
func windows(on space: UInt64) -> [Win] {
    let current = rules
    return listWindows(.optionOnScreenOnly).filter { $0.spaces.contains(space) && rule(for: $0.win.pid, in: current)?.floating != true }.map(\.win)
}

// Resize goes through Accessibility: SLS in Dock can move a window, but an app only relayouts when it resizes itself.
@_silgen_name("_AXUIElementGetWindow")
func axWindowID(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

// Apps list only their windows of the current Space here.
func axElement(_ win: Win) -> AXUIElement? {
    let app = AXUIElementCreateApplication(win.pid)
    AXUIElementSetMessagingTimeout(app, 0.25)  // a hung app must not stall the daemon
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let axWindows = value as? [AXUIElement] else { return nil }
    return axWindows.first { element in
        var id: CGWindowID = 0
        return axWindowID(element, &id) == .success && id == win.id
    }
}

func setHeight(_ win: Win, _ height: CGFloat) {
    guard let element = axElement(win) else { return }
    var size = CGSize(width: win.frame.width, height: height)
    if let axSize = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axSize)
    }
}

// Raises this window, then activates its app: activating alone brings up the app's last used window instead.
func focus(_ win: Win) {
    if let element = axElement(win) { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
    NSRunningApplication(processIdentifier: win.pid)?.activate()
}

// Title without Screen Recording permission, which CGWindowList needs for kCGWindowName. Current Space only.
func axTitle(_ win: Win) -> String? {
    var value: CFTypeRef?
    guard let element = axElement(win),
          AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return nil }
    return value as? String
}
