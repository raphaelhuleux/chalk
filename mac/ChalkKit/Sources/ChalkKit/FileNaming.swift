import Foundation

/// Naming rules for the Library: inline rename validation, and names for
/// duplicates and new files. Callers inject `isTaken`, so no filesystem.
public enum FileNaming {
    /// Why a typed name was refused.
    public enum RenameRejection: Equatable {
        case empty
        case unchanged
        case containsSlash
        case hidden
    }

    /// nil when `name` is an acceptable rename of `current`. A case-only change
    /// is acceptable, not "unchanged".
    public static func validateRename(_ name: String, current: String) -> RenameRejection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed == current { return .unchanged }
        if trimmed.contains("/") { return .containsSlash }
        if trimmed.hasPrefix(".") { return .hidden }
        return nil
    }

    /// `base.ext`, then `base 2.ext`, `base 3.ext`, …
    public static func uniqueName(
        base: String, ext: String?, isTaken: (String) -> Bool
    ) -> String {
        func name(_ stem: String) -> String {
            guard let ext, !ext.isEmpty else { return stem }
            return "\(stem).\(ext)"
        }
        var candidate = name(base)
        var n = 2
        while isTaken(candidate) {
            candidate = name("\(base) \(n)")
            n += 1
        }
        return candidate
    }

    /// The name a Duplicate lands on, keeping the extension. A leading dot
    /// belongs to the stem: ".gitignore" becomes ".gitignore 2".
    public static func duplicateName(for fileName: String, isTaken: (String) -> Bool) -> String {
        // The original always counts as taken.
        let taken: (String) -> Bool = { $0 == fileName || isTaken($0) }
        let dot = fileName.lastIndex(of: ".")
        let hasExtension = dot.map { $0 != fileName.startIndex } ?? false
        guard hasExtension, let dot else {
            return uniqueName(base: fileName, ext: nil, isTaken: taken)
        }
        return uniqueName(
            base: String(fileName[fileName.startIndex..<dot]),
            ext: String(fileName[fileName.index(after: dot)...]),
            isTaken: taken)
    }
}
