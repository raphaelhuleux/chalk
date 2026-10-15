import UIKit
import ChalkKit

extension UIWindow {
    /// A window on the test host's scene, sized to `frame`. Replaces `UIWindow(frame:)`, deprecated
    /// in iOS 26, which also leaves the window without a scene. Nonisolated so XCTest's synchronous
    /// `setUp` can call it; tests run on the main thread.
    static func hostedForTesting(frame: CGRect) -> UIWindow {
        MainActor.assumeIsolated {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else {
                preconditionFailure("no scene to host in")
            }
            let window = UIWindow(windowScene: scene)
            window.frame = frame
            return window
        }
    }
}
