// Control socket for "nori query …" and "nori focus …": queries about Spaces and windows, and the same actions as the hotkeys.
// One request per connection: the arguments joined by tabs, one line. Reply: JSON for a query, nothing for an action
// that worked, "error: …" otherwise. Then the daemon closes the connection. runClient is the other end.
// "subscribe" keeps the connection: one compact line of "query spaces" JSON now and after every change (publish below).
// The socket path and this format are public API (README, CLI): bars talk to the socket directly.

import Cocoa

let controlPath = "/tmp/nori-ctl_\(user).socket"
var controlSource: DispatchSourceRead?

let usage = """
    error: usage:
      nori                    run nori itself
      nori query spaces [--current]
      nori query windows [--space N] [--current] [--app NAME] [--id WID] [--focused]
      nori subscribe
      nori focus left|right
      nori focus column N
      nori focus space N
      nori focus window WID

    """

// nori with arguments: send them to the running nori, print its reply, exit 1 on an error.
func runClient(_ args: [String]) -> Never {
    if ["help", "-h", "--help"].contains(args[0]) {
        print(usage.dropFirst("error: ".count), terminator: "")
        exit(0)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0, withAddress(controlPath, { connect(fd, $0, $1) }) == 0 else {
        fputs("nori is not running\n", stderr)
        exit(1)
    }
    var request = Array((args.joined(separator: "\t") + "\n").utf8)[...]
    while !request.isEmpty {
        let n = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { break }
        request = request.dropFirst(n)
    }
    var reply: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    if args == ["subscribe"] {
        while case let n = read(fd, &buffer, buffer.count), n > 0 { FileHandle.standardOutput.write(Data(buffer[..<n])) }
        fputs("nori quit\n", stderr)
        exit(2)  // like OmniWM's subscribe: a lost connection is not the stream's normal end
    }
    while case let n = read(fd, &buffer, buffer.count), n > 0 { reply += buffer[..<n] }
    let text = String(decoding: reply, as: UTF8.self)
    if text.hasPrefix("error:") {
        fputs(text, stderr)
        exit(1)
    }
    print(text, terminator: "")
    exit(0)
}

// Requests run on the main queue, between polls, so they see the same state as the hotkeys.
func startControl() {
    unlink(controlPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    let mask = umask(0o177)  // owner only: the socket moves and focuses windows
    let bound = fd >= 0 && withAddress(controlPath, { bind(fd, $0, $1) }) == 0 && listen(fd, 8) == 0
    umask(mask)
    guard bound else {
        fputs("control socket \(controlPath) failed\n", stderr)
        return
    }
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
        var on: Int32 = 1  // a client gone before its reply must not kill the daemon with SIGPIPE
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)  // a stuck client must not stall the daemon
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !request.contains(10), request.count < 65536 {
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { break }
            request += buffer[..<n]
        }
        let line = String(decoding: request.prefix { $0 != 10 }, as: UTF8.self)
        if line == "subscribe" { return subscribe(client) }
        defer { close(client) }
        var reply = Array(handle(line.components(separatedBy: "\t")).utf8)[...]
        while !reply.isEmpty {
            let n = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            reply = reply.dropFirst(n)
        }
    }
    source.resume()
    controlSource = source
}

// Subscribers get each line whole or not at all: a full buffer means the client stopped reading, and it is dropped
// rather than stall the daemon. Disconnected ones drop out on the next write.
var subscribers: [Int32] = []
var lastPublished = ""
var publishQueued = false

