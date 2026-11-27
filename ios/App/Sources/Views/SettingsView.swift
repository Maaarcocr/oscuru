import OscuruCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var busy = false
    @State private var problem: String?
    @State private var confirmingDisconnect = false
    @State private var showingOtherWays = false
    /// Whether the camera offers frames: several RAW frames averaged into one shot.
    @AppStorage(Camera.framesKey) private var frames = false
    /// How much room the frames kept beside the photos take, once measured.
    @State private var keptFrames: Int64?
    @State private var confirmingDiscard = false
    @State private var exportingConversations = false
    @State private var exportedConversations: SharedFiles?
    @State private var exportProblem: String?

    private var account: Account { model.account }

    var body: some View {
        NavigationStack {
            Form {
                if account.isConnected {
                    connected
                } else {
                    signIn
                }
                Section {
                    NavigationLink {
                        ModelPicker()
                    } label: {
                        LabeledContent(L10n.settingsModel, value: account.models.first { $0.id == account.activeModel }?.name ?? account.activeModel)
                    }
                    .accessibilityIdentifier("settings.model")
                } footer: {
                    Text(L10n.settingsModelFooter)
                }
                Section {
                    Toggle(L10n.settingsFrames, isOn: $frames)
                        .accessibilityIdentifier("settings.frames")
                    // The frames of each shot are kept beside the photo, for the assistant to merge
                    // another way. This is where their room is given back.
                    if let size = keptFrames, size > 0 {
                        Button(L10n.settingsDiscardFrames(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), role: .destructive) {
                            confirmingDiscard = true
                        }
                        .accessibilityIdentifier("settings.discardFrames")
                        .alert(L10n.settingsDiscardFramesTitle, isPresented: $confirmingDiscard) {
                            Button(L10n.settingsDiscardFramesConfirm, role: .destructive) {
                                Task {
                                    await model.library.discardKeptFrames()
                                    keptFrames = await model.library.keptFramesSize()
                                }
                            }
                            Button(L10n.cancel, role: .cancel) {}
                        } message: {
                            Text(L10n.settingsDiscardFramesMessage)
                        }
                    }
                } header: {
                    Text(L10n.camera)
                } footer: {
                    Text(L10n.settingsFramesFooter)
                }
                .task { keptFrames = await model.library.keptFramesSize() }
                Section {
                    Button {
                        exportConversations()
                    } label: {
                        HStack {
                            Text(L10n.settingsExportConversations)
                            Spacer()
                            if exportingConversations { ProgressView() }
                        }
                    }
                    .disabled(exportingConversations)
                    .accessibilityIdentifier("settings.exportConversations")
                    .sheet(item: $exportedConversations) { files in
                        ShareSheet(urls: files.urls).presentationDetents([.medium, .large])
                    }
                    .alert(L10n.exportFailed, isPresented: Binding(get: { exportProblem != nil }, set: { if !$0 { exportProblem = nil } })) {
                        Button(L10n.ok, role: .cancel) {}
                    } message: {
                        Text(exportProblem ?? "")
                    }
                } footer: {
                    Text(L10n.settingsExportConversationsFooter)
                }
                if account.isConnected {
                    usage
                    Section {
                        Button(L10n.settingsDisconnect, role: .destructive) { confirmingDisconnect = true }
                            .accessibilityIdentifier("settings.disconnect")
                            .alert(L10n.settingsDisconnectTitle, isPresented: $confirmingDisconnect) {
                                Button(L10n.settingsDisconnect, role: .destructive) { account.disconnect() }
                                Button(L10n.cancel, role: .cancel) {}
                            } message: {
                                Text(L10n.settingsDisconnectMessage)
                            }
                    }
                }
                Section {
                    Text(L10n.privacyBody)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L10n.privacyTitle)
                }
            }
            .navigationTitle(L10n.settings)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingOtherWays) { OtherWaysToConnect() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
            .alert(L10n.settingsConnectFailed, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button(L10n.ok, role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            .task { await account.refresh() }
        }
    }

    /// Every conversation in one file, handed to the share sheet.
    private func exportConversations() {
        guard !exportingConversations else { return }
        exportingConversations = true
        Task {
            defer { exportingConversations = false }
            do {
                exportedConversations = SharedFiles([try await model.exportConversations()])
            } catch {
                exportProblem = error.localizedDescription
            }
        }
    }

    private var signIn: some View {
        Section {
            Button {
                attempt {
                    // When the page does not hand back a code, offer the other ways.
                    if try await !account.signIn(using: webAuthenticationSession) { showingOtherWays = true }
                }
            } label: {
                HStack {
                    Text(L10n.settingsSignIn)
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(busy)
            .accessibilityIdentifier("settings.signIn")
            Button(L10n.settingsOtherWays) { showingOtherWays = true }
                .accessibilityIdentifier("settings.other")
        } header: {
            Text(verbatim: "OpenRouter")
        } footer: {
            Text(L10n.settingsAccountFooter)
        }
    }

    private var connected: some View {
        Section {
            // One line: that it is connected, and with which key.
            LabeledContent(L10n.settingsConnected, value: account.keyInfo?.label ?? "")
                .accessibilityIdentifier("settings.connected")
        } header: {
            Text(verbatim: "OpenRouter")
        }
    }

    private var usage: some View {
        Section {
            LabeledContent(L10n.usageToday, value: UsageLedger.dollars(account.spentToday))
            LabeledContent(L10n.usageMonth, value: UsageLedger.dollars(account.spentThisMonth))
            LabeledContent(L10n.usageTotal, value: UsageLedger.dollars(account.spentInTotal))
        } header: {
            Text(L10n.usageTitle)
        } footer: {
            Text(L10n.usageFooter)
        }
    }

    private func attempt(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
            } catch let error as ModelError {
                problem = L10n.message(for: error)
            } catch {
                problem = String(describing: error)
            }
        }
    }
}

