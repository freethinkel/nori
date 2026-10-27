// Column order and scroll of every Space, and each window's frame before nori, kept across daemon restarts in
// ~/Library/Application Support/nori/strips.json. Written after a layout that changed them, read once at start. Window
// and Space ids last as long as the login session, so restarting the daemon (not the Mac) brings the strips back, and
// a nori started after a crash still puts windows back on quit; ids that are gone drop out on the first sync.

import Cocoa

let stripsPath = NSHomeDirectory() + "/Library/Application Support/nori/strips.json"
var writtenStrips: Data?

func saveStrips() {
    var strips = savedStrips
    strips[currentSpace] = (columns, columnCenters, stripOffset)
    strips[0] = nil  // the placeholder before the first sync
    var object = Dictionary(uniqueKeysWithValues: strips.map { (String($0.key), ["columns": $0.value.columns, "offset": $0.value.offset] as [String: Any]) })
    let open = Set(lastSeen.keys)
    object["frames"] = Dictionary(uniqueKeysWithValues: originalFrames.filter { open.contains($0.key) }.map { (String($0.key), [$0.value.minX, $0.value.minY, $0.value.width, $0.value.height]) })
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys), data != writtenStrips else { return }
    writtenStrips = data
    try? FileManager.default.createDirectory(atPath: (stripsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: stripsPath), options: .atomic)
}

// Into savedStrips: the first sync swaps the current Space's strip in.
func loadStrips() {
    guard let data = FileManager.default.contents(atPath: stripsPath),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
    for (key, strip) in object {
        guard let space = UInt64(key), let ids = strip["columns"] as? [NSNumber] else { continue }
        savedStrips[space] = (ids.map(\.uint32Value), [], CGFloat((strip["offset"] as? NSNumber)?.doubleValue ?? 0))
    }
    for (key, value) in object["frames"] ?? [:] {
        guard let id = UInt32(key), let f = (value as? [NSNumber])?.map({ CGFloat($0.doubleValue) }), f.count == 4 else { continue }
        originalFrames[id] = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
    }
    writtenStrips = data
}
