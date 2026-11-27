import SwiftUI

/// What the app is doing right now, refreshed every second: the connection, the processor and
/// memory, each photo's assistant, what the engine is drawing or waiting for, and the latest
/// events. Share sends all of it as a text file. For finding out why something is slow or stuck.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var shared: SharedFiles?
    @State private var problem: String?

    var body: some View {
        let diagnostics = Diagnostics.shared
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            List {
                lines(L10n.diagnosticsNow, diagnostics.now(model: model), empty: nil)
                lines(L10n.diagnosticsAssistants, diagnostics.assistants(model: model), empty: L10n.diagnosticsNoPhotos)
                lines(L10n.diagnosticsEngine, diagnostics.engine(model: model), empty: L10n.diagnosticsEngineIdle)
                lines(L10n.diagnosticsSlow, diagnostics.slow(model: model), empty: L10n.diagnosticsNothingSlow)
                Section {
                    ForEach(diagnostics.events.suffix(80).reversed()) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.date.formatted(date: .omitted, time: .standard))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(event.text).font(.caption)
                        }
                    }
                } header: {
                    Text(L10n.diagnosticsLog)
                }
            }
        }
        .navigationTitle(L10n.diagnostics)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    do {
                        shared = SharedFiles([try diagnostics.reportFile(model: model)])
                    } catch {
                        problem = error.localizedDescription
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(L10n.diagnosticsShare)
                .accessibilityIdentifier("diagnostics.share")
            }
        }
        .sheet(item: $shared) { files in
            ShareSheet(urls: files.urls).presentationDetents([.medium, .large])
        }
        .alert(L10n.exportFailed, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button(L10n.ok, role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func lines(_ title: String, _ lines: [Diagnostics.Line], empty: String?) -> some View {
        Section {
            if lines.isEmpty, let empty {
                Text(empty).foregroundStyle(.secondary)
            }
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.title).font(.subheadline.weight(.semibold))
                    Text(line.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(title)
        }
    }
}