/// For when signing in does not come back to the app: a code from OpenRouter's page, or a key.
private struct OtherWaysToConnect: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code = ""
    @State private var key = ""
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Button(L10n.settingsGetCode) {
                    if let url = model.account.codeSignInURL() { openURL(url) }
                }
                TextField(L10n.settingsCodePlaceholder, text: $code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(connectWithCode)
                if hasCode { connectButton(action: connectWithCode) }
            } header: {
                Text(L10n.settingsCodeTitle)
            } footer: {
                Text(L10n.settingsCodeFooter)
            }

            Section {
                SecureField(L10n.settingsKeyPlaceholder, text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(connectWithKey)
                    .accessibilityIdentifier("settings.key")
                if hasKey {
                    connectButton(action: connectWithKey)
                        .accessibilityIdentifier("settings.connectKey")
                }
            } header: {
                Text(L10n.settingsKeyTitle)
            } footer: {
                Text(L10n.settingsKeyFooter)
            }
        }
        .animation(.default, value: hasCode)
        .animation(.default, value: hasKey)
        .navigationTitle(L10n.settingsOtherWays)
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.settingsConnectFailed, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button(L10n.ok, role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var hasCode: Bool { !code.trimmingCharacters(in: .whitespaces).isEmpty }
    private var hasKey: Bool { !key.trimmingCharacters(in: .whitespaces).isEmpty }

    private func connectWithCode() {
        guard hasCode else { return }
        attempt { try await model.account.finishSignIn(code: code) }
    }

    private func connectWithKey() {
        guard hasKey else { return }
        attempt { try await model.account.connect(key: key) }
    }

    /// Shown once there is something to connect with.
    private func connectButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(L10n.settingsConnect)
                Spacer()
                if busy { ProgressView() }
            }
        }
        .disabled(busy)
    }

    private func attempt(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                dismiss()
            } catch let error as ModelError {
                problem = L10n.message(for: error)
            } catch {
                problem = String(describing: error)
            }
        }
    }
}

private struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        let account = model.account
        let shown = account.models.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
        List {
            if account.models.isEmpty {
                Text(account.activeModel)
            }
            ForEach(shown) { entry in
                Button {
                    account.chosenModel = entry.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).foregroundStyle(.primary)
                            Text(L10n.modelPrice(id: entry.id, input: entry.promptPrice, output: entry.completionPrice))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.id == account.activeModel {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle(L10n.settingsModel)
        .navigationBarTitleDisplayMode(.inline)
    }
}
