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
