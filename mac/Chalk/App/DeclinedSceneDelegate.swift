import UIKit
import os

/// The delegate for session roles Chalk does not support (`SceneRouting
/// .declined`: anything but a window).
///
/// `configurationForConnecting` must return a configuration, so declining
/// means: connect, create no `UIWindow`, and ask the system to destroy the
/// session. Not routed to `SceneDelegate`: that would tick
/// `applicationSceneConnectOrdinal` (stealing the Welcome slot from the real
/// window) and add a scene the launch settle sweep cannot see, since it filters
/// on `.windowApplication`.
final class DeclinedSceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// Required by `UIWindowSceneDelegate`; stays nil because a declined scene
    /// never gets a window.
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        Logger(subsystem: "com.huleux.chalk", category: "scene")
            .info("declining scene session with role \(session.role.rawValue, privacy: .public)")
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
    }
}
