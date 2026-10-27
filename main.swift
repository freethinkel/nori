// niri-mac daemon. Lays out on-screen windows as horizontal columns and sends moves to payload.dylib in Dock.
// 3-finger horizontal trackpad swipe scrolls the strip under the fingers and snaps to a column on lift.
// It reads raw touches, so it works with the macOS 3-finger vertical gestures (Mission Control) on.
// A window dragged by the mouse eases back to its column on release.
// Ctrl+Opt+Left/Right, Option+h/l (j/k too) move focus one column.
// New windows are picked up by polling and open right of the focused column, like niri. Closed ones drop out.
// The focused column is centered on screen; focusing a window (click, Cmd+Tab) scrolls the strip to it.
// Gaps and screen padding come from ~/.config/niri-mac/config, read once at start.
// Every macOS Space has its own strip. Option+1…5 switch Spaces through the system "Switch to Desktop N" shortcuts
// (com.apple.symbolichotkeys 118–122), not through this daemon.
// ponytail: one window per column, no column resize.
// ponytail: polls the window list 4x/s; push window-created events from the payload (SLS notify in Dock) if latency matters.
// Windows come from CGWindowList, moves go through the payload. Accessibility is for the event tap and for resizing:
// windows are stretched to the full screen height once, when they join the strip.

import Cocoa
import Darwin

let socketPath = "/tmp/niri-mac_\(ProcessInfo.processInfo.environment["USER"] ?? "user").socket"

// "key = value" lines, # starts a comment. Missing file or key: 0.
// ponytail: no live reload, restart to apply.
let configKeys = ["gap", "padding-top", "padding-bottom", "padding-left", "padding-right"]
let config: [String: CGFloat] = {
    let path = NSHomeDirectory() + "/.config/niri-mac/config"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var result: [String: CGFloat] = [:]
    for line in text.split(separator: "\n") {
        let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard !body.allSatisfy(\.isWhitespace) else { continue }
        let parts = body.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, configKeys.contains(parts[0]), let value = Double(parts[1]) else {
            fputs("config: skipping \"\(line)\"; keys: \(configKeys.joined(separator: ", "))\n", stderr)
            continue
        }
        result[parts[0]] = CGFloat(value)
    }
    return result
}()
let gap = config["gap"] ?? 0
let paddingTop = config["padding-top"] ?? 0
let paddingBottom = config["padding-bottom"] ?? 0
let paddingLeft = config["padding-left"] ?? 0
let paddingRight = config["padding-right"] ?? 0

// How far the strip is scrolled, in points. Column i is centered on screen when stripOffset == columnCenters[i].
var stripOffset: CGFloat = 0

// One connection per call: pass all lines of a layout at once.
func send(_ lines: [String]) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = socketPath.withCString { strncpy(&addr.sun_path.0, $0, 103) }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard ok == 0 else { return }
    _ = (lines.joined(separator: "\n") + "\n").withCString { write(fd, $0, strlen($0)) }
}

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

// Column centers on the strip in points, column 0 at 0. Windows keep their own width and sit `gap` apart.
func centers(of wins: [Win]) -> [CGFloat] {
    var x = -(wins.first?.frame.width ?? 0) / 2
    return wins.map { win in
        defer { x += win.frame.width + gap }
        return x + win.frame.width / 2
    }
}

// Window ids left to right, and their centers as of the last layout.
var columns: [UInt32] = []
var columnCenters: [CGFloat] = []

func focusedIndex() -> Int {
    columnCenters.indices.min { abs(columnCenters[$0] - stripOffset) < abs(columnCenters[$1] - stripOffset) } ?? 0
}

// Each Space keeps its own strip; the one in use lives in the globals above.
var currentSpace: UInt64 = 0
var savedStrips: [UInt64: (columns: [UInt32], centers: [CGFloat], offset: CGFloat)] = [:]

