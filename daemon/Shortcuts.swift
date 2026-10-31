// The system shortcuts nori presses to switch Spaces, since only Dock can: "Switch to Desktop N", and "Move left/right
// a space" for fullscreen Spaces. They are read from WindowServer, not the preferences: a new account has none of them
// there, and a change there means nothing until it is applied (docs/WINDOWSERVER.md). The menu lists the ones that are
// off; turning them on changes a system setting, so it is the user's call, asked once at launch.

import Cocoa

@_silgen_name("CGSIsSymbolicHotKeyEnabled") func CGSIsSymbolicHotKeyEnabled(_ id: Int32) -> Bool
@_silgen_name("CGSGetSymbolicHotKeyValue")
func CGSGetSymbolicHotKeyValue(_ id: Int32, _ character: UnsafeMutablePointer<UInt16>, _ keycode: UnsafeMutablePointer<UInt16>, _ flags: UnsafeMutablePointer<UInt32>) -> Int32

func symbolicHotkey(_ id: Int) -> SymbolicHotkey {
    var character: UInt16 = 0, keycode: UInt16 = 0, flags: UInt32 = 0
    guard CGSGetSymbolicHotKeyValue(Int32(id), &character, &keycode, &flags) == 0 else {
        return SymbolicHotkey(enabled: false, character: 65535, keycode: 65535, flags: 0)
    }
    return SymbolicHotkey(enabled: CGSIsSymbolicHotKeyEnabled(Int32(id)), character: Int(character), keycode: Int(keycode), flags: Int(flags))
}

func readDesktopHotkeys() -> [(chord: Chord, number: Int)] {
    (1...16).compactMap { number in
        let hotkey = symbolicHotkey(117 + number)
        guard hotkey.pressable else { return nil }
        return ((Int64(hotkey.keycode), CGEventFlags(rawValue: UInt64(hotkey.flags)).intersection(chordModifiers)), number)
    }
}

// The "Switch to Desktop N" shortcuts, kept fresh by checkShortcuts. A lock, as an event tap may read them off the main thread.
private let hotkeysLock = NSLock()
private var hotkeys = readDesktopHotkeys()
var desktopHotkeys: [(chord: Chord, number: Int)] {
    get { hotkeysLock.withLock { hotkeys } }
    set { hotkeysLock.withLock { hotkeys = newValue } }
}

// Puts what is off now on the problem list, and takes off what isn't. Returns the ids.
@discardableResult
func checkShortcuts() -> [Int] {
    desktopHotkeys = readDesktopHotkeys()
    let all = spaces()
    let off = shortcutsOff(desktops: all.filter { $0.number != nil }.count, spaces: all.count, hotkey: symbolicHotkey)
    let desktops = off.filter { $0 >= 118 }.map { String($0 - 117) }
    if desktops.isEmpty {
        clearProblem("desktop-shortcuts")
    } else {
        report(Problem(key: "desktop-shortcuts", title: "\"Switch to Desktop \(desktops.joined(separator: ", "))\" is off",
                       help: "nori can't switch to \(desktops.count == 1 ? "that Desktop" : "those Desktops"). Choose this to turn it on.",
                       fix: #selector(MenuActions.turnOnShortcuts)))
    }
    if off.contains(where: { $0 < 118 }) {
        report(Problem(key: "move-shortcuts", title: "\"Move left/right a space\" is off",
                       help: "nori reaches a fullscreen Space only if it holds its app's front window. Choose this to turn it on.",
                       fix: #selector(MenuActions.turnOnShortcuts)))
    } else {
        clearProblem("move-shortcuts")
    }
    return off
}

private let declinedKey = "declinedShortcuts"

// At launch. Declined once, the list keeps the offer and this stays quiet.
func offerShortcuts() {
    guard !checkShortcuts().isEmpty, !UserDefaults.standard.bool(forKey: declinedKey) else { return }
    let off = problems.filter { $0.fix == #selector(MenuActions.turnOnShortcuts) }.map(\.title).joined(separator: ", ")
    if alert("Turn on the Space shortcuts?",
             "nori switches Spaces by pressing macOS's own shortcuts, and these are off in System Settings: \(off). nori can turn them on, with the keys they already have.\n\nWithout them nori's keys, swipes and overview can't switch to those Spaces. You can turn them on later from nori's menu.",
             ["Turn On", "Not Now"]) == .alertFirstButtonReturn {
        enableShortcuts()
    } else {
        UserDefaults.standard.set(true, forKey: declinedKey)
    }
}

// The recipe from docs/WINDOWSERVER.md. A shortcut keeps its keys, the user's or macOS's default.
func enableShortcuts() {
    let off = checkShortcuts()
    guard !off.isEmpty else { return }
    _ = shell("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add"]
        + off.flatMap { [String($0), enabledPlist(symbolicHotkey($0))] })
    _ = shell("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
    UserDefaults.standard.removeObject(forKey: declinedKey)
    if !checkShortcuts().isEmpty {
        alert("Could not turn the shortcuts on", "Turn them on in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.", ["OK"])
    }
}

extension MenuActions {
    @objc func turnOnShortcuts() { enableShortcuts() }
}
