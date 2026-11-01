// Strips across a reboot. Window ids last one login, so strips.json also keeps each Desktop's windows by app and title.
// In a new login a window that comes up on its Desktop takes its old place and width, without taking focus: the same
// title first, then the next window of that app. The windows have to find their own way there: nori moves none between
// Desktops for this. Persist.swift keeps the list, syncColumns (Strip.swift) asks here.

import Foundation

struct RememberedWindow: Equatable {
    let app: String
    let title: String
    let width: Double
    var claimed = false
}

// The entry for a window, marked as taken. Its index is the window's rank in the old strip.
func claimRemembered(app: String, title: String?, in list: inout [RememberedWindow]) -> Int? {
    let open = list.indices.filter { !list[$0].claimed && list[$0].app == app }
    guard let rank = open.first(where: { list[$0].title == title }) ?? open.first else { return nil }
    list[rank].claimed = true
    return rank
}

// Where a window of that rank goes among columns with these ranks (nil: not restored): before the first with a later one.
func restoredIndex(rank: Int, ranks: [Int?]) -> Int {
    ranks.firstIndex { ($0 ?? -1) > rank } ?? ranks.count
}
