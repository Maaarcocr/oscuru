import OscuruCore
import SwiftUI

/// Where the person says what they want. Beside the words: their styles, to try on this photo or
/// to save its look as one; and Stop while the assistant works.
struct Composer: View {
    @Environment(AppModel.self) private var model
    let editor: PhotoEditor
    @FocusState.Binding var focused: Bool
    @State private var draft = ""
    @State private var showingStyles = false
    @State private var showingSettings = false
    @State private var showingPrompts = false

    private var isConnected: Bool { model.account.isConnected }

    var body: some View {
        VStack(spacing: 10) {
            if showingStyles {
                StyleStrip(editor: editor)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if isConnected, !editor.hasInstructions, !editor.isWorking {
                prompts
            }
            HStack(alignment: .bottom, spacing: 8) {
                stylesButton
                if isConnected {
                    TextField(editor.isWorking ? L10n.composerWhileWorking : L10n.composerPlaceholder, text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                        .accessibilityIdentifier("composer.field")
                    action
                } else {
                    Button {
                        showingSettings = true
                    } label: {
                        Text(L10n.composerConnect).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityIdentifier("composer.connect")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.black)
        .animation(.snappy, value: showingStyles)
        .onChange(of: focused) { _, typing in
            if typing { showingStyles = false }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingPrompts) { PromptsView() }
    }

    /// The person's prompts, for a first instruction: a tap sends one's words. The first button is
    /// where they are changed, added to and deleted.
    private var prompts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    focused = false
                    showingPrompts = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel(L10n.promptsEdit)
                .accessibilityIdentifier("prompts.edit")
                ForEach(model.prompts.prompts) { prompt in
                    Button {
                        send(prompt.text)
                    } label: {
                        // Its title, or without one its words (a long one shows how it starts).
                        Text(verbatim: prompt.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: 240)
                    }
                    .accessibilityHint(Text(verbatim: prompt.title.isEmpty ? "" : prompt.text))
                    .accessibilityIdentifier("prompts.item")
                }
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.white)
            .padding(.horizontal, 16)
        }
    }

    /// Opens the styles above the composer, and closes them again.
    private var stylesButton: some View {
        Button {
            focused = false
            showingStyles.toggle()
        } label: {
            Image(systemName: "camera.filters")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(showingStyles ? Color.black : Color.white)
                .frame(width: 42, height: 42)
                .background(showingStyles ? Color.accentColor : Color(white: 0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.styles)
        .accessibilityIdentifier("composer.styles")
    }

    /// Send, or stop while the assistant is working and there is nothing to send. Words sent while
    /// it works join its work between two steps.
    @ViewBuilder
    private var action: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if editor.isWorking, empty {
            Button {
                editor.stop()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .frame(height: 42)
            }
            .accessibilityLabel(L10n.stop)
            .accessibilityIdentifier("composer.stop")
        } else {
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(empty ? Color(white: 0.3) : Color.accentColor)
                    .frame(height: 42)
            }
            .disabled(empty)
            .accessibilityLabel(L10n.send)
            .accessibilityIdentifier("composer.send")
        }
    }

    private func send(_ text: String) {
        draft = ""
        focused = false
        showingStyles = false
        editor.send(text)
    }
}

/// The person's styles, each tried on this photo: tap one to put it on. The first tile saves the
/// photo's own look as a style.
private struct StyleStrip: View {
    @Environment(AppModel.self) private var model
    let editor: PhotoEditor
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    name = ""
                    naming = true
                } label: {
                    StyleTile(title: L10n.saveLook, isNew: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("styles.save")
                ForEach(model.styles) { style in
                    Button {
                        Task { await editor.apply(style) }
                    } label: {
                        // Tried on the photo as it is now, so the tile shows what a tap would give.
                        StyleTile(title: style.name, version: "\(model.styleStore.version(of: style.id)) \(editor.stateVersion)") { await editor.preview(of: style) }
                    }
                    .buttonStyle(.plain)
                    .disabled(editor.isWorking)
                    .accessibilityLabel(style.name)
                    .accessibilityIdentifier("styles.item")
                }
                if model.styles.isEmpty {
                    Text(L10n.stylesEmpty)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 210, height: StyleTile.side, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
        }
        .styleNameAlert(L10n.saveLook, isPresented: $naming, name: $name) {
            let wanted = name
            Task { _ = await editor.saveStyle(named: wanted) }
        }
    }
}
