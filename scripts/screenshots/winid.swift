// Prints "<windowID> <x> <y> <w> <h>" for the largest on-screen window owned by PID argv[1].
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var best: (Int, CGRect)?
for w in info where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    guard (w[kCGWindowLayer as String] as? Int) == 0,
          let id = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let r = CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
    if best == nil || r.width * r.height > best!.1.width * best!.1.height { best = (id, r) }
}
if let (id, r) = best { print(id, Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)) } else { exit(1) }
