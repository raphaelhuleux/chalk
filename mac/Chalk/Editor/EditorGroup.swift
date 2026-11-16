import AppKit

/// One side-by-side tab group (VS Code's editor group, Obsidian's tab group): its own tabs in
/// strip order, the one it shows, and the pane that shows it. A tab belongs to exactly one group;
/// a group is never empty while another group exists.
final class EditorGroup {
    let id = UUID()
    var tabs: [Tab] = []
    /// What this group's pane shows; nil only for the last group once its last tab closed.
    var activeTab: Tab?
    let pane = FlippedView()

    func contains(_ tab: Tab) -> Bool { tabs.contains { $0 === tab } }
    func index(of tab: Tab) -> Int? { tabs.firstIndex { $0 === tab } }
}

/// One group's strip snapshot.
struct TabGroupItem: Equatable {
    let id: UUID
    let tabs: [TabItem]
    /// The group the shell's commands act on.
    let isFocused: Bool
}
