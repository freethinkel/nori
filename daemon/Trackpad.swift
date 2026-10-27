// 3-finger horizontal swipe from raw touches. Works with the macOS 3-finger vertical gestures (Mission Control) on.

import Cocoa

// Trackpad: the strip follows the 3-finger centroid. A swipe that starts vertical is left to macOS (Mission Control).
// On lift the strip is thrown by the last finger speed and snaps to the nearest column.
// ponytail: one trackpad at a time; frames from a second trackpad would interleave with the first.
var fingerCount: Int32 = 0
let gestureFingers: Int32 = 3
let swipeSpeed: CGFloat = 1.3  // strip points per point of finger travel; above 1 the strip outruns the fingers
let swipeScale = CGDisplayBounds(CGMainDisplayID()).width * swipeSpeed  // points per full trackpad width
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