// Drops closed windows and inserts new ones right of the focused column.
// Returns live windows in column order, where the last new window went, and the frontmost window.
func syncColumns() -> (wins: [Win], inserted: Int?, front: UInt32?) {
    let space = CGSGetActiveSpace(cid)
    if space != currentSpace {
        savedStrips[currentSpace] = (columns, columnCenters, stripOffset)
        (columns, columnCenters, stripOffset) = savedStrips[space] ?? ([], [], 0)
        currentSpace = space
    }
    let live = windows(on: space)
    let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    columns.removeAll { byId[$0] == nil }
    var at = min(focusedIndex() + 1, columns.count)
    var inserted: Int?
    for id in byId.keys.sorted() where !columns.contains(id) {
        columns.insert(id, at: at)
        inserted = at
        at += 1
    }
    // CGWindowList is ordered front to back, so the first window is the focused one.
    return (columns.compactMap { byId[$0] }, inserted, live.first?.id)
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

// Height each window was last resized to. One try per window and height, so a window that refuses
// (fixed size, min/max limits) or that the user resized by hand is left alone.
// ponytail: entries of closed windows stay; window ids are not reused within a session.
var sizedTo: [UInt32: CGFloat] = [:]

// How far the strip shows when dragged `over` points past its end: the further, the less it moves (UIScrollView's curve).
func rubberBand(_ over: CGFloat, _ dimension: CGFloat) -> CGFloat {
    let pulled = dimension * (1 - 1 / (abs(over) / dimension * 0.55 + 1))
    return over < 0 ? -pulled : pulled
}

// immediate: "M" moves right away (used while the finger is down). Otherwise "S" sets a target and the payload eases there.
func layout(immediate: Bool) {
    let screen = CGDisplayBounds(CGMainDisplayID())
    // Between the menu bar and the Dock, minus padding. CG y grows down from the top of the main display.
    let visible = NSScreen.screens.first.map { (top: $0.frame.maxY - $0.visibleFrame.maxY, bottom: $0.visibleFrame.minY - $0.frame.minY) } ?? (0, 0)
    let top = screen.minY + visible.top + paddingTop
    let height = screen.maxY - visible.bottom - paddingBottom - top
    let centerX = screen.minX + paddingLeft + (screen.width - paddingLeft - paddingRight) / 2
    let wins = syncColumns().wins
    columnCenters = centers(of: wins)
    let maxOffset = columnCenters.last ?? 0
    let clamped = min(max(0, stripOffset), maxOffset)
    // Finger down: past the first or last column the strip stretches like rubber; the lift snaps it back.
    // Otherwise the offset is clamped for good.
    let offset = immediate ? clamped + rubberBand(stripOffset - clamped, screen.width) : clamped
    if !immediate { stripOffset = clamped }
    send(wins.enumerated().map { index, win in
        let x = centerX + columnCenters[index] - offset - win.frame.width / 2
        return "\(immediate ? "M" : "S") \(win.id) \(x) \(top)"
    })
    guard !immediate else { return }
    var resized = false
    for win in wins where sizedTo[win.id] != height {
        sizedTo[win.id] = height
        if abs(win.frame.height - height) >= 1 { setHeight(win, height); resized = true }
    }
    // An app that resizes may commit its frame at the position it last knew; put it back in its column.
    if resized { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { layout(immediate: false) } }
}

func focusColumn(at index: Int) {
    let wins = syncColumns().wins
    guard !wins.isEmpty else { return }
    let i = min(max(0, index), wins.count - 1)
    stripOffset = centers(of: wins)[i]
    layout(immediate: false)
    NSRunningApplication(processIdentifier: wins[i].pid)?.activate()
}

// Keyboard: one column left or right from the column the strip is closest to.
func focusColumn(by delta: Int) {
    focusColumn(at: focusedIndex() + delta)
}

// Trackpad: the strip follows the 3-finger centroid. A swipe that starts vertical is left to macOS (Mission Control).
// On lift the strip is thrown by the last finger speed and snaps to the nearest column.
// ponytail: one trackpad at a time; frames from a second trackpad would interleave with the first.
var fingerCount: Int32 = 0
let gestureFingers: Int32 = 3
let swipeScale = CGDisplayBounds(CGMainDisplayID()).width  // points per full trackpad width
let swipeThreshold: CGFloat = 0.02  // trackpad widths before the direction is decided

var gestureActive = false
var swipeIgnored = false  // this touch went vertical
var lastCenter: CGPoint?
var swipeTravel = CGPoint.zero
var swipeVelocity: CGFloat = 0  // points per frame, smoothed

// Main thread. center is the normalized (0...1) centroid of the touches, or nil when there are none.
func touchFrame(count: Int32, center: CGPoint?) {
    guard count == gestureFingers, let center else {
        if gestureActive {
            gestureActive = false
            stripOffset -= swipeVelocity * 8  // ponytail: fixed throw; real momentum would decay over frames
            focusColumn(at: focusedIndex())
        }
        swipeIgnored = false
        lastCenter = nil
        swipeTravel = .zero
        swipeVelocity = 0
        return
    }
    defer { lastCenter = center }
    guard let last = lastCenter, !swipeIgnored else { return }
    let dx = center.x - last.x, dy = center.y - last.y
    if !gestureActive {
        swipeTravel.x += dx
        swipeTravel.y += dy
        guard max(abs(swipeTravel.x), abs(swipeTravel.y)) >= swipeThreshold else { return }
        if abs(swipeTravel.y) > abs(swipeTravel.x) { swipeIgnored = true; return }
        gestureActive = true
    }
    // Fingers right: strip right, so content follows the fingers like natural scrolling.
    let delta = dx * swipeScale
    swipeVelocity = swipeVelocity * 0.5 + delta * 0.5
    stripOffset -= delta
    layout(immediate: true)
}

// Touches come from MultitouchSupport (private framework, same as OmniWM). Set macOS horizontal 3-finger
// gestures (swipe between full-screen apps) to 4 fingers or off, or macOS fires them too.
typealias ContactCallback = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int32, Double, Int32, UnsafeMutableRawPointer?) -> Int32

