#if canImport(UIKit)
import HaloDesignSystem
import CoreLocation
import HaloDomain
import MapKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The panel under the composer: the expression panel (GIFs · Stickers · Emoji) or attachments
/// (docs/features/COMPOSER_PANELS.md §4–§7). Panels never touch the composer: they insert or send through the view model.
struct ComposerPanelContent: View {
    let panel: ComposerPanel
    let model: TimelineViewModel
    let input: ComposerInputController
    let gifPanel: (@MainActor () -> AnyView)?
    let stickerPanel: (@MainActor () -> AnyView)?
    @Binding var choosingFile: Bool

    var body: some View {
        switch panel {
        case .expression:
            ExpressionPanel(model: model, input: input, gifPanel: gifPanel, stickerPanel: stickerPanel)
        case .attachments:
            AttachmentPanel(model: model, input: input, choosingFile: $choosingFile)
        }
    }
}

// MARK: - Expression panel

/// GIFs, stickers and emoji behind one floating tab pill; the last tab is remembered, as in the system keyboard.
struct ExpressionPanel: View {
    enum Tab: String, Hashable, Identifiable {
        case gifs, stickers, emoji
        var id: String { rawValue }
    }

    let model: TimelineViewModel
    let input: ComposerInputController
    let gifPanel: (@MainActor () -> AnyView)?
    let stickerPanel: (@MainActor () -> AnyView)?
    /// Opens on Emoji the first time, then on the last tab used (a new key, so earlier builds' choice doesn't carry over).
    @AppStorage("halo.composer.expressionTab.v2") private var stored = Tab.emoji.rawValue

    /// Emoji · GIFs · Stickers (founder, 2026-11-23).
    private var tabs: [Tab] {
        var tabs: [Tab] = [.emoji]
        if gifPanel != nil { tabs.append(.gifs) }
        if stickerPanel != nil { tabs.append(.stickers) }
        return tabs
    }

