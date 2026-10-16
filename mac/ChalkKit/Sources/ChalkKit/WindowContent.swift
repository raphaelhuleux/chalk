import Foundation

/// What a new editor window opens with.
public enum WindowContent: Equatable {
    case restoreSession(WindowSession)
    case openEmpty
    case openWelcome
}
