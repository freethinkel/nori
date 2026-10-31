// Mission Control and App Exposé use the same 3- and 4-finger swipes as nori, and macOS can act on them before a
// session event tap sees the gesture. nori turns both off while it runs and puts the original values back on quit.
// The originals live in system-gestures.json, so a crash (which skips the restore) still leaves the next launch
// knowing what to put back, and a manual `defaults write` while nori runs is left alone on the way out.
// leave-system-gestures keeps them on, from the next launch: changing them means a Dock restart and the admin password.

import Cocoa

let systemGestureKeys = ["showMissionControlGestureEnabled", "showAppExposeGestureEnabled"]
let systemGesturesPath = NSHomeDirectory() + "/Library/Application Support/nori/system-gestures.json"
var systemGesturesManaged = false  // this process wrote the originals, so it should put them back
var keepSystemGestures = false  // an update relaunch hands them to the new instance

func dockGesture(_ key: String) -> Bool {
    shell("/usr/bin/defaults", ["read", "com.apple.dock", key]).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
}

func setDockGesture(_ key: String, _ on: Bool) {
    _ = shell("/usr/bin/defaults", ["write", "com.apple.dock", key, "-bool", on ? "true" : "false"])
}

func savedSystemGestures() -> [String: Bool]? {
    guard let data = FileManager.default.contents(atPath: systemGesturesPath),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return nil }
    return object
}

@discardableResult
func saveSystemGestures(_ values: [String: Bool]) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys) else { return false }
    try? FileManager.default.createDirectory(atPath: (systemGesturesPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    return (try? data.write(to: URL(fileURLWithPath: systemGesturesPath), options: .atomic)) != nil
}

// Called once at launch, after Accessibility. Returns true when a preference changed, so Dock must restart to apply it
// (loadPayload does that). The state file is written before the first change, so a crash can never lose the originals.
func disableSystemGestures() -> Bool {
    let originals = savedSystemGestures() ?? Dictionary(uniqueKeysWithValues: systemGestureKeys.map { ($0, dockGesture($0)) })
    guard saveSystemGestures(originals) else {
        report(Problem(key: "system-gestures", title: "Mission Control's swipes stay on", help: "nori could not write \(systemGesturesPath), so macOS may act on nori's swipes too."))
        return false
    }
    systemGesturesManaged = true
    var changed = false
    for key in systemGestureKeys where dockGesture(key) {
        setDockGesture(key, false)
        if dockGesture(key) {
            report(Problem(key: "system-gestures", title: "Mission Control's swipes stay on", help: "nori could not turn off \(key) in com.apple.dock, so macOS may act on nori's swipes too."))
        } else {
            changed = true
        }
    }
    return changed
}

// Called on the way out.
func restoreSystemGestures() {
    if putBackSystemGestures() { restartDockSoon() }
}

// Only undo what nori turned off: if the user turned one back on meanwhile, leave it. Returns true when a preference
// changed, so Dock must restart to apply it.
func putBackSystemGestures() -> Bool {
    guard let originals = savedSystemGestures() else { return false }
    var changed = false, failed = false
    for (key, original) in originals where original && !dockGesture(key) {
        setDockGesture(key, true)
        if dockGesture(key) { changed = true } else { failed = true }
    }
    // Keep the file when a write failed, so the next launch can try again.
    guard !failed else { return false }
    try? FileManager.default.removeItem(atPath: systemGesturesPath)
    return changed
}

// Runs from atexit for an exit path that forgot to restore explicitly. The update relaunch keeps them for the new instance.
func restoreSystemGesturesOnExit() {
    guard systemGesturesManaged, !keepSystemGestures else { return }
    restoreSystemGestures()
}

// The payload puts the windows back from Dock, and a killall right away could drop those commands. Give it a moment,
// then let Dock read the restored gesture preferences. The helper outlives this process, which exits right after.
func restartDockSoon() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sleep 0.5; /usr/bin/killall Dock"]
    try? process.run()
}