func subscribe(_ client: Int32) {
    var size: Int32 = 1 << 20
    setsockopt(client, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
    publish(to: client)
}

func sendLine(_ fd: Int32, _ line: String) -> Bool {
    let sent = line.utf8CString.withUnsafeBytes { write(fd, $0.baseAddress, $0.count - 1) } == line.utf8.count
    if !sent { close(fd) }
    return sent
}

// Sends the snapshot to every subscriber if it changed, and to a new one in any case.
func publish(to new: Int32? = nil) {
    guard !subscribers.isEmpty || new != nil else { return }
    let line = json(querySpaces([:]), pretty: false)
    if line != lastPublished {
        lastPublished = line
        subscribers.removeAll { !sendLine($0, line) }
    }
    if let new, sendLine(new, line) { subscribers.append(new) }
}

// Called wherever state may have changed (poll, layout, a Space switch starting); a burst sends one snapshot.
func publishSoon() {
    guard !subscribers.isEmpty, !publishQueued else { return }
    publishQueued = true
    DispatchQueue.main.async {
        publishQueued = false
        publish()
    }
}

func handle(_ args: [String]) -> String {
    let number = args.count == 3 ? Int(args[2]) : nil
    switch (args.first ?? "", args.count > 1 ? args[1] : "") {
    case ("query", "spaces"):
        guard let opts = options(args.dropFirst(2), values: [], flags: ["--current"]) else { break }
        return json(querySpaces(opts))
    case ("query", "windows"):
        guard let opts = options(args.dropFirst(2), values: ["--space", "--app", "--id"], flags: ["--current", "--focused"]) else { break }
        return json(queryWindows(opts))
    case ("focus", "left") where args.count == 2:
        focusColumn(by: -1)
        return ""
    case ("focus", "right") where args.count == 2:
        focusColumn(by: 1)
        return ""
    case ("focus", "column"):
        guard let n = number else { break }
        guard columns.indices.contains(n - 1) else { return "error: no column \(n)\n" }
        focusColumn(at: n - 1)
        return ""
    case ("focus", "space"):
        guard let n = number else { break }
        return switchToSpace(n) ? "" : "error: no Desktop \(n), or its shortcut is off in Keyboard Shortcuts → Mission Control\n"
    // From the payload in Dock, see its header.
    case ("payload", "layout-done"):
        if let n = number { spaceLayoutDone(n) }
        return ""
    case ("payload", "resize-settled") where args.count == 4:
        if let window = UInt32(args[2]), let width = Double(args[3]) { resizeSettled(window, CGFloat(width)) }
        return ""
    case ("focus", "window"):
        guard let n = number else { break }
        guard let listed = listWindows([]).first(where: { $0.win.id == n }) else { return "error: no window \(n)\n" }
        focusWindow(listed)
        return ""
    default:
        break
    }
    return usage
}

// "--name value" pairs and bare "--flag"s. nil for an unknown option or a missing value.
func options(_ args: ArraySlice<String>, values: Set<String>, flags: Set<String>) -> [String: String]? {
    var result: [String: String] = [:]
    var rest = args.makeIterator()
    while let arg = rest.next() {
        if flags.contains(arg) {
            result[arg] = ""
        } else if values.contains(arg), let value = rest.next() {
            result[arg] = value
        } else {
            return nil
        }
    }
    return result
}

func json(_ value: Any, pretty: Bool = true) -> String {
    if (value as? [Any])?.isEmpty == true { return "[]\n" }  // JSONSerialization pretty-prints it as "[\n\n]"
    let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, pretty ? .prettyPrinted : []])
    return (data.map { String(decoding: $0, as: UTF8.self) } ?? "null") + "\n"
}

// The Space a switch nori started is going to, until Dock gets there (pressDesktop). The deadline covers a switch
// that never happens.
var pendingSpace: (id: UInt64, until: CFTimeInterval)?

// The Space that has focus, or is about to: a bar lights the target up on the key press, not after Dock's slide.
func focusedSpace() -> UInt64 {
    let active = CGSGetActiveSpace(cid)
    if let pending = pendingSpace, pending.id != active, CACurrentMediaTime() < pending.until { return pending.id }
    pendingSpace = nil
    return active
}

// Spaces of all displays in Mission Control order. Desktops are numbered from 1 across displays,
// like the "Switch to Desktop N" shortcuts; fullscreen Spaces get no number. visible: shown on its display
// ("Current Space" there), with the switch target counted as shown already.
func spaces() -> [(id: UInt64, number: Int?, display: String, fullscreen: Bool, visible: Bool)] {
    let displays = CGSCopyManagedDisplaySpaces(cid).takeRetainedValue() as? [[String: Any]] ?? []
    let focused = focusedSpace()
    var desktops = 0
    return displays.flatMap { display in
        let list = display["Spaces"] as? [[String: Any]] ?? []
        let ids = list.map { ($0["id64"] as? NSNumber)?.uint64Value ?? 0 }
        let current = ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
        let shown = ids.contains(focused) ? focused : current
        return zip(ids, list).map { id, space in
            let fullscreen = space["type"] as? Int == 4
            if !fullscreen { desktops += 1 }
            return (id, fullscreen ? nil : desktops, display["Display Identifier"] as? String ?? "", fullscreen, id == shown)
        }
    }
}

// Window ids left to right as the strip of that Space last saw them, closed ones left out. A Space nori hasn't shown
// yet gets the order its first sync will give it (syncColumns): ascending ids, floating windows left out.
func strip(of space: UInt64, _ listed: [Listed]) -> [UInt32] {
    let current = rules
    let here = listed.filter { $0.spaces.contains(space) && rule(for: $0.win.pid, in: current)?.floating != true }.map(\.win.id)
    guard let saved = space == currentSpace ? columns : savedStrips[space]?.columns else { return here.sorted() }
    return saved.filter(here.contains)
}

// Focused window per Space. The current Space: the focused window of the frontmost app, from Accessibility, so a
// panel or popover on top doesn't count. Others: the frontmost window there, which is the one focused there last.
// ponytail: z-order guess for other Spaces; keep a per-Space focus history if it guesses wrong.
func focusedWindows(_ listed: [Listed]) -> [UInt64: UInt32] {
    let active = CGSGetActiveSpace(cid)
    var result: [UInt64: UInt32] = [:]
    for w in listed { for space in w.spaces where space != active && result[space] == nil { result[space] = w.win.id } }
    if let front = focusedWindowID(), listed.contains(where: { $0.win.id == front && $0.spaces.contains(active) }) { result[active] = front }
    return result
}

