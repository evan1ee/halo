#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
import PhotosUI

public struct TimelineView: View {
    private let model: TimelineViewModel
    private let stickerPanel: (@MainActor () -> AnyView)?
    private let gifPanel: (@MainActor () -> AnyView)?
    private let onOpenThread: (@MainActor (EventID) -> Void)?
    private let onSaveAsSticker: (@MainActor (Data, String) -> Void)?
    /// Keyboard vs. Halo's panels under the composer (COMPOSER_PANELS §3, D97).
    @State private var input = ComposerInputController()
    @State private var choosingFile = false
    @State private var viewerPhoto: TimelineViewModel.PhotoViewerItem?
    @State private var showingPinnedMessages = false
    @State private var activePinIndex = 0
    @State private var headerVisible = false
    /// History is only loaded after the opening scroll: rows prepended before it would push the landing row out of place.
    @State private var landed = false
    /// Whether the unread marker row and the newest row are on screen (the marker is above the viewport when it isn't, and the newest is).
    /// Off screen until the marker row reports itself visible: a lazy list never lays out a row it lands far below, so that
    /// row never reports going away either (with `true` here the pill never showed after 40 unread messages).
    @State private var markerVisible = UnreadPill.markerOnScreenAtOpen
    @State private var bottomVisible = false
    /// The list follows its newest row (also when older history arrives above it) until the user scrolls away themselves.
    @State private var bottomFollow = BottomFollowState()
    /// In-flight programmatic jump-to-bottom task, cancelled on user touch or conflicting jump.
    @State private var jumpToBottomTask: Task<Void, Never>?
    /// The list is drawn once it has been placed at the newest row (a frame or two), so it never shows its top first and then
    /// jumps. No spinner: a short fallback timer shows it anyway if that never happens.
    @State private var listPlaced = false
    /// The list is being scrolled (a drag, a fling, an animated scroll): it is not following the newest row then.
    @State private var scrollMoving = false
    /// The user's finger is actively dragging the list (never re-anchor mid-drag).
    @State private var scrollInteracting = false
    /// Extra top content margin that keeps a short room anchored just above the composer.
    @State private var shortRoomTopMargin: Double = 0
    /// Recent short-room margin changes, to stop a layout loop instead of freezing (`ShortRoomAlignment`).
    @State private var marginChanges: [Date] = []
    /// Automatic history paging only runs with the newest row on screen (a short room that needs filling) or once the user has
    /// scrolled; right after history lands above the newest row the "Load earlier" row is briefly visible and paging then would
    /// move the content again.
    private var pagingAllowed: Bool { bottomVisible || !bottomFollow.pinnedToBottom }

    @Environment(\.scenePhase) private var scenePhase

    /// - Parameter stickerPanel: the Stickers tab of the expression panel for this room, made by the composition root (a
    ///   feature never imports another feature). Without it the panel has no Stickers tab.
    /// - Parameter gifPanel: the GIFs tab (KLIPY, D98); without it the panel has no GIFs tab.
    /// - Parameter onOpenThread: opens a focused thread sheet for the chosen root event (M10 Threads).
    public init(
        model: TimelineViewModel,
        stickerPanel: (@MainActor () -> AnyView)? = nil,
        gifPanel: (@MainActor () -> AnyView)? = nil,
        onOpenThread: (@MainActor (EventID) -> Void)? = nil,
        onSaveAsSticker: (@MainActor (Data, String) -> Void)? = nil
    ) {
        self.model = model
        self.stickerPanel = stickerPanel
        self.gifPanel = gifPanel
        self.onOpenThread = onOpenThread
        self.onSaveAsSticker = onSaveAsSticker
    }

    public var body: some View {
        bodyContent.modifier(TimelineDropModifier(model: model))
    }

