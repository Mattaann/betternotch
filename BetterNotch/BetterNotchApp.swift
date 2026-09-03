import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BetterNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct NotchActivationZone {
    let rect: NSRect

    init(notch: NSRect, extensionPoints: CGFloat) {
        let margin = max(0, extensionPoints)
        rect = notch.insetBy(dx: -margin, dy: -margin)
    }

    func contains(_ point: NSPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
}

enum PanelTab: String, CaseIterable, Identifiable {
    case files = "Files", music = "Music", notes = "Notes", calendar = "Calendar"
    var id: String { rawValue }
    var section: PanelTab { self }
    static func restored(_ value: String) -> PanelTab? {
        value == "Paper" ? .calendar : PanelTab(rawValue: value)
    }
    var label: String { rawValue }
    var symbol: String {
        switch self {
        case .files: return "folder"
        case .music: return "music.note"
        case .notes: return "pencil"
        case .calendar: return "calendar"
        }
    }
}

struct QuickNote: Identifiable {
    let id = UUID()
    var text = ""
}

enum PanelAnimation: String, CaseIterable, Identifiable {
    case instant = "Instant"
    case expand = "Expand"
    case fade = "Fade"
    static func restored(_ value: String) -> PanelAnimation? { value == "Glide" ? .expand : PanelAnimation(rawValue: value) }
    var id: String { rawValue }
}

final class Shelf: ObservableObject {
    @Published var files: [URL] = []
    @Published var activeSections: Set<PanelTab> = [.files]
    @Published var enabledTabs = Set(PanelTab.allCases)
    @Published var showTemperature = false
    @Published var musicSource: MusicSource = .appleMusic
    @Published var allAudioSources = false
    @Published var notes: [QuickNote] = []
    var nonemptyNoteCount: Int { notes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count }
    @Published var selectedNoteID: UUID?
    @Published var editingNote = false
    let music = MusicController()
    let weather = WeatherController()
    var modulesChanged: (() -> Void)?
    var presentationChanged: (() -> Void)?
    var visibleSections: [PanelTab] {
        [.files, .music, .calendar, .notes].filter { section in
            activeSections.contains(section) && enabledTabs.contains(where: { $0.section == section })
        }
    }
    func sectionHeight(_ section: PanelTab) -> CGFloat { section == .calendar ? 150 : 78 }
    var contentHeight: CGFloat {
        guard !visibleSections.isEmpty else { return 100 }
        return visibleSections.reduce(22) { $0 + sectionHeight($1) } + CGFloat(visibleSections.count - 1) * 12
    }
    var notesVisible: Bool { visibleSections.contains(.notes) }
    func isActive(_ tab: PanelTab) -> Bool { visibleSections.contains(tab.section) }
    var focusPanel: (() -> Void)?
    var closePanel: (() -> Void)?
    var effectivePanelWidth: CGFloat {
        max(panelWidth, notchWidth + 28 + 2 * (max(88 + CGFloat(enabledTabs.count) * 24, 140) + 18))
    }
    func select(_ tab: PanelTab) {
        let section = tab.section
        guard enabledTabs.contains(tab) else { return }
        if activeSections.contains(section) {
            activeSections.remove(section)
            if section == .notes { editingNote = false }
        } else {
            activeSections.insert(section)
            if section == .notes && !notes.contains(where: { $0.id == selectedNoteID }) {
                selectedNoteID = notes.first?.id
            }
            if section == .music { music.refresh() }
        }
        interaction?()
        presentationChanged?()
    }
    func addNote() {
        let note = QuickNote()
        notes.append(note)
        selectedNoteID = note.id
        focusPanel?()
    }
    func deleteNote() {
        guard let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else { return }
        notes.remove(at: index)
        selectedNoteID = notes.isEmpty ? nil : notes[min(index, notes.count - 1)].id
    }
    func setTab(_ tab: PanelTab, enabled: Bool) {
        if enabled {
            enabledTabs.insert(tab)
            activeSections.insert(tab.section)
        } else {
            enabledTabs.remove(tab)
            if !enabledTabs.contains(where: { $0.section == tab.section }) { activeSections.remove(tab.section) }
        }
        if !notesVisible { editingNote = false }
        modulesChanged?()
    }
    @Published var expanded = false
    @Published var message: String?
    @Published var panelWidth: CGFloat = 560
    @Published var topInset: CGFloat = 32
    @Published var notchWidth: CGFloat = 180
    @Published var closeDistance: Double = 1.5
    @Published var activationDistance: Double = 0
    @Published var openingAnimation: PanelAnimation = .expand
    @Published var closingAnimation: PanelAnimation = .expand
    @Published var animationSpeed: Double = 1
    @Published var showIdleOutline = false
    @Published var idlePadding: Double = 6
    @Published var idleRadius: Double = 8
    @Published var hideFromDock = true
    @Published var hideFromMenuBar = false
    @Published var startAtLogin = true
    @Published var loginStatus = ""
    @Published var loginNeedsAttention = false
    var visibilityChanged: (() -> Void)?
    var loginChanged: ((Bool) -> Void)?
    var openLoginSettings: (() -> Void)?
    var quit: (() -> Void)?
    var previewAnimation: (() -> Void)?
    @Published var settingsCategory: SettingsCategory = .general
    var permissions: (() -> Void)?
    var customize: (() -> Void)?
    var layoutChanged: (() -> Void)?
    var share: (([URL]) -> Void)?
    var choose: (() -> Void)?
    var interaction: (() -> Void)?

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let normalized = url.standardizedFileURL
            if !files.contains(normalized) { files.append(normalized) }
        }
        if enabledTabs.contains(.files) {
            activeSections.insert(.files)
            presentationChanged?()
        }
        interaction?()
    }

    func receive(_ providers: [NSItemProvider], airDrop: Bool = false) -> Bool {
        let supported = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !supported.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in supported {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = nil }
                if let url, url.isFileURL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if urls.isEmpty { self.message = "These files could not be read. Try dragging them from Finder." }
            else if airDrop { self.share?(urls) }
            else { self.add(urls) }
        }
        return true
    }
}

