import Combine
import MetalKit
import SwiftUI
import UIKit

@main
struct LightmappingApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}

/// Holds the open project's engine so the external display scene can find it.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var engine: Engine?
    @Published var receiverMode = false
    /// Pixel size of a connected HDMI/AirPlay screen, if any.
    @Published var externalScreenSize: CGSize?

    func open(_ project: Project) {
        engine?.saveNow()
        let e = Engine(project: project)
        e.setExternalDisplay(size: externalScreenSize)
        engine = e
    }

    func close() {
        engine?.stopTimeline()
        engine?.saveNow()
        engine = nil
    }

    func externalDisplayChanged(_ size: CGSize?) {
        externalScreenSize = size
        engine?.setExternalDisplay(size: size)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if session.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "External Display", sessionRole: session.role)
            config.delegateClass = ExternalDisplaySceneDelegate.self
            return config
        }
        // No delegate class: SwiftUI supplies its own for the main window.
        return UISceneConfiguration(name: nil, sessionRole: session.role)
    }
}

/// Fills a connected projector (HDMI adapter or AirPlay) with the clean output while the
/// device screen keeps the editing controls.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var metalView: MTKView?
    private var observation: AnyCancellable?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let vc = UIViewController()
        let view = MTKView(frame: windowScene.screen.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.backgroundColor = .black
        vc.view = view
        window.rootViewController = vc
        window.isHidden = false
        self.window = window
        metalView = view

        let screen = windowScene.screen
        let pixelSize = CGSize(width: screen.nativeBounds.width, height: screen.nativeBounds.height)
        Task { @MainActor in
            let model = AppModel.shared
            model.externalDisplayChanged(pixelSize)
            // Attaches now, and again whenever a different project is opened.
            observation = model.$engine.sink { [weak view] engine in
                guard let view else { return }
                engine?.attach(view)
            }
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        Task { @MainActor in
            if let metalView { AppModel.shared.engine?.detach(metalView) }
            AppModel.shared.externalDisplayChanged(nil)
        }
        window = nil
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.receiverMode {
                ReceiverView()
            } else if let engine = model.engine {
                EditorView()
                    .environmentObject(engine)
                    .id(ObjectIdentifier(engine))
            } else {
                ProjectBrowserView()
            }
        }
    }
}
