// Column order and scroll of every Space, kept across daemon restarts in ~/Library/Application Support/nori/strips.json.
// Written after a layout that changed them, read once at start. Window and Space ids last as long as the login session,
// so restarting the daemon (not the Mac) brings the strips back; ids that are gone drop out on the first sync.

import Cocoa

let stripsPath = NSHomeDirectory() + "/Library/Application Support/nori/strips.json"
var writtenStrips: Data?

func saveStrips() {
    var strips = savedStrips
    strips[currentSpace] = (columns, columnCenters, stripOffset)
    strips[0] = nil  // the placeholder before the first sync
    let object = Dictionary(uniqueKeysWithValues: strips.map { (String($0.key), ["columns": $0.value.columns, "offset": $0.value.offset] as [String: Any]) })
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
    writtenStrips = data
}