struct ShelfView: View {
    @ObservedObject var shelf: Shelf
    @State private var targeted = false
    @State private var airDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button { shelf.customize?() } label: {
                        Text("Betternotch").font(.system(size: 12, weight: .semibold))
                    }.help("Customize BetterNotch")
                    ForEach(PanelTab.allCases.filter { shelf.enabledTabs.contains($0) }) { tab in
                        Button { shelf.select(tab) } label: {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 18, height: 24)
                                .foregroundStyle(shelf.isActive(tab) ? .white : .white.opacity(0.45))
                                .background(shelf.isActive(tab) ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.help(tab.label).accessibilityLabel(tab.label)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity)
                Color.clear.frame(width: shelf.notchWidth + 28)
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    if shelf.showTemperature { TemperatureBadge(weather: shelf.weather, openPermissions: { shelf.permissions?() }) }
                    if shelf.notesVisible {
                        Button { shelf.deleteNote() } label: {
                            Image(systemName: "minus").frame(width: 20, height: 24)
                        }
                        .disabled(shelf.selectedNoteID == nil)
                        .help("Delete selected note")
                        .accessibilityLabel("Delete selected note")
                    }
                    Button {
                        if shelf.notesVisible { shelf.addNote() }
                        else { shelf.choose?() }
                    } label: {
                        Image(systemName: "plus").frame(width: 20, height: 24)
                    }
                    .disabled(!shelf.notesVisible && !shelf.enabledTabs.contains(.files))
                    .help(shelf.notesVisible ? "New note" : "Add files or folders")
                    Button { shelf.customize?() } label: {
                        Image(systemName: "gearshape").frame(width: 20, height: 24)
                    }.help("Settings").accessibilityLabel("Settings")
                }.frame(maxWidth: .infinity)
            }
            .frame(height: shelf.topInset)
            VStack(spacing: 12) {
                if shelf.visibleSections.isEmpty {
                    Text("Choose a section above").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 78)
                }
                ForEach(shelf.visibleSections) { section in
                    Group {
                        switch section {
                        case .files: fileShelf
                        case .music: NowPlayingView(music: shelf.music, active: shelf.expanded, openPermissions: { shelf.permissions?() })
                        case .calendar: MiniCalendarView()
                        case .notes: QuickNotesView(shelf: shelf)
                        }
                    }.frame(maxWidth: .infinity).frame(height: shelf.sectionHeight(section))
                }
            }.frame(maxWidth: .infinity).frame(height: shelf.contentHeight - 22)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(width: shelf.effectivePanelWidth, height: shelf.topInset + shelf.contentHeight, alignment: .top)
        .overlay(alignment: .bottom) {
            if let message = shelf.message {
                HStack(spacing: 8) {
                    Text(message)
                    Button("Permissions") { shelf.permissions?() }
                    Button { shelf.message = nil } label: { Image(systemName: "xmark") }
                }.font(.system(size: 10))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black, in: Capsule())
                    .padding(.bottom, 2)

            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    private var fileShelf: some View {
            HStack(spacing: 10) {
                Group {
                    if shelf.files.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 20, weight: .light))
                            Text(targeted ? "Release to keep here" : "Drop something here")
                                .font(.system(size: 13, weight: .medium))
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(shelf.files, id: \.self) { url in
                                    fileCard(url)
                                }
                            }.padding(.horizontal, 10)
                        }
                    }
                }
                .frame(width: shelf.effectivePanelWidth - 128, height: 78)
                .background(.white.opacity(targeted ? 0.13 : 0.045), in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(targeted ? 0.65 : 0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { shelf.receive($0) }

                Button {
                    if shelf.files.isEmpty { shelf.message = "Drop a file on AirDrop, or add files to the shelf first." }
                    else { shelf.share?(shelf.files) }
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "airplayaudio").font(.system(size: 25, weight: .light))
                        Text("AirDrop").font(.system(size: 11, weight: .medium))
                    }.frame(width: 82, height: 78)
                        .background(.white.opacity(airDropTargeted ? 0.2 : 0.075), in: RoundedRectangle(cornerRadius: 15))
                        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(airDropTargeted ? 0.7 : 0.1)))
                }
                .buttonStyle(.plain)
                .help("Drop files here to choose an AirDrop recipient, or click to share the shelf")
                .onDrop(of: [UTType.fileURL], isTargeted: $airDropTargeted) { shelf.receive($0, airDrop: true) }
            }
        }

    private func fileCard(_ url: URL) -> some View {
        FileDragCard(url: url, shelf: shelf).frame(width: 74, height: 72)
    }
}

