// Windows come from CGWindowList, moves go through the payload, resizes through Accessibility.

import Cocoa

typealias Win = (id: UInt32, pid: pid_t, frame: CGRect)

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace") func CGSGetActiveSpace(_ cid: Int32) -> UInt64
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?
let cid = CGSMainConnectionID()

// Windows from other apps on the current Space, normal layer only. Skips invisible and tiny helper windows.
// The Space check matters during a Space switch, when both Spaces' windows are on screen.
func windows(on space: UInt64) -> [Win] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { info in
        guard info[kCGWindowLayer as String] as? Int == 0,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let id = info[kCGWindowNumber as String] as? UInt32,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width >= 50, frame.height >= 50,
              let spaces = CGSCopySpacesForWindows(cid, 7, [id] as CFArray)?.takeRetainedValue() as? [UInt64],
              spaces.contains(space)
        else { return nil }
        return (id, pid, frame)
    }
}

// Resize goes through Accessibility: SLS in Dock can move a window, but an app only relayouts when it resizes itself.
@_silgen_name("_AXUIElementGetWindow")
func axWindowID(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

func setHeight(_ win: Win, _ height: CGFloat) {
    let app = AXUIElementCreateApplication(win.pid)
    AXUIElementSetMessagingTimeout(app, 0.25)  // a hung app must not stall the daemon
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let axWindows = value as? [AXUIElement] else { return }
    for element in axWindows {
        var id: CGWindowID = 0
        guard axWindowID(element, &id) == .success, id == win.id else { continue }
        var size = CGSize(width: win.frame.width, height: height)
        if let axSize = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axSize)
        }
        return
    }
}
