import Foundation

/// What the tester did with a crash prompt.
public enum CrashPromptOutcome: Equatable, Sendable {
    case sent
    /// "No thanks", the close box, or a timeout. A prompt that times out
    /// counts as refused, or an ignorable ask could repeat forever.
    case declined
}

/// When Chalk may ask about a crash. Kept in one place, out of the views, so
/// the prompt stays turnable off. Three refusals end it for good; nothing the
/// app does re-enables the Settings toggle.
public enum CrashPromptPolicy {
    public static let declineLimit = 3

    public static func shouldPrompt(verdict: LaunchVerdict,
                                    declines: Int,
                                    userOptedOut: Bool) -> Bool {
        guard !userOptedOut else { return false }
        guard case .abnormal = verdict else { return false }
        return declines < declineLimit
    }

    /// The count to store after an outcome, clamped at both ends since a
    /// stored preference can hold anything.
    public static func declines(after outcome: CrashPromptOutcome,
                                from current: Int) -> Int {
        switch outcome {
        // Sending is not opting out; don't retire the prompt for a helper.
        case .sent: return 0
        case .declined: return min(max(current, 0) + 1, declineLimit)
        }
    }
}
