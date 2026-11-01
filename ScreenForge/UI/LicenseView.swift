import SwiftUI

struct LicenseView: View {
    @ObservedObject private var manager = LicenseManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("License")
                .font(.system(size: 18, weight: .bold))
            Text(manager.state.message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if manager.state.isConfigured {
                SecureField("Paste your license key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                HStack {
                    Button("Activate") {
                        manager.activate(key: key)
                        key = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.isEmpty)
                    if manager.state.license != nil {
                        Button("Deactivate", role: .destructive) {
                            manager.deactivate()
                        }
                    }
                }
            } else {
                Text("Set SCREENFORGE_LICENSE_PUBLIC_KEY (base64 Ed25519 public key) to enable offline license verification. Keys are stored in the macOS Keychain.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 420, height: 260)
    }
}
