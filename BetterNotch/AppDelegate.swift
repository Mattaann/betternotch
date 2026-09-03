import AppKit
import SwiftUI
import QuartzCore
import ServiceManagement

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelSurface: NSView {
    let hosting: NSHostingView<ShelfView>
    private let shelf: Shelf
    private let stage = NSView()
    private let clippingShape = CAShapeLayer()
    var isCompact = true

    init(shelf: Shelf) {
        self.shelf = shelf
        hosting = NSHostingView(rootView: ShelfView(shelf: shelf))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.black.cgColor
        stage.layer?.mask = clippingShape
        addSubview(stage)
        stage.addSubview(hosting)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if stage.frame != bounds { stage.frame = bounds }
        stage.layer?.anchorPoint = CGPoint(x: 0.5, y: 1)
        stage.layer?.position = CGPoint(x: bounds.midX, y: bounds.maxY)
        hosting.frame = NSRect(x: (bounds.width - shelf.effectivePanelWidth) / 2, y: 0, width: shelf.effectivePanelWidth, height: shelf.topInset + shelf.contentHeight)
        let radius = min(isCompact ? CGFloat(shelf.idleRadius) : 22, bounds.width / 2, bounds.height / 2)
        let path = CGMutablePath()
        path.move(to: NSPoint(x: 0, y: bounds.height))
        path.addLine(to: NSPoint(x: bounds.width, y: bounds.height))
        path.addLine(to: NSPoint(x: bounds.width, y: radius))
        path.addQuadCurve(to: NSPoint(x: bounds.width - radius, y: 0), control: NSPoint(x: bounds.width, y: 0))
        path.addLine(to: NSPoint(x: radius, y: 0))
        path.addQuadCurve(to: NSPoint(x: 0, y: radius), control: .zero)
        path.closeSubpath()
        clippingShape.frame = bounds
        clippingShape.path = path
        CATransaction.commit()
    }

    func reveal(_ rect: NSRect?, duration: TimeInterval = 0) {
        guard let stageLayer = stage.layer else { return }
        let previous = stageLayer.animation(forKey: "notchExpansion") == nil
            ? stageLayer.transform : (stageLayer.presentation()?.transform ?? stageLayer.transform)
        let target = rect.map {
            CATransform3DMakeScale($0.width / max(bounds.width, 1), $0.height / max(bounds.height, 1), 1)
        } ?? CATransform3DIdentity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.removeAnimation(forKey: "notchExpansion")
        stageLayer.transform = target
        if duration > 0 {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: previous)
            animation.toValue = NSValue(caTransform3D: target)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            stageLayer.add(animation, forKey: "notchExpansion")
        }
        CATransaction.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {
    private let shelf = Shelf()
    private var panel: NotchPanel!
    private var surface: PanelSurface!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var closeWork: DispatchWorkItem?
    private var suspended = false
    private var fastPointerCheck = false
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var compact = NSRect.zero
    private var expanded = NSRect.zero
    private var activationZone = NotchActivationZone(notch: .zero, extensionPoints: 0)
    private var lastInside = Date()
    private var activeShare: NSSharingService?
    private var choosing = false
    private var settingsWindow: NSWindow?
    private var pointsPerMillimeter: CGFloat = 4
    private var transitionID = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        surface = PanelSurface(shelf: shelf)
        panel.contentView = surface
        surface.hosting.alphaValue = 0
        shelf.focusPanel = { [weak self] in self?.panel.makeKey() }
        shelf.closePanel = { [weak self] in self?.setExpanded(false) }
        shelf.presentationChanged = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.shelf.activeSections.map(\.rawValue), forKey: "activeSections")
            self.configureScreen()
        }
        shelf.modulesChanged = { [weak self] in self?.applyModules() }
        shelf.share = { [weak self] in self?.airDrop($0) }
        shelf.choose = { [weak self] in self?.chooseFiles() }
        shelf.interaction = { [weak self] in self?.lastInside = Date() }
        let savedWidth = UserDefaults.standard.double(forKey: "panelWidth")
        if (520...680).contains(savedWidth) { shelf.panelWidth = savedWidth }
        let savedDistance = UserDefaults.standard.double(forKey: "closeDistance")
        if (1...2).contains(savedDistance) { shelf.closeDistance = savedDistance }
        let savedActivationDistance = UserDefaults.standard.double(forKey: "activationDistance")
        if (0...8).contains(savedActivationDistance) { shelf.activationDistance = savedActivationDistance }
        let preferences = UserDefaults.standard
        if let tabs = preferences.stringArray(forKey: "enabledTabs") { shelf.enabledTabs = Set(tabs.compactMap(PanelTab.restored)) }
        shelf.allAudioSources = preferences.bool(forKey: "allAudioSources")
        shelf.musicSource = MusicSource(rawValue: preferences.string(forKey: "musicSource") ?? "") ?? .appleMusic
        shelf.showTemperature = preferences.bool(forKey: "showTemperature")
        if let active = preferences.stringArray(forKey: "activeSections") {
            shelf.activeSections = Set(active.compactMap(PanelTab.restored).map(\.section))
        }
        shelf.hideFromDock = preferences.object(forKey: "hideFromDock") as? Bool ?? true
        shelf.hideFromMenuBar = preferences.bool(forKey: "hideFromMenuBar")
        shelf.visibilityChanged = { [weak self] in self?.applyVisibility() }
        shelf.loginChanged = { [weak self] in self?.setStartAtLogin($0) }
        shelf.openLoginSettings = { SMAppService.openSystemSettingsLoginItems() }
        shelf.quit = { NSApp.terminate(nil) }
        shelf.openingAnimation = PanelAnimation.restored(preferences.string(forKey: "openingAnimation") ?? "") ?? .expand
        shelf.closingAnimation = PanelAnimation.restored(preferences.string(forKey: "closingAnimation") ?? "") ?? .expand
        if !preferences.bool(forKey: "notchExpansionEnabled") {
            shelf.openingAnimation = .expand
            shelf.closingAnimation = .expand
            preferences.set(PanelAnimation.expand.rawValue, forKey: "openingAnimation")
            preferences.set(PanelAnimation.expand.rawValue, forKey: "closingAnimation")
            preferences.set(true, forKey: "notchExpansionEnabled")
        }
        let speed = preferences.double(forKey: "animationSpeed")
        if (0.5...2).contains(speed) { shelf.animationSpeed = speed }
        shelf.showIdleOutline = preferences.bool(forKey: "showIdleOutline")
        if let padding = preferences.object(forKey: "idlePadding") as? Double, (0...12).contains(padding) { shelf.idlePadding = padding }
        if let radius = preferences.object(forKey: "idleRadius") as? Double, (0...22).contains(radius) { shelf.idleRadius = radius }
        shelf.previewAnimation = { [weak self] in self?.showShelf() }
        shelf.customize = { [weak self] in self?.showCustomize() }
        shelf.permissions = { [weak self] in
            self?.shelf.settingsCategory = .permissions
            self?.showCustomize()
        }
        shelf.layoutChanged = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.shelf.panelWidth, forKey: "panelWidth")
            UserDefaults.standard.set(self.shelf.closeDistance, forKey: "closeDistance")
            UserDefaults.standard.set(self.shelf.activationDistance, forKey: "activationDistance")
            UserDefaults.standard.set(self.shelf.openingAnimation.rawValue, forKey: "openingAnimation")
            UserDefaults.standard.set(self.shelf.closingAnimation.rawValue, forKey: "closingAnimation")
            UserDefaults.standard.set(self.shelf.animationSpeed, forKey: "animationSpeed")
            UserDefaults.standard.set(self.shelf.showIdleOutline, forKey: "showIdleOutline")
            UserDefaults.standard.set(self.shelf.idlePadding, forKey: "idlePadding")
            UserDefaults.standard.set(self.shelf.idleRadius, forKey: "idleRadius")
            self.configureScreen()
        }
        configureScreen()
        configureMenu()
        applyModules()
        applyVisibility()
        if preferences.bool(forKey: "loginConfigured") {
            refreshLoginStatus()
        } else {
            setStartAtLogin(true)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLoginStatus), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(suspendActivity), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(suspendActivity), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(resumeActivity), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(resumeActivity), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let movement: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: movement) { [weak self] event in
            self?.trackPointer()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: movement) { [weak self] _ in
            self?.trackPointer()
        }
        schedulePointerChecks()
    }

    private func schedulePointerChecks() {
        timer?.invalidate()
        guard !suspended else { return }
        let poll = Timer(timeInterval: fastPointerCheck ? 1.0 / 30 : 0.5, repeats: true) { [weak self] _ in self?.trackPointer() }
        poll.tolerance = fastPointerCheck ? 0.005 : 0.1
        RunLoop.main.add(poll, forMode: .common)
        RunLoop.main.add(poll, forMode: .eventTracking)
        timer = poll
    }

    @objc private func suspendActivity() {
        suspended = true
        timer?.invalidate()
        closeWork?.cancel()
        closeWork = nil
        transitionID += 1
        shelf.expanded = false
        shelf.editingNote = false
        shelf.music.cancelRefresh()
        shelf.weather.setSuspended(true)
        panel.orderOut(nil)
        surface.isCompact = true
        surface.reveal(nil)
    }

    @objc private func resumeActivity() {
        suspended = false
        fastPointerCheck = false
        shelf.weather.setSuspended(false)
        configureScreen()
        schedulePointerChecks()
        trackPointer()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shelf.nonemptyNoteCount > 0 else { return .terminateNow }
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        choosing = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Discard temporary notes and quit?"
        alert.informativeText = "Your temporary notes contain text. Quitting will discard it. Keep BetterNotch open to continue working."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep BetterNotch Open")
        alert.addButton(withTitle: "Discard Notes and Quit")
        let choice = alert.runModal()
        choosing = false
        if choice == .alertSecondButtonReturn { return .terminateNow }
        lastInside = Date()
        if wasVisible { panel.orderFrontRegardless() }
        return .terminateCancel
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "BetterNotch")
        let menu = NSMenu()
        for (title, action, key) in [("Open BetterNotch", #selector(showShelf), ""), ("Add Files…", #selector(chooseFiles), ""), ("Clear Shelf", #selector(clearShelf), ""), ("Settings…", #selector(showCustomize), ","), ("Quit BetterNotch", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
    }

    private func applyModules() {
        UserDefaults.standard.set(shelf.enabledTabs.map(\.rawValue), forKey: "enabledTabs")
        UserDefaults.standard.set(shelf.activeSections.map(\.rawValue), forKey: "activeSections")
        UserDefaults.standard.set(shelf.showTemperature, forKey: "showTemperature")
        UserDefaults.standard.set(shelf.musicSource.rawValue, forKey: "musicSource")
        if shelf.music.source != shelf.musicSource { shelf.music.source = shelf.musicSource }
        shelf.weather.setEnabled(shelf.showTemperature)
        UserDefaults.standard.set(shelf.allAudioSources, forKey: "allAudioSources")
        if shelf.music.allAudioSources != shelf.allAudioSources { shelf.music.allAudioSources = shelf.allAudioSources }
        shelf.music.setEnabled(shelf.enabledTabs.contains(.music))
        configureScreen()
    }

    private func applyVisibility() {
        UserDefaults.standard.set(shelf.hideFromDock, forKey: "hideFromDock")
        UserDefaults.standard.set(shelf.hideFromMenuBar, forKey: "hideFromMenuBar")
        NSApp.setActivationPolicy(shelf.hideFromDock ? .accessory : .regular)
        statusItem.isVisible = !shelf.hideFromMenuBar
    }

    private func setStartAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            UserDefaults.standard.set(true, forKey: "loginConfigured")
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            shelf.loginNeedsAttention = true
            shelf.loginStatus = "macOS could not update the login item. Try again or check Login Items in System Settings."
        }
    }

    @objc private func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            shelf.startAtLogin = true
            shelf.loginStatus = "BetterNotch will start automatically when you sign in."
            shelf.loginNeedsAttention = false
        case .requiresApproval:
            shelf.startAtLogin = true
            shelf.loginStatus = "Allow BetterNotch in System Settings → General → Login Items to finish enabling this."
            shelf.loginNeedsAttention = true
        case .notRegistered:
            shelf.startAtLogin = false
            shelf.loginStatus = "Start at login is off."
            shelf.loginNeedsAttention = false
        case .notFound:
            shelf.startAtLogin = false
            shelf.loginStatus = "macOS could not locate the login item. Keep BetterNotch in a permanent location and retry."
            shelf.loginNeedsAttention = true
        @unknown default:
            shelf.startAtLogin = false
            shelf.loginStatus = "Login item status is unavailable."
            shelf.loginNeedsAttention = true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showCustomize()
        return true
    }

    @objc private func screenChanged() { configureScreen() }

    private func configureScreen() {
        guard !suspended else { return }
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first else {
            transitionID += 1
            panel.orderOut(nil)
            return
        }
        closeWork?.cancel()
        closeWork = nil
        let top = screen.frame.maxY
        let notchHeight = max(screen.safeAreaInsets.top, 24)
        var center = screen.frame.midX
        var width: CGFloat = 180
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = max(100, right.minX - left.maxX)
            center = (left.maxX + right.minX) / 2
        }
        shelf.topInset = notchHeight
        shelf.notchWidth = width
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let physicalWidth = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value)).width
            if physicalWidth > 0 { pointsPerMillimeter = screen.frame.width / physicalWidth }
        }
        let padding = shelf.showIdleOutline ? CGFloat(shelf.idlePadding) : 0
        compact = NSRect(x: center - width / 2 - padding, y: top - notchHeight - padding, width: width + padding * 2, height: notchHeight + padding)
        expanded = NSRect(x: center - shelf.effectivePanelWidth / 2, y: top - notchHeight - shelf.contentHeight, width: shelf.effectivePanelWidth, height: notchHeight + shelf.contentHeight)
        let physicalNotch = NSRect(x: center - width / 2, y: top - notchHeight, width: width, height: notchHeight)
        activationZone = NotchActivationZone(notch: physicalNotch, extensionPoints: CGFloat(shelf.activationDistance) * pointsPerMillimeter)
        transitionID += 1
        if !shelf.expanded { panel.orderOut(nil) }
        surface.isCompact = !shelf.expanded
        surface.reveal(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(shelf.expanded ? expanded : compact, display: true)
            panel.animator().alphaValue = 1
            surface.hosting.animator().alphaValue = shelf.expanded ? 1 : 0
        }
        surface.needsLayout = true
        if shelf.expanded || shelf.showIdleOutline { panel.orderFrontRegardless() }
        else { panel.orderOut(nil) }
    }

    private func trackPointer() {
        guard !suspended else { return }
        let dragging = NSEvent.pressedMouseButtons != 0
        if fastPointerCheck != dragging {
            fastPointerCheck = dragging
            schedulePointerChecks()
        }
        let pointer = NSEvent.mouseLocation
        let margin = CGFloat(shelf.closeDistance) * pointsPerMillimeter
        let closeBoundary = CGPath(roundedRect: expanded.insetBy(dx: -margin, dy: -margin), cornerWidth: 22 + margin, cornerHeight: 22 + margin, transform: nil)
        let inside = shelf.expanded ? closeBoundary.contains(pointer) : activationZone.contains(pointer)
        if inside {
            closeWork?.cancel()
            closeWork = nil
            lastInside = Date()
            if !shelf.expanded { setExpanded(true) }
        } else if shelf.expanded && !choosing && !shelf.editingNote && activeShare == nil && !dragging {
            let remaining = 0.06 - Date().timeIntervalSince(lastInside)
            if remaining <= 0 {
                closeWork?.cancel()
                closeWork = nil
                setExpanded(false)
            } else if closeWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.closeWork = nil
                    self?.trackPointer()
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
            }
        }
    }

    private func setExpanded(_ value: Bool) {
        guard shelf.expanded != value else { return }
        transitionID += 1
        let currentTransition = transitionID
        let needsOpeningStart = !panel.isVisible || surface.isCompact
        shelf.expanded = value
        if !value { shelf.editingNote = false }
        surface.isCompact = false
        let style = value ? shelf.openingAnimation : shelf.closingAnimation
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || style == .instant
            ? 0 : (value ? 0.3 : 0.22) / shelf.animationSpeed
        let notchShape = NSRect(x: (expanded.width - shelf.notchWidth) / 2,
                                y: expanded.height - shelf.topInset,
                                width: shelf.notchWidth, height: shelf.topInset)
        if value {
            shelf.message = nil
            if needsOpeningStart {
                panel.orderOut(nil)
                panel.setFrame(expanded, display: true)
                surface.needsLayout = true
                surface.layoutSubtreeIfNeeded()
                surface.reveal(style == .expand && duration > 0 ? notchShape : nil)
                panel.alphaValue = style == .fade && duration > 0 ? 0 : 1
                surface.hosting.alphaValue = 1
            }
            panel.orderFrontRegardless()
        }
        surface.reveal(!value && style == .expand ? notchShape : nil, duration: style == .expand ? duration : 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().alphaValue = !value && style == .fade ? 0 : 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.transitionID == currentTransition else { return }
            if !value {
                self.panel.orderOut(nil)
                self.surface.isCompact = true
                self.surface.hosting.alphaValue = 0
                self.surface.reveal(nil)
                self.panel.setFrame(self.compact, display: true)
                self.panel.alphaValue = 1
            }
            self.surface.needsLayout = true
            self.surface.layoutSubtreeIfNeeded()
            if !value && self.shelf.showIdleOutline { self.panel.orderFrontRegardless() }
        }
    }

    @objc private func showShelf() {
        lastInside = Date().addingTimeInterval(2)
        setExpanded(true)
        panel.orderFrontRegardless()
    }

    @objc private func showCustomize() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 570), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "BetterNotch"
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: CustomizeView(shelf: shelf))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func clearShelf() { shelf.files.removeAll() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func chooseFiles() {
        choosing = true
        showShelf()
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = true
        picker.canChooseFiles = true
        picker.prompt = "Add to Shelf"
        picker.begin { [weak self] response in
            guard let self else { return }
            if response == .OK { self.shelf.add(picker.urls) }
            self.choosing = false
            self.lastInside = Date()
        }
    }

    private func airDrop(_ urls: [URL]) {
        guard activeShare == nil else { return }
        guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            shelf.message = "A file is unavailable. Remove it and add its current location."
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            shelf.message = "AirDrop is unavailable. Check Wi-Fi and Bluetooth."
            return
        }
        activeShare = service
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        activeShare = nil
        shelf.message = "AirDrop finished."
        lastInside = Date()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        activeShare = nil
        shelf.message = "AirDrop did not complete. You can try again."
        lastInside = Date()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        closeWork?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }
}