    private var tab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: stored).flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first ?? .emoji },
            set: { stored = $0.rawValue }
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab.wrappedValue {
                case .gifs: gifPanel?()
                case .stickers: stickerPanel?()
                case .emoji: EmojiPanel(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // The pill hides while a panel's search field has the keyboard up.
            if tabs.count > 1, !input.state.panelSearching {
                HStack(alignment: .center) {
                    PanelTabPill(
                        items: tabs.map { tab in
                            switch tab {
                            case .gifs: .init(tab: tab, title: "GIFs", identifier: "panel-tab-gifs")
                            case .stickers: .init(tab: tab, title: "Stickers", identifier: "panel-tab-stickers")
                            case .emoji: .init(tab: tab, title: "Emoji", identifier: "panel-tab-emoji")
                            }
                        },
                        selection: tab
                    )
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    if tab.wrappedValue == .emoji {
                        ComposerCircleButton(systemImage: "delete.left", label: "Delete") { model.deleteBackward() }
                            .padding(.trailing, HaloSpacing.m)
                            .accessibilityIdentifier("emoji-delete")
                    }
                }
                .padding(.bottom, HaloSpacing.s)
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Emoji panel

/// The full emoji set (`EmojiKeyboard`): recently used first, a category strip to jump, and search. Tapping inserts at the
/// end of the draft and keeps the panel open.
struct EmojiPanel: View {
    let model: TimelineViewModel
    @State private var search = ""

    private let columns = [GridItem(.adaptive(minimum: 42), spacing: HaloSpacing.xs)]

    private static func symbol(_ section: EmojiKeyboard.Section) -> String {
        switch section {
        case .smileys: "face.smiling"
        case .nature: "leaf"
        case .food: "fork.knife"
        case .activity: "soccerball"
        case .travel: "car"
        case .objects: "lightbulb"
        case .symbols: "heart"
        case .flags: "flag"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelSearchField(text: $search, placeholder: "Search emoji", identifier: "emoji-search")
                .padding(.horizontal, HaloSpacing.m)
                .padding(.top, HaloSpacing.s)
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                if search.trimmingCharacters(in: .whitespaces).isEmpty {
                    categoryStrip(proxy)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HaloSpacing.s) {
                        if search.trimmingCharacters(in: .whitespaces).isEmpty {
                            if !model.recentEmoji.isEmpty {
                                section("Recently used", model.recentEmoji).id("recent")
                            }
                            ForEach(EmojiKeyboard.Section.allCases) { section in
                                self.section(section.rawValue, EmojiKeyboard.emoji(in: section)).id(section.id)
                            }
                        } else {
                            let hits = EmojiKeyboard.search(search)
                            if hits.isEmpty {
                                Text("No emoji found").font(HaloTypography.meta).foregroundStyle(HaloColor.textSecondary)
                                    .frame(maxWidth: .infinity).padding(.top, HaloSpacing.l)
                            } else {
                                grid(hits)
                            }
                        }
                    }
                    .padding(.horizontal, HaloSpacing.m)
                    .padding(.bottom, 72)
                }
                .scrollDismissesKeyboard(.immediately)
                }
            }
        }
    }

    private func categoryStrip(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            if !model.recentEmoji.isEmpty {
                categoryButton("clock", label: "Recently used") { proxy.scrollTo("recent", anchor: .top) }
            }
            ForEach(EmojiKeyboard.Section.allCases) { section in
                categoryButton(Self.symbol(section), label: section.rawValue) { proxy.scrollTo(section.id, anchor: .top) }
            }
        }
        .padding(.horizontal, HaloSpacing.s)
    }

    private func categoryButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(HaloTypography.body)
                .foregroundStyle(HaloColor.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func section(_ title: String, _ emoji: [String]) -> some View {
        VStack(alignment: .leading, spacing: HaloSpacing.xs) {
            Text(title.uppercased())
                .font(HaloTypography.captionEmphasis)
                .foregroundStyle(HaloColor.textSecondary)
                .padding(.top, HaloSpacing.s)
                .accessibilityAddTraits(.isHeader)
            grid(emoji)
        }
    }

    private func grid(_ emoji: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: HaloSpacing.xs) {
            ForEach(emoji, id: \.self) { item in
                Button { model.insertEmoji(item) } label: {
                    Text(item)
                        .font(HaloTypography.title)
                        .frame(minWidth: 42, minHeight: 42)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(EmojiKeyboard.name(of: item) ?? item)
            }
        }
    }
}

// MARK: - Attachment panel

/// Telegram's attach sheet as a panel (COMPOSER_PANELS §7, D100): Gallery · File · Location · Poll behind a floating pill.
/// It always opens on Gallery.
struct AttachmentPanel: View {
    enum Tab: String, Hashable, Identifiable {
        case gallery, file, location, poll, article
        var id: String { rawValue }
    }

    let model: TimelineViewModel
    let input: ComposerInputController
    @Binding var choosingFile: Bool
    @State private var tab = Tab.gallery

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .gallery: GalleryTab(model: model)
                case .file: FileTab(model: model, choosingFile: $choosingFile)
                case .location: LocationTab(model: model, input: input)
                case .poll: PollTab(model: model, input: input)
                case .article: ArticleTab(model: model, input: input)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            PanelTabPill(
                items: [
                    .init(tab: .gallery, title: "Gallery", systemImage: "photo.on.rectangle", identifier: "attach-tab-gallery"),
                    .init(tab: .file, title: "File", systemImage: "doc", identifier: "attach-tab-file"),
                    .init(tab: .location, title: "Location", systemImage: "mappin.and.ellipse", identifier: "attach-tab-location"),
                    .init(tab: .poll, title: "Poll", systemImage: "chart.bar.xaxis", identifier: "attach-tab-poll"),
                    .init(tab: .article, title: "Article", systemImage: "doc.richtext", identifier: "attach-tab-article"),
                ],
                selection: $tab,
                stacked: true
            )
            .padding(.bottom, HaloSpacing.s)
        }
    }
}