struct FileDragCard: NSViewRepresentable {
    let url: URL
    let shelf: Shelf

    func makeNSView(context: Context) -> FileDragView {
        FileDragView(url: url, shelf: shelf)
    }

    func updateNSView(_ view: FileDragView, context: Context) {
        view.url = url
        view.toolTip = url.lastPathComponent
        view.setAccessibilityLabel(url.lastPathComponent)
        view.needsDisplay = true
    }
}

final class FileDragView: NSView, NSDraggingSource {
    var url: URL
    private let shelf: Shelf
    private var mouseDownPoint: NSPoint?
    private var draggedURL: URL?

    init(url: URL, shelf: Shelf) {
        self.url = url
        self.shelf = shelf
        super.init(frame: NSRect(x: 0, y: 0, width: 74, height: 72))
        toolTip = url.lastPathComponent
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(url.lastPathComponent)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: 23, y: 40, width: 28, height: 28))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        (url.lastPathComponent as NSString).draw(in: NSRect(x: 2, y: 5, width: 70, height: 29), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        if event.clickCount == 2 { openFile() }
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint, draggedURL == nil,
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 3 else { return }
        mouseDownPoint = nil
        draggedURL = url
        shelf.interaction?()
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: 23, y: 40, width: 28, height: 28), contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let completedURL = draggedURL
        draggedURL = nil
        let returnedToShelf = window?.frame.contains(screenPoint) ?? false
        if !operation.isEmpty, !returnedToShelf, let completedURL {
            shelf.files.removeAll { $0 == completedURL }
        }
        shelf.interaction?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Open", #selector(openFile)), ("Show in Finder", #selector(revealFile)), ("AirDrop", #selector(shareFile)), ("Remove from Shelf", #selector(removeFile))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    override func accessibilityPerformPress() -> Bool { openFile(); return true }
    @objc private func openFile() {
        if !NSWorkspace.shared.open(url) { shelf.message = "File unavailable. It may have been moved or deleted." }
    }
    @objc private func revealFile() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @objc private func shareFile() { shelf.share?([url]) }
    @objc private func removeFile() { shelf.files.removeAll { $0 == url } }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General", modules = "Modules", appearance = "Appearance", behavior = "Behavior", audio = "Music & Audio", permissions = "Permissions", privacy = "Notes & Privacy"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .modules: return "square.grid.2x2"
        case .appearance: return "rectangle.topthird.inset.filled"
        case .behavior: return "cursorarrow.rays"
        case .audio: return "music.note"
        case .permissions: return "checkmark.shield"
        case .privacy: return "lock.shield"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "Make BetterNotch part of your everyday setup."
        case .modules: return "Choose what belongs in your notch."
        case .appearance: return "Fine-tune the shape and movement."
        case .behavior: return "Adjust when the panel opens and closes."
        case .audio: return "Choose your player and manage media access."
        case .permissions: return "Connect your apps and resolve access problems."
        case .privacy: return "Temporary by design. You stay in control."
        }
    }
}

