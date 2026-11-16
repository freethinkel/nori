// Dock's own Space swipe, driven from nori's 3-finger vertical swipe: synthetic DockSwipe events (Began, Changed with
// the progress, then Ended or Cancelled), so a swipe moves exactly like Dock's switch (Control+arrow), offset included,
// and the payload's hook turns it vertical as it does that one. One Space per swipe, as in macOS.
// macOS 27 takes such an event only with the IOHID payload a real trackpad's carries appended to it. The fields and
// the payload are from InstantSpaceSwitcher (MIT, (c) 2026 jurplel), Sources/ISS/ISS.c and event_serialize.c;
// probe/dock-swipe.m tried them (docs/WINDOWSERVER.md).

import Cocoa

enum DockSwipePhase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

// progress: Spaces, signed the way Dock reads it (see dockSwipeSign).
func postDockSwipe(_ phase: DockSwipePhase, progress: Double) {
    func field(_ n: UInt32) -> CGEventField { CGEventField(rawValue: n)! }
    guard let event = CGEvent(source: nil), let companion = CGEvent(source: nil) else { return }
    event.setIntegerValueField(field(55), value: 30)  // DockControl
    event.setIntegerValueField(field(110), value: 23)  // DockSwipe
    event.setIntegerValueField(field(132), value: phase.rawValue)
    event.setIntegerValueField(field(134), value: phase.rawValue)
    event.setIntegerValueField(field(123), value: 1)  // horizontal, as Dock's swipe is
    event.setDoubleValueField(field(124), value: progress)
    event.setDoubleValueField(field(125), value: 0.1)
    event.setDoubleValueField(field(138), value: 3)
    event.setDoubleValueField(field(169), value: Double(mach_absolute_time()))
    guard let augmented = withIOHIDPayload(event, phase: phase, progress: progress) else { return }
    companion.setIntegerValueField(field(55), value: 29)  // Dock ignores a DockControl event without a gesture one
    augmented.post(tap: .cgSessionEventTap)
    companion.post(tap: .cgSessionEventTap)
}

// Dock reads the sign through natural scrolling. With it on, a negative progress goes to the next Space (verified).
var dockSwipeSign: Double {
    UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.swipescrolldirection"] as? Bool == false ? 1 : -1
}

// The event's own bytes, a tag (payload size and field 4205, big-endian), then an IOHID queue element: a header, a
// fluid touch gesture (type 23, phase in the top byte of options, flavor 3: Dock's), and for Ended a velocity (type 9).
private func withIOHIDPayload(_ event: CGEvent, phase: DockSwipePhase, progress: Double) -> CGEvent? {
    guard let data = event.data as Data?, data.starts(with: [0, 0, 0, 2]) else { return nil }
    func fixed(_ v: Double) -> Int32 { let f = Int32(v * 65536); return f == 0 && v != 0 ? (v > 0 ? 1 : -1) : f }
    var payload = Data()
    func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { payload.append(contentsOf: $0) } }
    let velocity = phase == .ended
    put(mach_absolute_time()); put(UInt64(0)); put(UInt32(0)); put(UInt32(0)); put(UInt32(velocity ? 2 : 1))
    put(UInt32(40)); put(UInt32(23)); put(UInt32(phase.rawValue & 0xFF) << 24); put(UInt32(0))  // size type options depth
    put(fixed(0.1)); put(Int32(0)); put(Int32(0)); put(UInt32(0)); put(UInt16(1)); put(UInt16(3)); put(fixed(progress))
    if velocity { put(UInt32(28)); put(UInt32(9)); put(UInt32(0)); put(UInt32(1)); put(Int32(0)); put(Int32(0)); put(Int32(0)) }
    var out = data
    out.append(contentsOf: [UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF), UInt8(4205 >> 8), UInt8(4205 & 0xFF)])
    out.append(payload)
    return CGEvent(withDataAllocator: nil, data: out as CFData)
}