/// Streams a picked Photos video straight to a temporary disk file without loading it into memory (M19-5, M20-3).
private struct PickedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("halo-picked-video-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}

/// An inline, privacy-preserving system Photos picker (no photo-library permission needed); checked photos and videos
/// join the composer's pending strip (with captions on send, M20-3), unchecked ones leave it.
private struct GalleryTab: View {
    private struct AttachedItem: Equatable {
        let id: String
        let isVideo: Bool
    }

    let model: TimelineViewModel
    @State private var selection: [PhotosPickerItem] = []
    /// Picker item identifiers in the order their items were attached, to mirror deselection.
    @State private var attached: [AttachedItem] = []

    private var remaining: Int {
        let totalPending = model.pendingPhotos.count + model.pendingVideos.count
        return max(1, TimelineViewModel.maxPendingPhotos - totalPending + attached.count)
    }

    var body: some View {
        Group {
            if model.canSendImages || model.canSendVideos {
                PhotosPicker(
                    selection: $selection,
                    maxSelectionCount: remaining,
                    selectionBehavior: .continuousAndOrdered,
                    matching: model.canSendVideos ? .any(of: [.images, .videos]) : .images,
                    preferredItemEncoding: .current,
                    photoLibrary: .shared()
                ) {
                    Text("Photos & Videos")
                }
                .photosPickerStyle(.inline)
                .photosPickerDisabledCapabilities([.stagingArea, .selectionActions])
                .photosPickerAccessoryVisibility(.hidden, edges: .all)
                .accessibilityIdentifier("photo-button")
            } else {
                ContentUnavailableView("Media can't be sent here", systemImage: "photo.badge.exclamationmark")
            }
        }
        .onChange(of: selection) { _, new in Task { await sync(to: new) } }
        .onChange(of: model.pendingPhotos.count + model.pendingVideos.count) { _, count in
            // Sent, or an item removed from the strip: the picker's checkmarks can no longer be matched, so they reset.
            if count < attached.count {
                attached = []
                selection = []
            }
        }
    }

    /// Mirrors the picker's selection into pending photos and videos: newly checked items are prepared and attached
    /// in order, unchecked ones are removed again.
    private func sync(to new: [PhotosPickerItem]) async {
        let newIDs = Set(new.enumerated().map { index, item in item.itemIdentifier ?? "item-\(index)" })
        // Remove any unchecked photos/videos from the end of their respective pending strips.
        let attachedPhotos = attached.filter { !$0.isVideo }
        let photoBase = max(0, model.pendingPhotos.count - attachedPhotos.count)
        for (offset, entry) in attachedPhotos.enumerated().reversed() where !newIDs.contains(entry.id) {
            model.removePendingPhoto(at: photoBase + offset)
        }
        let attachedVideos = attached.filter(\.isVideo)
        let videoBase = max(0, model.pendingVideos.count - attachedVideos.count)
        for (offset, entry) in attachedVideos.enumerated().reversed() where !newIDs.contains(entry.id) {
            model.removePendingVideo(at: videoBase + offset)
        }
        attached.removeAll { !newIDs.contains($0.id) }

        for (index, item) in new.enumerated() {
            let id = item.itemIdentifier ?? "item-\(index)"
            guard !attached.contains(where: { $0.id == id }) else { continue }
            let isVideo = model.canSendVideos && item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
            if isVideo {
                guard let picked = try? await item.loadTransferable(type: PickedVideoFile.self) else { continue }  // best-effort: an unreadable picker item is skipped
                defer { try? FileManager.default.removeItem(at: picked.url.deletingLastPathComponent()) }
                let ext = picked.url.pathExtension
                let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "video/mp4"
                let before = model.pendingVideos.count
                await model.attachVideo(fileURL: picked.url, filename: picked.url.lastPathComponent, mimeType: mime)
                if model.pendingVideos.count > before { attached.append(AttachedItem(id: id, isVideo: true)) }
            } else {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }  // best-effort: an item the picker can't read is skipped
                let before = model.pendingPhotos.count
                await model.attachPhoto(data: data, filename: id.components(separatedBy: "/").first ?? "photo")
                if model.pendingPhotos.count > before { attached.append(AttachedItem(id: id, isVideo: false)) }
            }
        }
    }
}