struct SettingsCardStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.system(size: 13, weight: .semibold))
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
    }
}

struct CustomizeView: View {
    @ObservedObject var shelf: Shelf
    private var category: SettingsCategory { shelf.settingsCategory }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 20))
                    Text("BetterNotch").font(.system(size: 14, weight: .semibold))
                }.padding(.vertical, 22).padding(.horizontal, 8)
                ForEach(SettingsCategory.allCases) { item in
                    Button { shelf.settingsCategory = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).frame(width: 18)
                            Text(item.rawValue)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, weight: category == item ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .background(category == item ? .white.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("Settings").font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(10)
            }.padding(.horizontal, 12).frame(width: 172)
                .background(.black.opacity(0.15))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.rawValue).font(.system(size: 24, weight: .semibold))
                        Text(category.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.bottom, 2)
                    selectedContent
                }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            }.id(category)
        }
        .frame(width: 720, height: 570)
        .foregroundStyle(.white)
        .background(Color(white: 0.10))
        .groupBoxStyle(SettingsCardStyle())
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var selectedContent: some View {
        switch category {
        case .general: generalSettings
        case .modules: modulesSettings
        case .appearance: animationSettings; appearanceSettings
        case .behavior: behaviorSettings
        case .audio: AudioSettingsView(shelf: shelf, music: shelf.music)
        case .permissions: PermissionsSettingsView(shelf: shelf, weather: shelf.weather)
        case .privacy: privacySettings
        }
    }

    private var modulesSettings: some View {
        GroupBox("Visible controls") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(PanelTab.allCases) { tab in
                    Toggle(isOn: Binding(get: { shelf.enabledTabs.contains(tab) }, set: { shelf.setTab(tab, enabled: $0) })) {
                        Label(tab.label, systemImage: tab.symbol)
                    }
                }
                Divider()
                Toggle("Local temperature", isOn: $shelf.showTemperature)
                    .onChange(of: shelf.showTemperature) { _ in shelf.modulesChanged?() }
                Text("Click the icons in the notch to show or hide individual sections. Your content stays in place.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        }
    }

    private var privacySettings: some View {
        VStack(spacing: 16) {
            GroupBox("Temporary notes") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Confirmation before quitting", systemImage: "checkmark.shield")
                    Text("If a note contains text, BetterNotch asks before quitting. Keep the app open to retain your notes, or explicitly discard them.")
                    Text("Notes live in memory and are never written to disk. Force Quit or a crash cannot preserve them.")
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
            GroupBox("Files & connections") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shelf items are references. Removing them never deletes your original files.")
                    Text("Music metadata, artwork, and weather stay in memory. Only your settings are saved locally.")
                    Text("Weather uses your approximate location with Open-Meteo, after you allow location access.")
                    Link("Weather by Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var generalSettings: some View {
        GroupBox("App") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Hide from Dock", isOn: $shelf.hideFromDock)
                            .onChange(of: shelf.hideFromDock) { _ in shelf.visibilityChanged?() }
                        Toggle("Hide from menu bar", isOn: $shelf.hideFromMenuBar)
                            .onChange(of: shelf.hideFromMenuBar) { _ in shelf.visibilityChanged?() }
                        Toggle("Start at login", isOn: Binding(get: { shelf.startAtLogin }, set: { shelf.loginChanged?($0) }))
                        if !shelf.loginStatus.isEmpty {
                            Text(shelf.loginStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        if shelf.loginNeedsAttention {
                            HStack {
                                Button("Open Login Items") { shelf.openLoginSettings?() }
                                Button("Permissions") { shelf.permissions?() }
                            }
                        }
                        Text("The notch and its settings button remain available when both icons are hidden.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Quit BetterNotch") { shelf.quit?() }
                    }.padding(10)
                }
    }

    private var animationSettings: some View {
        GroupBox("Animations") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Opening", selection: $shelf.openingAnimation) {
                            ForEach(PanelAnimation.allCases) { Text($0.rawValue).tag($0) }
                        }.onChange(of: shelf.openingAnimation) { _ in shelf.layoutChanged?() }
                        Picker("Closing", selection: $shelf.closingAnimation) {
                            ForEach(PanelAnimation.allCases) { Text($0.rawValue).tag($0) }
                        }.onChange(of: shelf.closingAnimation) { _ in shelf.layoutChanged?() }
                        HStack {
                            Text("Animation speed")
                            Spacer()
                            Text(String(format: "%.2g×", shelf.animationSpeed)).foregroundStyle(.secondary)
                        }
                        Slider(value: $shelf.animationSpeed, in: 0.5...2, step: 0.25)
                            .onChange(of: shelf.animationSpeed) { _ in shelf.layoutChanged?() }
                        Text("Higher is faster. Instant skips animation. Reduce Motion is always respected.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Preview animation") { shelf.previewAnimation?() }
                    }.padding(10)
                }
    }

    private var appearanceSettings: some View {
        GroupBox("Closed appearance") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Show outline around notch", isOn: $shelf.showIdleOutline)
                            .onChange(of: shelf.showIdleOutline) { _ in shelf.layoutChanged?() }
                        Text("Hidden by default. When hidden, nothing is drawn over or around the physical notch. Hover still opens the shelf immediately.")
                            .font(.caption).foregroundStyle(.secondary)
                        if shelf.showIdleOutline {
                            HStack {
                                Text("Extra size")
                                Slider(value: $shelf.idlePadding, in: 0...12, step: 1)
                                    .onChange(of: shelf.idlePadding) { _ in shelf.layoutChanged?() }
                                Text("\(Int(shelf.idlePadding)) pt").monospacedDigit().frame(width: 40)
                            }
                            HStack {
                                Text("Corner radius")
                                Slider(value: $shelf.idleRadius, in: 0...22, step: 1)
                                    .onChange(of: shelf.idleRadius) { _ in shelf.layoutChanged?() }
                                Text("\(Int(shelf.idleRadius)) pt").monospacedDigit().frame(width: 40)
                            }
                        }
                    }.padding(10)
                }
    }

    private var behaviorSettings: some View {
        GroupBox("Layout & behavior") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Panel width")
                            Spacer()
                            Text("\(Int(shelf.panelWidth)) pt").foregroundStyle(.secondary)
                        }
                        Slider(value: $shelf.panelWidth, in: 520...680, step: 10)
                            .onChange(of: shelf.panelWidth) { _ in shelf.layoutChanged?() }
                        HStack {
                            Text("Opening deadzone")
                            Spacer()
                            Text(shelf.activationDistance == 0 ? "Touch notch" : String(format: "%.1f mm", shelf.activationDistance))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $shelf.activationDistance, in: 0...8, step: 0.5)
                            .onChange(of: shelf.activationDistance) { _ in shelf.layoutChanged?() }
                        Text("0 mm requires touching the physical notch. Increase this to extend the opening zone around it.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("Close outside panel")
                            Spacer()
                            Text(String(format: "%.1f mm", shelf.closeDistance)).foregroundStyle(.secondary)
                        }
                        Slider(value: $shelf.closeDistance, in: 1...2, step: 0.25)
                            .onChange(of: shelf.closeDistance) { _ in shelf.layoutChanged?() }
                    }.padding(10)
                }
    }
}
