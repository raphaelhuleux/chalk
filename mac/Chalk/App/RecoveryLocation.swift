import Foundation
import ChalkKit

extension RecoveryStore {
    /// Chalk's own folder. The Privacy screen reveals this one and tells the
    /// user everything it describes lives here, so every folder Chalk writes
    /// for itself sits inside it.
    ///
    /// Application Support, never Documents: this is Chalk's own bookkeeping,
    /// not the user's files, and it must not appear beside their work.
    static let chalkFolder: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.huleux.chalk",
                                    isDirectory: true)
    }()

    /// Where Chalk keeps unsaved-buffer snapshots. One definition: the editor
    /// writes here, the launch path counts what is here, and the Privacy screen
    /// reports on it and offers to empty it.
    static let appDirectory: URL = chalkFolder.appendingPathComponent("Recovery", isDirectory: true)

    /// Where a save conflict's losing version is copied when the sandbox
    /// refuses the copy beside the file. One definition for the same reason as
    /// `appDirectory`: the save path writes here and the Privacy screen counts
    /// what is here.
    static let conflictCopiesDirectory: URL =
        chalkFolder.appendingPathComponent("ConflictCopies", isDirectory: true)
}
