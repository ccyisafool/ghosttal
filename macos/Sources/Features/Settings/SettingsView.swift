import SwiftUI

struct SettingsView: View {
    // We need access to our app delegate to know if we're quitting or not.
    @EnvironmentObject private var appDelegate: AppDelegate

    var body: some View {
        HStack {
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)

            VStack(alignment: .leading) {
                Text("Configuration").font(.title)
                Text("Ghosttal reads your Ghostty config first, then applies its own overlay. " +
                     "Use Open Configuration to edit Ghosttal-only motion settings, then reload.")
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
            }
        }
        .padding()
        .frame(minWidth: 500, maxWidth: 500, minHeight: 156, maxHeight: 156)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