func startMultitouch() {
    guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
          let createList = dlsym(lib, "MTDeviceCreateList"),
          let start = dlsym(lib, "MTDeviceStart"),
          let register = dlsym(lib, "MTRegisterContactFrameCallbackWithRefcon")
    else {
        fputs("MultitouchSupport unavailable: trackpad swipe disabled\n", stderr)
        return
    }
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias Start = @convention(c) (OpaquePointer, Int32) -> Int32
    typealias Register = @convention(c) (OpaquePointer, ContactCallback, UnsafeMutableRawPointer?) -> Int32

    // Runs on a MultitouchSupport thread. Each touch is a 96-byte MTTouch; the normalized position is two floats at offset 32.
    let callback: ContactCallback = { _, touches, count, _, _, _ in
        fingerCount = count
        var center: CGPoint?
        if let touches, count > 0 {
            var x: Float = 0, y: Float = 0
            for i in 0..<Int(count) {
                x += touches.load(fromByteOffset: i * 96 + 32, as: Float.self)
                y += touches.load(fromByteOffset: i * 96 + 36, as: Float.self)
            }
            center = CGPoint(x: CGFloat(x / Float(count)), y: CGFloat(y / Float(count)))
        }
        DispatchQueue.main.async { touchFrame(count: count, center: center) }
        return 0
    }
    guard let list = unsafeBitCast(createList, to: CreateList.self)()?.takeRetainedValue() else { return }
    for index in 0..<CFArrayGetCount(list) {
        guard let device = OpaquePointer(CFArrayGetValueAtIndex(list, index)) else { continue }
        _ = unsafeBitCast(register, to: Register.self)(device, callback, nil)
        _ = unsafeBitCast(start, to: Start.self)(device, 0)
    }
}

// Ctrl+Opt+Left / Right, Option+h/j/k/l. 3-finger scroll events are swallowed: the swipe is handled from raw touches.
let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.scrollWheel.rawValue | 1 << CGEventType.leftMouseUp.rawValue,
    callback: { _, type, event, _ in
        if type == .leftMouseUp {
            // A drag may have ended: send every window back to its slot. The payload eases from where it was dropped.
            // The short delay lets apps that move their own window (Electron, Chrome) apply their last move first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { layout(immediate: false) }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        if type == .scrollWheel {
            return fingerCount == gestureFingers ? nil : Unmanaged.passUnretained(event)
        }
        guard flags.contains(.maskAlternate) else { return Unmanaged.passUnretained(event) }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if flags.contains(.maskControl) {
            switch key {
            case 123: focusColumn(by: -1); return nil  // left
            case 124: focusColumn(by: 1); return nil   // right
            default: break
            }
        }
        // Option + h/k = previous column, Option + l/j = next column (vim keys, keycodes from the US layout).
        switch key {
        case 4, 40: focusColumn(by: -1); return nil   // h, k
        case 37, 38: focusColumn(by: 1); return nil   // l, j
        default: return Unmanaged.passUnretained(event)
        }
    },
    userInfo: nil
)

guard let tap = tap else {
    fputs("event tap failed: grant Accessibility to this binary\n", stderr)
    exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
startMultitouch()
layout(immediate: false)
// New window: scroll to it. Window focused by click or Cmd+Tab: scroll to it. Closed window: close the gap.
// ponytail: focus changes are seen by the same 4x/s poll; observe NSWorkspace activation if that feels slow.
var lastFront: UInt32?
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    guard !gestureActive else { return }
    let before = columns
    let sync = syncColumns()
    defer { lastFront = sync.front }
    if let index = sync.inserted {
        focusColumn(at: index)
    } else if sync.front != lastFront, let front = sync.front,
              let index = columns.firstIndex(of: front), index != focusedIndex() {
        focusColumn(at: index)
    } else if columns != before {
        layout(immediate: false)
    }
}
CFRunLoopRun()
