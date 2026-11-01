// POC helper for probe/border.m: tells it the focused window, here the front window of the frontmost app.
// swiftc probe/follow.swift -o build/border-follow && build/border-follow
// ponytail: polls every 50 ms. In nori the daemon knows the focused window, so this goes away with the probe.
import AppKit

let path = "/tmp/nori_border_\(NSUserName()).socket"
var last: CGWindowID = 0

func send(_ line: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { target in path.utf8CString.withUnsafeBytes { target.copyMemory(from: $0) } }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return }
    _ = (line + "\n").withCString { write(fd, $0, strlen($0)) }
    var reply = [UInt8](repeating: 0, count: 256)
    let n = read(fd, &reply, reply.count)
    if n > 0 { print(String(decoding: reply[..<n], as: UTF8.self), terminator: "") }
}

func frontWindow() -> CGWindowID? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    return list.first {
        $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0
            && ($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0 >= 50
    }?[kCGWindowNumber as String] as? CGWindowID
}

let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
    guard let wid = frontWindow(), wid != last else { return }
    last = wid
    send("T \(wid)")
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
