// Talks to payload.dylib in Dock over its unix socket. Line protocol: see payload/payload.m.

import Cocoa

let user = ProcessInfo.processInfo.environment["USER"] ?? "user"
let socketPath = "/tmp/nori_\(user).socket"

// Calls body with the sockaddr of a unix socket path, for connect and bind.
func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = path.withCString { strncpy(&addr.sun_path.0, $0, 103) }
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

// One connection per call: pass all lines of a layout at once.
func send(_ lines: [String]) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    guard withAddress(socketPath, { connect(fd, $0, $1) }) == 0 else { return }
    _ = (lines.joined(separator: "\n") + "\n").withCString { write(fd, $0, strlen($0)) }
}

// Dock restarting (a crash, `killall Dock`) takes the payload with it, and from then on `send` drops every command.
// Checked every 2 s, and two misses in a row count: one refused connect can be a full backlog. nori's own Dock restarts
// don't get here: loadPayload blocks the main thread through its restart, and restartDockSoon runs on the way out.
var payloadLost = false
var payloadMisses = 0

func watchPayload() {
    guard !payloadAlive() else {
        payloadMisses = 0
        if payloadLost { payloadBack() }
        return
    }
    payloadMisses += 1
    guard payloadMisses == 2 else { return }
    payloadLost = true
    resetOverview()             // nothing would close it, and an open overview keeps every click
    spaceLayoutDone(layoutSeq)  // nothing would report the end of a running layout
    report(Problem(key: "payload", title: "nori is not running in Dock", help: "Dock restarted. Windows and Spaces stay put until you choose this to reload nori.",
                   fix: #selector(MenuActions.reloadPayload)))
    if alert("nori stopped working",
             "Dock restarted, and nori's helper went with it. Windows and Spaces stay put until it is back. Reloading restarts Dock once more and may ask for your password. You can also do it later from nori's menu.",
             ["Reload", "Later"]) == .alertFirstButtonReturn {
        reloadDockPayload()
    }
}

// The one call that gets the payload back while nori runs. Cancelled or failed, nori goes on without it.
func reloadDockPayload() {
    loadPayload()
    if payloadAlive() { payloadBack() }
}

func payloadBack() {
    payloadLost = false
    payloadMisses = 0
    clearProblem("payload")
    send(["P \(getpid())"])  // vertical Spaces from now on, not from the next repeat
    layout(immediate: false)
}