/// Any file from Files (sent as is, up to 50 MB), or an image on the clipboard.
private struct FileTab: View {
    let model: TimelineViewModel
    @Binding var choosingFile: Bool

    var body: some View {
        VStack(spacing: HaloSpacing.m) {
            Spacer(minLength: HaloSpacing.s)
            Image(systemName: "doc.badge.plus")
                .font(HaloTypography.title)
                .imageScale(.large)
                .foregroundStyle(HaloColor.accent)
                .accessibilityHidden(true)
            Text("Send a file as it is")
                .font(HaloTypography.headline)
                .foregroundStyle(HaloColor.textPrimary)
            Text("Documents, audio, video or anything else up to 50 MB.")
                .font(HaloTypography.meta)
                .foregroundStyle(HaloColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { choosingFile = true } label: {
                Label("Choose from Files", systemImage: "folder").frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isSendingFile)
            .accessibilityIdentifier("file-button")
            if model.canSendImages, UIPasteboard.general.hasImages {
                Button { pasteImage() } label: {
                    Label("Paste image", systemImage: "doc.on.clipboard").frame(maxWidth: 260)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("paste-image-button")
            }
            Spacer(minLength: 72)
        }
        .padding(.horizontal, HaloSpacing.l)
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image, let data = image.pngData() ?? image.jpegData(compressionQuality: 0.9) else { return }
        Task { await model.attachPhoto(data: data, filename: "pasted") }
    }
}

/// A map to send the current location or a pin dropped at the map's centre (D100). Location access is asked for only
/// when this tab opens; without it the pin still works.
private struct LocationTab: View {
    let model: TimelineViewModel
    let input: ComposerInputController
    @State private var position = MapCameraPosition.userLocation(fallback: .automatic)
    @State private var center: CLLocationCoordinate2D?
    @State private var current: CLLocation?
    @State private var access = CLAuthorizationStatus.notDetermined
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Map(position: $position) { UserAnnotation() }
                    .mapControls { MapUserLocationButton() }
                    .onMapCameraChange(frequency: .onEnd) { center = $0.region.center }
                Image(systemName: "mappin")
                    .font(HaloTypography.title)
                    .foregroundStyle(HaloColor.danger)
                    .offset(y: -12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .clipShape(.rect(cornerRadius: HaloRadius.medium, style: .continuous))
            .padding(.horizontal, HaloSpacing.s)
            .padding(.top, HaloSpacing.s)
            VStack(spacing: HaloSpacing.s) {
                if let current {
                    Button { send(OutgoingLocation(latitude: current.coordinate.latitude, longitude: current.coordinate.longitude,
                                                   accuracy: current.horizontalAccuracy, isOwnLocation: true)) } label: {
                        Label("Send my current location", systemImage: "location.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("send-current-location")
                } else if access == .denied || access == .restricted {
                    Text("Location access is off for Halo. You can still send the pinned place.")
                        .font(HaloTypography.caption).foregroundStyle(HaloColor.textSecondary).multilineTextAlignment(.center)
                }
                Button { if let center { send(OutgoingLocation(latitude: center.latitude, longitude: center.longitude, isOwnLocation: false)) } } label: {
                    Label("Send the pinned place", systemImage: "mappin").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(center == nil)
                .accessibilityIdentifier("send-pinned-location")
            }
            .disabled(sending)
            .padding(.horizontal, HaloSpacing.l)
            .padding(.top, HaloSpacing.s)
            .padding(.bottom, 80)
        }
        .task {
            // Asks for "while using" access the first time this tab opens, then follows the position while it is shown.
            let session = CLServiceSession(authorization: .whenInUse)
            defer { session.invalidate() }
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if update.authorizationDenied || update.authorizationDeniedGlobally { access = .denied }
                    if let location = update.location {
                        access = .authorizedWhenInUse
                        current = location
                        if center == nil { center = location.coordinate }
                    }
                }
            } catch {}
        }
    }

    private func send(_ location: OutgoingLocation) {
        sending = true
        Task {
            if await model.sendLocation(location) { input.dismiss() }
            sending = false
        }
    }
}

/// Starts a poll: the form opens as a sheet so its text fields get the whole screen.
private struct PollTab: View {
    let model: TimelineViewModel
    let input: ComposerInputController
    @State private var composing = false

    var body: some View {
        VStack(spacing: HaloSpacing.m) {
            Spacer(minLength: HaloSpacing.s)
            Image(systemName: "chart.bar.xaxis")
                .font(HaloTypography.title)
                .imageScale(.large)
                .foregroundStyle(HaloColor.accent)
                .accessibilityHidden(true)
            Text("Ask the room")
                .font(HaloTypography.headline)
                .foregroundStyle(HaloColor.textPrimary)
            Text("A question with up to 20 answers. Votes show as they come in, or only when you end the poll.")
                .font(HaloTypography.meta)
                .foregroundStyle(HaloColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { composing = true } label: {
                Label("Create a poll", systemImage: "plus").frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("create-poll-button")
            Spacer(minLength: 72)
        }
        .padding(.horizontal, HaloSpacing.l)
        .sheet(isPresented: $composing) {
            PollComposer(model: model) { input.dismiss() }
                .presentationDetents([.large])
        }
    }
}

/// The poll form (D100): question, 2–20 answers, multiple choice, hidden results.
struct PollComposer: View {
    let model: TimelineViewModel
    let onSent: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answers = ["", ""]
    @State private var multiple = false
    @State private var hidden = false
    @State private var sending = false
    @FocusState private var focusedAnswer: Int?

    private var poll: OutgoingPoll {
        OutgoingPoll(question: question, answers: answers, allowsMultipleAnswers: multiple, hidesResultsUntilEnd: hidden)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("Ask a question", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("poll-question")
                }
                Section {
                    ForEach(answers.indices, id: \.self) { index in
                        TextField("Answer \(index + 1)", text: $answers[index])
                            .focused($focusedAnswer, equals: index)
                            .submitLabel(index == answers.count - 1 ? .done : .next)
                            .onSubmit { focusedAnswer = index + 1 < answers.count ? index + 1 : nil }
                            .accessibilityIdentifier("poll-answer-\(index)")
                    }
                    .onDelete { offsets in
                        guard answers.count - offsets.count >= 2 else { return }
                        answers.remove(atOffsets: offsets)
                    }
                    if answers.count < OutgoingPoll.maximumAnswers {
                        Button("Add an answer", systemImage: "plus.circle.fill") {
                            answers.append("")
                            focusedAnswer = answers.count - 1
                        }
                        .accessibilityIdentifier("poll-add-answer")
                    }
                } header: {
                    Text("Answers")
                } footer: {
                    Text("At least two. Swipe to remove one.")
                }
                if let error = model.sendError, !sending {
                    Section { Text(error).foregroundStyle(HaloColor.danger) }
                }
                Section {
                    Toggle("Multiple answers", isOn: $multiple)
                    Toggle("Hide results until the poll ends", isOn: $hidden)
                }
            }
            .navigationTitle("New poll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sending = true
                        Task {
                            if await model.createPoll(poll) {
                                dismiss()
                                onSent()
                            }
                            sending = false
                        }
                    }
                    .disabled(!poll.isValid || sending)
                    .accessibilityIdentifier("poll-send")
                }
            }
        }
    }
}
#endif
