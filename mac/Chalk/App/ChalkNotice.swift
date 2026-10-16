import AppKit
import ChalkKit
import os

private let noticeLog = Logger(subsystem: "com.huleux.chalk", category: "notice")

extension NSViewController {
    /// End the sheet this controller is the content of (Done, Esc). A plain
    /// window closes instead.
    @objc func endChalkSheet() {
        guard let window = view.window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    /// A one-button notice as a sheet on this controller's window. Logged
    /// instead when there is no window (tests, a screen not yet shown).
    func presentChalkNotice(title: String?, message: String) {
        guard let window = view.window else {
            noticeLog.notice("notice without a window: \(title ?? message, privacy: .public)")
            return
        }
        let alert = NSAlert()
        alert.messageText = title ?? message
        if title != nil { alert.informativeText = message }
        alert.addButton(withTitle: "OK")
        if let sheet = window.attachedSheet {
            // A sheet cannot carry a second sheet; the notice goes on top of it.
            alert.beginSheetModal(for: sheet)
        } else {
            alert.beginSheetModal(for: window)
        }
    }
}

/// Report a Problem, Privacy and the About screens as a sheet on an app
/// window: the screen under a Done button, pinned to the app's forced
/// appearance (a sheet window would otherwise follow the system's), with Esc
/// as Done. The completion is how focus returns to the editor.
enum HelpSheet {
    /// The screen's natural size; the window is sized to it, floored for the
    /// text-heavy screens.
    static let size = NSSize(width: 560, height: 640)

    @discardableResult
    static func present(_ screen: NSViewController, over window: NSWindow,
                        onDismiss: @escaping () -> Void) -> NSWindow {
        let sheet = makeWindow(for: HelpSheetHostViewController(screen: screen), size: size)
        sheet.contentMinSize = NSSize(width: 420, height: 360)
        sheet.appearance = Preferences.themePreference.appearance
        window.beginSheet(sheet) { _ in onDismiss() }
        return sheet
    }

    /// A titled, resizable window around `content`, sized to `size`, titled
    /// after the content, kept alive by its owner rather than by being shown.
    static func makeWindow(for content: NSViewController, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = content.title ?? ""
        window.contentViewController = content
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        return window
    }
}

/// The sheet's frame: the screen above a bar with Done.
final class HelpSheetHostViewController: NSViewController {
    let screen: NSViewController

    init(screen: NSViewController) {
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
        title = screen.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = ChromeToneView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(screen)
        screen.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(screen.view)

        let bar = FlippedView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        let rule = FlippedView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor.chalkBorderHard.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        let done = NSButton(title: "Done", target: self, action: #selector(endChalkSheet))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(rule)
        bar.addSubview(done)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            screen.view.topAnchor.constraint(equalTo: view.topAnchor),
            screen.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            screen.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            screen.view.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52),
            rule.topAnchor.constraint(equalTo: bar.topAnchor),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            done.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            done.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    /// Esc closes, matching the palettes.
    override func cancelOperation(_ sender: Any?) { endChalkSheet() }
}
