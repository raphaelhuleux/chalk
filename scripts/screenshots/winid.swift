// Prints "<windowID> <x> <y> <w> <h>" for the largest on-screen window owned by PID argv[1],
// or, with a title substring as argv[2], the largest whose title contains it.
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let wantedTitle = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var best: (Int, CGRect)?
for w in info where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    guard (w[kCGWindowLayer as String] as? Int) == 0,
          let id = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    if let wantedTitle, !((w[kCGWindowName as String] as? String) ?? "").contains(wantedTitle) { continue }
    let r = CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
    if best == nil || r.width * r.height > best!.1.width * best!.1.height { best = (id, r) }
}
if let (id, r) = best { print(id, Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)) } else { exit(1) }