func appName(_ listed: Listed) -> String {
    NSRunningApplication(processIdentifier: listed.win.pid)?.localizedName ?? listed.info[kCGWindowOwnerName as String] as? String ?? ""
}

func querySpaces(_ opts: [String: String]) -> [[String: Any]] {
    let all = spaces()
    let focused = focusedSpace()
    let listed = listWindows([])
    let focusedWins = focusedWindows(listed)
    return all.filter { opts["--current"] == nil || $0.id == focused }.map { space in
        let wins = listed.filter { $0.spaces.contains(space.id) }
        var pids: [pid_t] = []
        for w in wins where !pids.contains(w.win.pid) { pids.append(w.win.pid) }
        let apps: [[String: Any]] = pids.map { pid in
            let own = wins.filter { $0.win.pid == pid }
            return ["pid": pid, "name": appName(own[0]), "windows": own.map(\.win.id),
                    "bundleId": NSRunningApplication(processIdentifier: pid)?.bundleIdentifier as Any? ?? NSNull()]
        }
        let fields: [String: Any?] = [
            "id": space.id, "number": space.number, "display": space.display,
            "type": space.fullscreen ? "fullscreen" : "desktop", "isFocused": space.id == focused, "isVisible": space.visible,
            "windows": wins.map(\.win.id), "columns": strip(of: space.id, listed), "apps": apps,
            "focusedWindow": focusedWins[space.id],
        ]
        return fields.compactMapValues { $0 }
    }
}

func queryWindows(_ opts: [String: String]) -> [[String: Any]] {
    let active = CGSGetActiveSpace(cid)
    let all = spaces()
    let numbers = Dictionary(all.compactMap { s in s.number.map { (s.id, $0) } }, uniquingKeysWith: { a, _ in a })
    let listed = listWindows([])
    let strips = Dictionary(all.map { ($0.id, strip(of: $0.id, listed)) }, uniquingKeysWith: { a, _ in a })
    let current = rules
    let focused = focusedWindows(listed)[active]
    return listed.compactMap { w in
        let id = w.win.id
        let space = w.spaces.contains(active) ? active : w.spaces[0]  // a window on all Spaces lists each of them
        let app = NSRunningApplication(processIdentifier: w.win.pid)
        if let n = opts["--space"], !w.spaces.contains(where: { numbers[$0].map(String.init) == n }) { return nil }
        if opts["--current"] != nil, space != active { return nil }
        if let name = opts["--app"], ![appName(w), app?.bundleIdentifier ?? ""].contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return nil }
        if let wanted = opts["--id"], wanted != String(id) { return nil }
        if opts["--focused"] != nil, id != focused { return nil }
        let title = (w.info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (space == active ? axTitle(w.win) : nil)
        let frame = w.win.frame
        let fields: [String: Any?] = [
            "id": id, "pid": w.win.pid, "app": appName(w), "bundleId": app?.bundleIdentifier, "title": title,
            "space": numbers[space], "spaceId": space, "column": strips[space]?.firstIndex(of: id).map { $0 + 1 },
            "isFocused": id == focused, "isOnScreen": w.info[kCGWindowIsOnscreen as String] as? Bool ?? false,
            "isFloating": rule(for: w.win.pid, in: current)?.floating == true,
            "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height],
        ]
        return fields.compactMapValues { $0 }
    }
}

// Posts the system "Switch to Desktop N" shortcut (symbolic hotkeys 118…133), whatever keys it is bound to.
func switchToSpace(_ number: Int) -> Bool {
    let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
    guard (1...16).contains(number), spaces().contains(where: { $0.number == number }),
          let entry = hotkeys?[String(117 + number)] as? [String: Any], entry["enabled"] as? Bool == true,
          let keys = (entry["value"] as? [String: Any])?["parameters"] as? [Int], keys.count == 3
    else { return false }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keys[1]), keyDown: down)
        event?.flags = CGEventFlags(rawValue: UInt64(keys[2]))  // NSEvent modifier bits, same as CGEventFlags
        event?.post(tap: .cghidEventTap)
    }
    return true
}

func focusWindow(_ listed: Listed) {
    let active = CGSGetActiveSpace(cid)
    if listed.spaces.contains(active) {
        if let index = columns.firstIndex(of: listed.win.id) { focusColumn(at: index) } else { focus(listed.win) }
        return
    }
    // Accessibility only sees windows of the current Space, so go there first. A fullscreen Space or one without
    // a shortcut: activating the app may switch Spaces by itself.
    // ponytail: fixed wait for the Space slide; wait for the active Space to change if 0.5 s is too short or too long.
    if let number = spaces().first(where: { listed.spaces.contains($0.id) })?.number, switchToSpace(number) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focus(listed.win) }
    } else {
        focus(listed.win)
    }
}
