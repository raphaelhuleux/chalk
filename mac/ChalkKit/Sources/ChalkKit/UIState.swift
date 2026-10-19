import Foundation

/// One window configuration the chrome must be correct in: the invariant
/// and transition matrices' vocabulary.
public struct UIState: Equatable, Hashable, Sendable {
    public enum WindowMode: String, CaseIterable, Sendable { case windowed, fullscreen }
    /// Raw values carry the id vocabulary ("sidebar"/"nosidebar"), which
    /// reads less ambiguously in the hyphenated id than "shown"/"hidden".
    public enum SidebarState: String, CaseIterable, Sendable { case shown = "sidebar", hidden = "nosidebar" }
    /// The editor's trailing slot: closed, the persistent outline (⌘K), or
    /// the compiled PDF (⌥⌘P) in the same frame. Same id vocabulary rule as
    /// `SidebarState`.
    public enum OutlineState: String, CaseIterable, Sendable {
        case shown = "outline", hidden = "nooutline", pdf
    }
    /// Only the chrome-affecting editing modes (not typewriter or focus).
    public enum ChromeMode: String, CaseIterable, Sendable { case normal, zen }
    /// One editor pane, or two side by side (⌘\).
    public enum SplitState: String, CaseIterable, Sendable { case single, split }
    public enum Appearance: String, CaseIterable, Sendable { case light, dark }

    public let window: WindowMode
    public let sidebar: SidebarState
    public let outline: OutlineState
    public let mode: ChromeMode
    public let split: SplitState
    public let appearance: Appearance

    public init(window: WindowMode, sidebar: SidebarState,
                outline: OutlineState = .hidden,
                mode: ChromeMode, split: SplitState = .single, appearance: Appearance) {
        self.window = window
        self.sidebar = sidebar
        self.outline = outline
        self.mode = mode
        self.split = split
        self.appearance = appearance
    }

    /// Stable and readable: the label every test failure names a state by. Appearance stays
    /// last: the light/dark sibling check drops the final component.
    public var id: String {
        [window.rawValue, sidebar.rawValue, outline.rawValue,
         mode.rawValue, split.rawValue, appearance.rawValue].joined(separator: "-")
    }

    /// The full cross product of every dimension. Exhaustive on purpose: an
    /// invariant checked on a sample can regress in the states nobody sampled.
    public static let matrix: [UIState] = WindowMode.allCases.flatMap { window in
        SidebarState.allCases.flatMap { sidebar in
            OutlineState.allCases.flatMap { outline in
                ChromeMode.allCases.flatMap { mode in
                    SplitState.allCases.flatMap { split in
                        Appearance.allCases.map { appearance in
                            UIState(window: window, sidebar: sidebar, outline: outline,
                                    mode: mode, split: split, appearance: appearance)
                        }
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
    /// Show the outline in the trailing slot, or close the slot (whatever it shows).
    case outline(Bool)
    /// Enter or leave full screen.
    case window(UIState.WindowMode)
    /// Enter or leave zen.
    case zen(Bool)
    /// Show one editor pane or two.
    case split(Bool)
}

extension UIState {
    /// The state a resting window ends in after `step`. Zen owns the chrome:
    /// zen(true) hides sidebar and outline, and opening either while in zen is
    /// refused (state unchanged). The split is documents, not chrome, so zen
    /// leaves it alone.
    public func applying(_ step: TransitionStep) -> UIState {
        switch step {
        case .sidebar(let visible):
            if visible && mode == .zen { return self }
            return UIState(window: window,
                           sidebar: visible ? .shown : .hidden, outline: outline,
                           mode: mode, split: split, appearance: appearance)
        case .outline(let visible):
            if visible && mode == .zen { return self }
            return UIState(window: window,
                           sidebar: sidebar, outline: visible ? .shown : .hidden,
                           mode: mode, split: split, appearance: appearance)
        case .window(let windowMode):
            return UIState(window: windowMode, sidebar: sidebar, outline: outline,
                           mode: mode, split: split, appearance: appearance)
        case .zen(let on):
            return UIState(window: window,
                           sidebar: on ? .hidden : sidebar,
                           outline: on ? .hidden : outline,
                           mode: on ? .zen : .normal, split: split, appearance: appearance)
        case .split(let on):
            return UIState(window: window, sidebar: sidebar, outline: outline,
                           mode: mode, split: on ? .split : .single, appearance: appearance)
        }
    }
}
