// Column order and scroll of every Space, and each window's frame before nori, kept across daemon restarts in
// ~/Library/Application Support/nori/strips.json. Written after a layout that changed them, read once at start. Window
// and Space ids last as long as the login session, so restarting the daemon (not the Mac) brings the strips back, and
// a nori started after a crash still puts windows back on quit; ids that are gone drop out on the first sync.
// A new login reads only `remembered`, the strips by app and title (Restore.swift).

import Cocoa

let stripsPath = NSHomeDirectory() + "/Library/Application Support/nori/strips.json"
var writtenStrips: Data?
let loginSession = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionUniqueSessionUUID"] as? String ?? ""
let restoreGrace = 120.0  // seconds after a launch in a new login: apps bring their windows back over a while
var poweringOff = false   // set by Events.swift

var remembered: [String: [RememberedWindow]] = [:]  // by Space uuid: the last login's strips, as far as not claimed
var restoreRanks: [UInt32: Int] = [:]               // the rank each restored window had
var restoreCeiling: UInt32 = 0                      // window ids above this opened after the grace: new, not restored
var windowTitles: [UInt32: String] = [:]            // as of the window's last focus

// Off the main thread, as a hung app must not stall the strip.
func readTitle(_ win: Win) {
    axQueue.async {
        guard let title = axTitle(win) else { return }
        DispatchQueue.main.async { windowTitles[win.id] = title }
    }
}

func appKey(_ pid: pid_t) -> String? { appNames(pid).last }

// The rank of a window coming into a strip, if the last login had it here. Its width too, unless a rule sets one.
func restoreRank(_ win: Win, on space: UInt64) -> Int? {
    guard win.id <= restoreCeiling, let uuid = spaceUUIDs()[space], var list = remembered[uuid], let app = appKey(win.pid),
          let rank = claimRemembered(app: app, title: axTitle(win), in: &list) else { return nil }
    remembered[uuid] = list
    restoreRanks[win.id] = rank
    if ruleWidth(win) == nil { pendingWidths[win.id] = min(CGFloat(list[rank].width), usableWidth) }
    return rank
}

// Every Space with a strip as it is now, the others as the last login left them: they may just not have been shown yet.
func rememberedStrips(_ strips: [UInt64: (columns: [UInt32], centers: [CGFloat], offset: CGFloat)]) -> [String: [[String: Any]]] {
    var all = remembered.mapValues { $0.filter { !$0.claimed } }
    let uuids = spaceUUIDs()
    for (space, strip) in strips {
        guard let uuid = uuids[space] else { continue }
        let windows = strip.columns.compactMap { id -> RememberedWindow? in
            guard let win = lastSeen[id], let app = appKey(win.pid) else { return nil }
            return RememberedWindow(app: app, title: windowTitles[id] ?? "", width: Double(win.frame.width))
        }
        if !windows.isEmpty { all[uuid] = windows }
    }
    return all.mapValues { $0.map { ["app": $0.app, "title": $0.title, "width": $0.width] } }
}

func saveStrips() {
    guard !poweringOff else { return }
    var strips = savedStrips
    strips[currentSpace] = (columns, columnCenters, stripOffset)
    strips[0] = nil  // the placeholder before the first sync
    var object = Dictionary(uniqueKeysWithValues: strips.map { (String($0.key), ["columns": $0.value.columns, "offset": $0.value.offset] as [String: Any]) })
    let open = Set(lastSeen.keys)
    object["frames"] = Dictionary(uniqueKeysWithValues: originalFrames.filter { open.contains($0.key) }.map { (String($0.key), [$0.value.minX, $0.value.minY, $0.value.width, $0.value.height]) })
    object["floating"] = Dictionary(uniqueKeysWithValues: floatingByHand.map { (String($0.key), $0.value) })
    object["dimmed"] = Dictionary(uniqueKeysWithValues: dimmed.map { (String($0.key), [$0.value.own, $0.value.set]) })
    object["remembered"] = rememberedStrips(strips)
    object["session"] = ["id": loginSession]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys), data != writtenStrips else { return }
    writtenStrips = data
    try? FileManager.default.createDirectory(atPath: (stripsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: stripsPath), options: .atomic)
}

// Into savedStrips: the first sync swaps the current Space's strip in.
func loadStrips() {
    guard let data = FileManager.default.contents(atPath: stripsPath),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
    for (uuid, value) in object["remembered"] ?? [:] {
        remembered[uuid] = (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let app = entry["app"] as? String, let width = entry["width"] as? Double else { return nil }
            return RememberedWindow(app: app, title: entry["title"] as? String ?? "", width: width)
        }
    }
    // Ids name other windows now. A file from before sessions were kept counts as this login.
    if let session = object["session"]?["id"] as? String, session != loginSession {
        restoreCeiling = .max
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreGrace) {
            restoreCeiling = listWindows([]).map(\.win.id).max() ?? 0
        }
        return
    }
    for (key, strip) in object {
        guard let space = UInt64(key), let ids = strip["columns"] as? [NSNumber] else { continue }
        savedStrips[space] = (ids.map(\.uint32Value), [], CGFloat((strip["offset"] as? NSNumber)?.doubleValue ?? 0))
    }
    for (key, value) in object["frames"] ?? [:] {
        guard let id = UInt32(key), let f = (value as? [NSNumber])?.map({ CGFloat($0.doubleValue) }), f.count == 4 else { continue }
        originalFrames[id] = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
    }
    // Only windows open now: after a new login the same ids name other windows.
    let open = Set(listWindows([]).map(\.win.id))
    for (key, value) in object["floating"] ?? [:] {
        guard let id = UInt32(key), open.contains(id), let width = value as? NSNumber else { continue }
        floatingByHand[id] = CGFloat(width.doubleValue)
    }
    for (key, value) in object["dimmed"] ?? [:] {
        guard let id = UInt32(key), open.contains(id), let alpha = (value as? [NSNumber])?.map(\.floatValue), alpha.count == 2 else { continue }
        dimmed[id] = (alpha[0], alpha[1])
    }
    writtenStrips = data
}