    private var bodyContent: some View {
        Group {
            switch model.content {
            case .opening:
                // No spinner when a room opens: it is normally there within a moment. Only a slow open (a poor network) gets one.
                DelayedProgressView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't open room", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await model.retry() } }.buttonStyle(.borderedProminent)
                }
            case .live(let rows, let isPaginating, let canLoadEarlier, let paginationError):
                ScrollViewReader { proxy in
                List {
                    if canLoadEarlier {
                        HStack {
                            Spacer()
                            if isPaginating {
                                ProgressView()
                            } else {
                                Button(paginationError ?? "Load earlier messages") { Task { await model.loadEarlier() } }
                                    .font(.footnote)
                            }
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        // History loads only while this row is on screen (the user is at the top), and continues until the
                        // screen is full or the start marker arrives; opening a room never loads it all.
                        .onAppear { headerVisible = true }
                        .onDisappear { headerVisible = false }
                        .task(id: PaginationTrigger(rows: rows.count, ready: headerVisible && landed && pagingAllowed)) { if headerVisible, landed, pagingAllowed, paginationError == nil { await model.loadEarlier() } }
                    }
                    // A room with nothing but its setup events (created, joined, settings) says so, above those events
                    // (as a row, so the short-room alignment keeps it clear of them and of the composer).
                    if !canLoadEarlier, !rows.contains(where: \.isConversation) {
                        ContentUnavailableView {
                            Label("No messages yet", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("Messages you send here appear in this conversation.")
                        }
                        // ContentUnavailableView fills what it's offered and can be squeezed; a list row must keep its own
                        // height or the description draws over the setup rows below (founder screenshot, two-line description).
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("empty-room")
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    ForEach(rows) { row in
                        RowView(
                            row: row,
                            model: model,
                            onOpenThread: onOpenThread,
                            onOpenPhoto: { rowID in
                                viewerPhoto = model.viewerPhotos.first(where: { $0.id == rowID })
                            },
                            onSaveAsSticker: onSaveAsSticker
                        )
                            .background(model.highlightedRowID == row.id ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 8))
                            .animation(.easeOut(duration: 0.4), value: model.highlightedRowID)
                            // The pill's target: whether the first row that was unread at open is on screen.
                            .onScrollVisibilityChange { if row.id == model.unreadMarkerID { markerVisible = $0 } }
                            // D6: a row counts as seen when at least half of it is on screen; the 0.5 s dwell is in the view model.
                            .onScrollVisibilityChange(threshold: 0.5) { model.rowVisibility(row, isVisible: $0) }
                            .onDisappear { model.rowVisibility(row, isVisible: false) }
                            .listRowSeparator(.hidden, edges: .all)
                            // Messages of one group sit close together; a new sender or a gap gets more room above. Stickers and
                            // photos have no bubble to separate them, so they keep a small gap even inside a group.
                            .listRowInsets(EdgeInsets(top: row.continuesRun ? (row.isSticker || row.image != nil ? 4 : 1) : 8, leading: 16, bottom: 1, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .scrollEdgeEffectHidden(true, for: .top)
                // A finger dragging the conversation closes the keyboard or panel (the drag gesture below). The list itself
                // never dismisses the keyboard: a programmatic move (a short room's margin changing as the keyboard rises)
                // would count as a scroll, and with interactive dismissal the composer could not follow the finger (it
                // doesn't move with the system keyboard, D102, and iOS sends no keyboard frames during that drag).
                .scrollDismissesKeyboard(.never)
                // A tap on the conversation closes the keyboard or panel; the gesture only exists while one is open.
                .simultaneousGesture(TapGesture().onEnded { input.dismiss() }, including: input.state.mode == .idle && input.state.displayedPanel == nil ? .subviews : .all)
                .opacity(listPlaced || rows.isEmpty ? 1 : 0)
                .task {
                    try? await Task.sleep(for: .milliseconds(600))
                    listPlaced = true
                }
                .environment(\.defaultMinListRowHeight, 0)  // rows are as tall as their content, so a group reads as one
                .listSectionSeparator(.hidden)
                .listRowSeparatorTint(.clear)
                .defaultScrollAnchor(.bottom)
                // A short room sits just above the composer instead of at the top (`ShortRoomAlignment`).
                .contentMargins(.top, shortRoomTopMargin, for: .scrollContent)
                .onScrollGeometryChange(for: ShortRoomGeometry.self) { geometry in
                    ShortRoomGeometry(
                        containerHeight: geometry.containerSize.height,
                        topInset: geometry.contentInsets.top,
                        bottomInset: geometry.contentInsets.bottom,
                        contentHeight: geometry.contentSize.height,
                        canLoadEarlier: canLoadEarlier
                    )
                } action: { _, value in
                    updateShortRoomMargin(value)
                }
                // "At the bottom" comes from the scroll geometry, not from one row's visibility: that flag could stay true after
                // rows were added above the newest row and then hide that the list had moved away from the bottom.
                // While the list follows the newest row and nothing is scrolling it, any change that leaves it short of the bottom
                // scrolls it back: history arriving above, a row that grows (a reaction), the keyboard, and a lazy list replacing
                // estimated row heights with real ones after the opening scroll (it then drifts up by itself; seen in S10 scroll
                // test). Any scroll movement — a drag, a fling, a tap on the status bar, an animated jump — stops the following.
                .onScrollGeometryChange(for: BottomGap.self) { geometry in
                    BottomGap(
                        contentHeight: geometry.contentSize.height, bottomInset: geometry.contentInsets.bottom,
                        visibleMaxY: geometry.visibleRect.maxY)
                } action: { _, value in
                    let atBottom = value.isAtBottom
                    if atBottom != bottomVisible {
                        bottomVisible = atBottom
                    }
                    if landed, (!bottomFollow.jumpingToBottom || atBottom), model.isAtBottom != atBottom {
                        model.setAtBottom(atBottom)
                    }
                    if bottomFollow.onScrollGeometryChanged(atBottom: atBottom, scrollMoving: scrollMoving),
                       let last = rows.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                // A finger dragging the conversation puts the keyboard or a panel away (COMPOSER_PANELS §3). A real drag
                // gesture, not the scroll phase: that also changes for programmatic moves.
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in
                    if input.state.mode != .idle || input.state.displayedPanel != nil { input.dismiss() }
                }, including: input.state.mode == .idle && input.state.displayedPanel == nil ? .subviews : .all)
                .onScrollPhaseChange { _, phase in
                    scrollMoving = phase == .interacting || phase == .decelerating || phase == .animating
                    scrollInteracting = phase == .interacting
                    if phase == .interacting {
                        jumpToBottomTask?.cancel()
                        jumpToBottomTask = nil
                        bottomFollow.onUserInteractionStarted(atBottom: bottomVisible)
                        if !landed {
                            landed = true
                            listPlaced = true
                            model.setAtBottom(bottomVisible)
                        }
                    }
                }
                .onChange(of: rows.first?.id) { oldFirst, newFirst in
                    if let anchor = PrependedAnchor.anchor(
                        oldFirst: oldFirst,
                        newFirst: newFirst,
                        rowIDs: rows.map(\.id),
                        landed: landed,
                        pinnedToBottom: bottomFollow.pinnedToBottom,
                        interacting: scrollInteracting
                    ) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
                .accessibilityIdentifier("timeline")
                // Opening a room: the newest row goes to the bottom. `.defaultScrollAnchor(.bottom)` already opens the list there, so
                // when that row is on screen nothing is scrolled and the list never visibly moves.
                // `.task(id:)` also runs for a value that was already set when this list first appeared (onChange wouldn't).
                .task(id: model.landingRow) {
                    guard let landing = model.landingRow else { return }
                    try? await Task.sleep(for: .milliseconds(80))  // let the list lay the rows out first
                    // A lazy list estimates the height of rows it hasn't laid out, so one jump to a row far below the visible
                    // part lands short; jumping again after each layout converges (at most ~2 s).
                    var confirmed = 0
                    for _ in 0..<16 {
                        if Task.isCancelled { return }
                        // Placed only when the newest row is still there one check later: right after the first scroll the list
                        // replaces estimated row heights with real ones and can move again.
                        if model.landingIsUnread ? markerVisible : bottomVisible {
                            confirmed += 1
                            if confirmed >= 2 { break }
                            try? await Task.sleep(for: .milliseconds(60))
                            continue
                        }
                        confirmed = 0
                        // Landing at the bottom means the newest row now: history can still be arriving in batches after
                        // the landing row was chosen (seen on a reopened room), and that row would leave the list mid-history.
                        let target = model.landingIsUnread ? landing : (model.lastRowID ?? landing)
                        proxy.scrollTo(target, anchor: model.landingIsUnread ? .top : .bottom)
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                    listPlaced = true
                    // Settle first: `landingShown()` clears `landingRow`, which changes this task's id and cancels it.
                    try? await Task.sleep(for: .milliseconds(250))  // let the scroll settle before history may load
                    landed = true
                    model.landingShown()
                    model.setAtBottom(bottomVisible)
                }
                // A newer last row (own echo or incoming message) scrolls into view when the user is at the bottom. Earlier
                // history prepended at the top doesn't change the last row, so reading old messages isn't disturbed.
                .task(id: rows.last?.id) {
                    // A new last row scrolls into view when already at the bottom or when the user just sent it; when
                    // scrolled up reading history, stay put so the "↓ N new" pill lets the user jump down on their own (TIMELINE §6).
                    guard landed, let last = rows.last, model.isAtBottom || last.isOwn else { return }
                    for step in 0..<3 {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        try? await Task.sleep(for: .milliseconds(step == 0 ? 200 : 250))
                    }
                }
                .onChange(of: model.jumpRequest) { _, target in
                    guard let target else { return }
                    jumpToBottomTask?.cancel()
                    jumpToBottomTask = nil
                    landed = true
                    listPlaced = true
                    bottomFollow.detach()  // a reply/pin jump leaves the bottom: new rows must not pull the reader back down
                    if target != rows.last?.id {
                        bottomVisible = false
                        model.setAtBottom(false)
                    }
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    model.jumpHandled()
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        model.clearHighlight()
                    }
                }
                // FR-4: the marker is above the viewport once the user is at the bottom and the marker is out of sight.
                .overlay(alignment: .top) {
                    if let marker = model.unreadMarkerID,
                       UnreadPill.isShown(hasMarker: true, landed: landed, markerOnScreen: markerVisible, atBottom: bottomVisible) {
                        Button {
                            jumpToBottomTask?.cancel()
                            jumpToBottomTask = nil
                            bottomFollow.detach()
                            withAnimation { proxy.scrollTo(marker, anchor: .top) }
                        } label: {
                            Label("Jump to unread", systemImage: "arrow.up")
                                .font(.footnote.bold()).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .accessibilityIdentifier("jump-to-unread")
                    }
                }
                // TIMELINE §6: when scrolled up, offer a floating button (or "↓ N new" pill) to return to the newest row.
                .overlay(alignment: .bottomTrailing) {
                    if landed, (!model.isAtBottom || !bottomVisible), let last = rows.last?.id {
                        Button {
                            jumpToBottomTask?.cancel()
                            bottomFollow.beginJumpToBottom()
                            model.setAtBottom(true)
                            let wasMoving = scrollMoving
                            let initialTarget = model.lastRowID ?? last
                            if wasMoving {
                                // Interrupt in-flight deceleration/animation synchronously on the tap frame.
                                proxy.scrollTo(initialTarget, anchor: .bottom)
                            }
                            jumpToBottomTask = Task { @MainActor in
                                defer { bottomFollow.cancelJumpToBottom() }
                                if wasMoving {
                                    try? await Task.sleep(for: .milliseconds(50))
                                } else {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        proxy.scrollTo(model.lastRowID ?? last, anchor: .bottom)
                                    }
                                    try? await Task.sleep(for: .milliseconds(120))
                                }
                                for _ in 0..<8 {
                                    if Task.isCancelled || bottomVisible || !bottomFollow.jumpingToBottom { break }
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo(model.lastRowID ?? last, anchor: .bottom)
                                    }
                                    try? await Task.sleep(for: .milliseconds(100))
                                }
                            }
                        } label: {
                            if model.newSinceDetached > 0 {
                                Label("\(model.newSinceDetached) new", systemImage: "arrow.down")
                                    .font(HaloTypography.meta.weight(.bold))
                                    .foregroundStyle(HaloColor.textPrimary)
                                    .padding(.horizontal, HaloSpacing.m)
                                    .padding(.vertical, HaloSpacing.s)
                                    .contentShape(.capsule)
                                    .glassEffect(.regular.interactive(), in: .capsule)
                            } else {
                                Image(systemName: "arrow.down")
                                    .font(HaloTypography.meta.weight(.bold))
                                    .foregroundStyle(HaloColor.textPrimary)
                                    .frame(width: 34, height: 34)
                                    .contentShape(.circle)
                                    .glassEffect(.regular.interactive(), in: .circle)
                                    .frame(width: 44, height: 44)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, HaloSpacing.s)
                        .padding(.bottom, HaloSpacing.m)
                        .accessibilityLabel(model.newSinceDetached > 0 ? "\(model.newSinceDetached) new messages, jump to bottom" : "Jump to bottom")
                        .accessibilityIdentifier("jump-to-bottom")
                    }
                }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                let pins = model.pinnedMessages
                if !pins.isEmpty {
                    let index = min(max(activePinIndex, 0), pins.count - 1)
                    let current = pins[index]
                    Button {
                        showingPinnedMessages = true
                    } label: {
                        HStack(spacing: HaloSpacing.xs) {
                            Image(systemName: "pin.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HaloColor.accent)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(pins.count == 1 ? "Pinned" : "Pinned \(index + 1)/\(pins.count)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(HaloColor.textPrimary)
                                    .lineLimit(1)
                                    .contentTransition(.numericText())
                                Text(current.preview)
                                    .font(.caption2)
                                    .foregroundStyle(HaloColor.textSecondary)
                                    .lineLimit(1)
                                    .id(current.eventID)
                                    .transition(.opacity)
                            }
                            .frame(maxWidth: 165, alignment: .leading)
                            .animation(.snappy(duration: 0.2), value: index)
                        }
                        .padding(.horizontal, HaloSpacing.m)
                        .frame(height: 44)
                        .contentShape(.capsule)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                guard pins.count > 1, abs(value.translation.width) > abs(value.translation.height) else { return }
                                withAnimation(.snappy(duration: 0.2)) {
                                    if value.translation.width > 20 {
                                        activePinIndex = (index + 1) % pins.count
                                    } else if value.translation.width < -20 {
                                        activePinIndex = (index - 1 + pins.count) % pins.count
                                    }
                                }
                            }
                    )
                    .accessibilityLabel(pins.count == 1 ? "Pinned message: \(current.preview)" : "Pinned \(index + 1) of \(pins.count): \(current.preview)")
                    .accessibilityIdentifier("pinned-messages-banner")
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Composer(model: model, input: input, choosingFile: $choosingFile)
                #if canImport(UIKit)
                ComposerPanelArea(controller: input) { panel in
                    ComposerPanelContent(
                        panel: panel, model: model, input: input, gifPanel: gifPanel, stickerPanel: stickerPanel, choosingFile: $choosingFile)
                }
                #endif
            }
        }
        #if canImport(UIKit)
        // The area under the composer holds the keyboard's height itself (`ComposerPanelMetrics.areaHeight`), so the system
        // must not also move the composer for the keyboard: two animations made it dip and creep back in every keyboard/panel
        // swap (D102). Applied always: switching it rebuilds the message field, which then loses focus.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(item: Binding(get: { model.openedFile }, set: { if $0 == nil { model.closeFile() } })) {
            QuickLookView(url: $0.url)
                .ignoresSafeArea()
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $viewerPhoto) { photo in
            photoViewer(initial: photo)
        }
        #else
        .sheet(item: $viewerPhoto) { photo in
            photoViewer(initial: photo)
        }
        #endif
        .alert("Can't open file", isPresented: Binding(get: { model.openFileError != nil }, set: { if !$0 { model.dismissOpenFileError() } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.openFileError ?? "") }
        .sheet(isPresented: $showingPinnedMessages) {
            PinnedMessagesSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.editHistory != nil }, set: { if !$0 { model.closeEditHistory() } })) {
            EditHistoryView(state: model.editHistory ?? .loading)
        }
        .sheet(isPresented: Binding(get: { model.reactionTarget != nil }, set: { if !$0 { model.cancelReactionPicker() } })) {
            ReactionPicker(model: model).presentationDetents([.medium])
        }
        .task { await model.start() }
        .onChange(of: scenePhase, initial: true) { _, phase in model.setActive(phase == .active) }
        .onDisappear {
            jumpToBottomTask?.cancel()
            jumpToBottomTask = nil
            model.setActive(false)
            Task { await model.stop() }
        }
    }

    private func photoViewer(initial: TimelineViewModel.PhotoViewerItem) -> some View {
        let all = model.viewerPhotos
        let photos = all.isEmpty ? [initial] : all
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        let items = photos.map {
            PagedMediaItem(id: $0.id, title: $0.sender ?? "Photo", caption: $0.caption, fallbackSymbol: "photo", isImage: true)
        }
        return PagedPhotoViewer(
            items: items,
            initialID: initial.id,
            loadImageData: { item in
                guard let target = byID[item.id] else { return nil }
                return await model.fullImageData(for: target.image)
            },
            exportItem: { item in
                guard let target = byID[item.id] else { return nil }
                return await model.exportViewerPhoto(target)
            },
            onReply: { item in
                guard case .live(let rows, _, _, _) = model.content,
                      let row = rows.first(where: { $0.id == item.id }),
                      row.eventID != nil else { return }
                model.beginReply(row)
            },
            onReact: { item, emoji in
                guard case .live(let rows, _, _, _) = model.content,
                      let row = rows.first(where: { $0.id == item.id }),
                      row.eventID != nil else { return }
                Task { await model.toggleReaction(on: row, key: emoji) }
            },
            onSaveAsSticker: onSaveAsSticker.map { save in
                { data, filename in
                    viewerPhoto = nil
                    save(data, filename)
                }
            }
        )
    }
}

/// TIMELINE FR-4 and D95: the "Jump to unread" pill shows once the room has landed at the newest message and the first
/// unread message is above the screen.
enum UnreadPill {
    /// The marker row counts as off screen until it reports itself visible.
    static let markerOnScreenAtOpen = false

    static func isShown(hasMarker: Bool, landed: Bool, markerOnScreen: Bool, atBottom: Bool) -> Bool {
        hasMarker && landed && !markerOnScreen && atBottom
    }
}

/// How far the end of the list is below its visible part (≤ 0 at the bottom), and the content height, so a change of either
/// reaches the scroll-geometry action. The visible rect reaches under the composer, so the end is the content plus the bottom
/// inset; measured against the content alone, the newest row could sit half behind the composer and count as at the bottom.
extension TimelineView {
    /// Applies the short-room margin for `value`, at most `ShortRoomAlignment.maximumChangesPerSecond` times a second.
    func updateShortRoomMargin(_ value: ShortRoomGeometry) {
        let margin = ShortRoomAlignment.topMargin(
            containerHeight: value.containerHeight,
            topInset: value.topInset,
            bottomInset: value.bottomInset,
            contentHeight: value.contentHeight,
            currentMargin: shortRoomTopMargin,
            canLoadEarlier: value.canLoadEarlier
        )
        guard margin != shortRoomTopMargin else { return }
        let now = Date()
        marginChanges = marginChanges.filter { now.timeIntervalSince($0) < 1 } + [now]
        guard marginChanges.count <= ShortRoomAlignment.maximumChangesPerSecond else { return }
        shortRoomTopMargin = margin
    }
}

struct BottomGap: Equatable {
    let gap: Double
    let contentHeight: Double

    init(contentHeight: Double, bottomInset: Double, visibleMaxY: Double) {
        gap = contentHeight + bottomInset - visibleMaxY
        self.contentHeight = contentHeight
    }

    var isAtBottom: Bool { gap <= 8 }
}

struct PaginationTrigger: Hashable {
    let rows: Int
    let ready: Bool
}

/// A spinner that appears only when the wait passes one second.
private struct DelayedProgressView: View {
    @State private var shown = false

    var body: some View {
        ProgressView()
            .opacity(shown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .seconds(1))
                shown = true
            }
    }
}

/// "View source" for a text message: who sent it, which event, and the plain and HTML bodies exactly as received.

#endif
