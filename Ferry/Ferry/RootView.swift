import SwiftUI
import UIKit

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(uiColor: .systemBackground), Color.accentColor.opacity(0.08)],
                           startPoint: .top, endPoint: .bottomTrailing).ignoresSafeArea()
            if model.phase == .setup || model.phase == .connecting { AccessView(model: model) }
            else { TimelineView(model: model) }
        }
        .task { await model.start() }
    }
}

private struct AccessView: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Field?
    private enum Field: Hashable { case server, name, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)
                // White paper-plane glyph, always shown on a dark tile so it
                // reads identically in light and dark mode.
                Image("PlaneLogo")
                    .resizable().scaledToFit()
                    .padding(18)
                    .frame(width: 92, height: 92)
                    .background(Color(red: 0.06, green: 0.09, blue: 0.16), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Ferry").font(.largeTitle.bold())
                    Text("Your clipboard and files, across your own devices.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                VStack(spacing: 16) {
                    VStack(spacing: 16) {
                        TextField("Server address", text: $model.serverAddress)
                            .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().focused($focused, equals: .server)
                            .accessibilityIdentifier("server-address")
                        TextField("Device name", text: $model.deviceName)
                            .focused($focused, equals: .name).accessibilityIdentifier("device-name")
                        SecureField("Access password (if enabled)", text: $model.accessPassword)
                            .textContentType(.password)
                            .focused($focused, equals: .password).accessibilityIdentifier("access-password")
                        if let message = model.statusMessage {
                            Text(message).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("access-error")
                        }
                        Button { focused = nil; Task { await model.connect() } } label: {
                            HStack { if model.phase == .connecting { ProgressView() }; Text("Connect").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.phase == .connecting)
                        .accessibilityIdentifier("connect-device")
                    }
                    .padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

                    discovery
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var discovery: some View {
        VStack(spacing: 12) {
            Button {
                Task { await model.discover() }
            } label: {
                HStack {
                    if model.isDiscovering { ProgressView() }
                    else { Image(systemName: "dot.radiowaves.left.and.right") }
                    Text(model.isDiscovering ? "Scanning…" : "Find PC on network")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(model.isDiscovering)
            .accessibilityIdentifier("find-pc")

            if !model.discovered.isEmpty {
                VStack(spacing: 8) {
                    ForEach(model.discovered) { server in
                        Button {
                            model.selectDiscovered(server)
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer").foregroundStyle(.cyan)
                                Text(server.origin).font(.subheadline.monospaced())
                                Spacer()
                            }
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("discovered-server")
                    }
                }
            }
        }
    }
}
