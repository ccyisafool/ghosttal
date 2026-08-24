import Sparkle
import Cocoa
import Combine
import SwiftUI

/// Update UI retained from upstream while Ghosttal's update channel is offline.
///
/// This controller wraps SPUStandardUpdaterController to provide a simpler interface
/// for managing updates with Ghostty's custom driver and delegate. It handles
/// initialization, starting the updater, and provides the check for updates action.
class UpdateController {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    /// True if we're installing an update triggered manually.
    var shouldTerminateWithoutWarning: Bool {
        viewModel.state.shouldTerminateWithoutWarning
    }

    /// Initialize a new update controller.
    init() {
        let hostBundle = Bundle.main
        self.userDriver = UpdateDriver(
            viewModel: .init(),
            hostBundle: hostBundle)
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: userDriver
        )
    }

    /// Ghosttal deliberately does not start Sparkle until it has its own signed feed.
    func startUpdater() {
        // Intentionally disabled. Never point a Ghosttal build at Ghostty's feed.
    }

    /// Check for updates.
    ///
    /// This is typically connected to a menu item action.
    func checkForUpdates() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Ghosttal updates are not enabled yet"
        alert.informativeText = "This sanity-check build never contacts Ghostty's update service. Ghosttal will gain its own signed update channel later."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct InstallingAccessoryView: View {
    let installing: UpdateState.Installing

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Restart Required")
                    .font(.system(size: 13, weight: .semibold))

                Text("The update is ready. Please restart the application to complete the installation.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let item = installing.appcastItem, let releaseNotesURL = installing.releaseNotes?.url {
                    VStack(alignment: .leading, spacing: 4) {
                        Link(destination: releaseNotesURL) {
                            HStack(spacing: 6) {
                                Text("Version:")
                                    .foregroundColor(.secondary)
                                    .frame(width: 60, alignment: .trailing)
                                Text(item.displayVersionString)
                            }
                            .font(.system(size: 11))
                        }

                        if let date = item.date {
                            HStack(spacing: 6) {
                                Text("Released:")
                                    .foregroundColor(.secondary)
                                    .frame(width: 60, alignment: .trailing)
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                            }
                            .font(.system(size: 11))
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }
}
