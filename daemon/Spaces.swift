// Option+J/K: Space below / above, like niri's workspace down / up. The daemon presses the system
// "Switch to Desktop N" shortcut (com.apple.symbolichotkeys 118 + N - 1), so the switch itself is Dock's.
// ponytail: main display only, Desktops 1…16 (the ones that have such a shortcut), no wrap-around.

import Cocoa

@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>

func switchSpace(by delta: Int) {
    let active = CGSGetActiveSpace(cid)
    // Desktops in Mission Control order; type 0 skips full-screen app Spaces, which have no Desktop number.
    let displays = CGSCopyManagedDisplaySpaces(cid).takeRetainedValue() as? [[String: Any]] ?? []
    let desktops = displays.lazy
        .map { ($0["Spaces"] as? [[String: Any]] ?? []).filter { $0["type"] as? Int == 0 }.compactMap { $0["ManagedSpaceID"] as? UInt64 } }
        .first { $0.contains(active) } ?? []
    guard let index = desktops.firstIndex(of: active), desktops.indices.contains(index + delta) else { return }
    let target = index + delta
    let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
    guard let entry = hotkeys?[String(118 + target)] as? [String: Any], entry["enabled"] as? Bool == true,
          let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int], params.count == 3
    else {
        fputs("Desktop \(target + 1): turn on \"Switch to Desktop \(target + 1)\" in System Settings → Keyboard → Shortcuts → Mission Control\n", stderr)
        return
    }
    // parameters: (character, keycode, modifier flags); the flags use the same bits as CGEventFlags.
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(params[1]), keyDown: down)
        event?.flags = CGEventFlags(rawValue: UInt64(params[2]))
        event?.post(tap: .cghidEventTap)
    }
}
