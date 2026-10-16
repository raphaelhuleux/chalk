import Foundation

public extension URL {
    /// The path two spellings of one file share: `/var` vs `/private/var` (document picker vs file
    /// tree), `..` segments and a directory's trailing slash all collapse to the same string.
    var fileIdentity: String {
        standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Whether the item on disk is a directory; the URL's own spelling decides when it cannot be read.
    var isDirectoryOnDisk: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? hasDirectoryPath
    }
}
