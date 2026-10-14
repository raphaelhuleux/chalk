import Foundation

/// One window configuration the chrome must be correct in. Shared vocabulary
/// for the invariant tests, the screenshot renderer, and contact sheets.
public struct UIState: Equatable, Hashable, Sendable {
    public enum WindowMode: String, CaseIterable, Sendable { case windowed, fullscreen }
    /// Raw values carry the id vocabulary ("sidebar"/"nosidebar"), which
    /// reads less ambiguously in the hyphenated id than "shown"/"hidden".
    public enum SidebarState: String, CaseIterable, Sendable { case shown = "sidebar", hidden = "nosidebar" }
    /// The persistent outline panel on the editor's trailing edge (⌘K).
    /// Same id vocabulary rule as `SidebarState`.
    public enum OutlineState: String, CaseIterable, Sendable { case shown = "outline", hidden = "nooutline" }
    /// Only the chrome-affecting editing modes (not typewriter or focus).
    public enum ChromeMode: String, CaseIterable, Sendable { case normal, zen }
    public enum Appearance: String, CaseIterable, Sendable { case light, dark }

    public let window: WindowMode
    public let sidebar: SidebarState
    public let outline: OutlineState
    public let mode: ChromeMode
    public let appearance: Appearance

    public init(window: WindowMode, sidebar: SidebarState,
                outline: OutlineState = .hidden,
                mode: ChromeMode, appearance: Appearance) {
        self.window = window
        self.sidebar = sidebar
        self.outline = outline
        self.mode = mode
        self.appearance = appearance
    }

    /// Stable, readable, and the label used everywhere: test failures and
    /// contact-sheet cells.
    public var id: String {
        [window.rawValue, sidebar.rawValue, outline.rawValue,
         mode.rawValue, appearance.rawValue].joined(separator: "-")
    }

    public init?(id: String) {
        // `omittingEmptySubsequences: false` so a stray hyphen yields an
        // empty part and fails, instead of a typo parsing as a different,
        // valid state.
        let parts = id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5,
              let window = WindowMode(rawValue: parts[0]),
              let sidebar = SidebarState(rawValue: parts[1]),
              let outline = OutlineState(rawValue: parts[2]),
              let mode = ChromeMode(rawValue: parts[3]),
              let appearance = Appearance(rawValue: parts[4]) else { return nil }
        self.init(window: window, sidebar: sidebar,
                  outline: outline, mode: mode, appearance: appearance)
    }

    /// The full cross product of every dimension. Exhaustive on purpose: an
    /// invariant checked on a sample can regress in the states nobody sampled.
    public static let matrix: [UIState] = WindowMode.allCases.flatMap { window in
        SidebarState.allCases.flatMap { sidebar in
            OutlineState.allCases.flatMap { outline in
                ChromeMode.allCases.flatMap { mode in
                    Appearance.allCases.map { appearance in
                        UIState(window: window, sidebar: sidebar,
                                outline: outline, mode: mode, appearance: appearance)
                    }
                }
            }
        }
    }
}

/// One user-level chrome toggle, as the transition matrix drives them.
/// Product rules live in `UIState.applying(_:)`.
public enum TransitionStep: Equatable, Sendable {
    /// Show or hide the Library column.
    case sidebar(Bool)
    /// Show or hide the outline panel.
    case outline(Bool)
    /// Enter or leave full screen.
    case window(UIState.WindowMode)
    /// Enter or leave zen.
    case zen(Bool)
}

extension UIState {
    /// The state a resting window ends in after `step`. Zen owns the chrome:
    /// zen(true) hides sidebar and outline, and opening either while in zen is
    /// refused (state unchanged).
    public func applying(_ step: TransitionStep) -> UIState {
        switch step {
        case .sidebar(let visible):
            if visible && mode == .zen { return self }
            return UIState(window: window,
                           sidebar: visible ? .shown : .hidden, outline: outline,
                           mode: mode, appearance: appearance)
        case .outline(let visible):
            if visible && mode == .zen { return self }
            return UIState(window: window,
                           sidebar: sidebar, outline: visible ? .shown : .hidden,
                           mode: mode, appearance: appearance)
        case .window(let windowMode):
            return UIState(window: windowMode,
                           sidebar: sidebar, outline: outline, mode: mode, appearance: appearance)
        case .zen(let on):
            return UIState(window: window,
                           sidebar: on ? .hidden : sidebar,
                           outline: on ? .hidden : outline,
                           mode: on ? .zen : .normal, appearance: appearance)
        }
    }
}
