import AppKit
import ChalkKit

/// The hosted-test window, and the handful of UIKit-named conveniences the
/// ported suites read (`isHidden`, `rootViewController`, `layoutIfNeeded`),
/// so a test reads the same on both shells. The window is a real titled,
/// full-size-content window like the app's; `isReleasedWhenClosed` is off
/// because the tests hold the reference.
extension NSWindow {
    static func hostedForTesting(frame: CGRect) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }

    var isHidden: Bool {
        get { !isVisible }
        set { newValue ? orderOut(nil) : orderFrontRegardless() }
    }

    /// Assigning a content view controller resizes the window to the
    /// controller's view (zero for a freshly loaded one, clamped to the
    /// minimum size); the hosted size is put back, as the app's window
    /// controller does.
    var rootViewController: NSViewController? {
        get { contentViewController }
        set {
            let size = contentView?.frame.size ?? .zero
            contentViewController = newValue
            if newValue != nil, size != .zero { setContentSize(size) }
        }
    }

    func addSubview(_ view: NSView) {
        contentView?.addSubview(view)
    }

    func layoutIfNeeded() {
        contentView?.layoutSubtreeIfNeeded()
    }

    func setNeedsLayout() {
        contentView?.needsLayout = true
    }

    /// Resize the content, the way the Catalyst tests set `window.frame`.
    var frame: CGRect {
        get { contentView?.frame ?? .zero }
        set { setContentSize(newValue.size) }
    }
}

extension NSView {
    func layoutIfNeeded() { layoutSubtreeIfNeeded() }
    func setNeedsLayout() { needsLayout = true }
    var alpha: CGFloat {
        get { alphaValue }
        set { alphaValue = newValue }
    }
}

extension NSViewController {
    /// The window this controller's view sits in.
    var hostingWindow: NSWindow? { view.window }
}

enum TestAccessibility {
    /// Reduce Motion, as the shell reads it.
    static var isReduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
