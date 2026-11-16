import Combine
import Foundation
import Sparkle

/// Fork builds leave the update feed unset, so they never install an upstream binary.
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// False while a check or an update is already under way.
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController?

    var isConfigured: Bool { controller != nil }

    private init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Whether Sparkle checks the feed once a day in the background.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
