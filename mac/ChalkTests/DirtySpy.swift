import Foundation
import ChalkKit
@testable import Chalk

/// The suite's `DocumentControllerDelegate` stand-in: it forwards dirty-state
/// changes to a closure and refuses to pick a save destination.
///
/// Seven test files had a byte-identical copy of this — five called it
/// `DirtySpy` and two (`RecoveryDirtySpy`, `RoutingDirtySpy`) only differed by
/// the name they picked to dodge the collision `private` made unavoidable.
/// Internal, so there is one.
///
/// Only the two methods below have no default: everything else on
/// `DocumentControllerDelegate` is defaulted to a no-op in its protocol
/// extension, which is what a delegate that exists to observe one signal
/// wants.
final class DirtySpy: DocumentControllerDelegate {
    var onDirtyChange: ((Bool) -> Void)?

    func documentController(_ controller: DocumentController, didChangeDirty isDirty: Bool) {
        onDirtyChange?(isDirty)
    }

    func documentController(_ controller: DocumentController,
                            needsSaveDestination completion: @escaping (Bool) -> Void) {
        completion(false)
    }
}
