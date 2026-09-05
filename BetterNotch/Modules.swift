import Network
import AppKit
import SwiftUI
import CoreLocation

struct QuickNotesView: View {
    @ObservedObject var shelf: Shelf
    @FocusState private var focused: Bool

    private var text: Binding<String> {
        Binding(get: {
            shelf.notes.first(where: { $0.id == shelf.selectedNoteID })?.text ?? ""
        }, set: { value in
            if let index = shelf.notes.firstIndex(where: { $0.id == shelf.selectedNoteID }) { shelf.notes[index].text = value }
        })
    }

    var body: some View {
        HStack(spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(shelf.notes) { note in
                        Button {
                            shelf.selectedNoteID = note.id
                            focused = true
                        } label: {
                            Text(note.text.isEmpty ? "New note" : String(note.text.prefix(40)))
                                .font(.system(size: 10)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(5)
                                .background(shelf.selectedNoteID == note.id ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }.frame(width: 112)
            if shelf.selectedNoteID != nil {
                TextEditor(text: text)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(6)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .onChange(of: focused) { shelf.editingNote = $0 }
                    .onExitCommand { focused = false; shelf.closePanel?() }
            } else {
                Text("No notes yet. Press + to add one.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear { shelf.focusPanel?(); focused = shelf.selectedNoteID != nil }
        .onChange(of: shelf.selectedNoteID) { _ in
            shelf.focusPanel?()
            focused = shelf.selectedNoteID != nil
        }
        .onChange(of: shelf.editingNote) { editing in
            if !editing { focused = false }
        }
        .onDisappear { shelf.editingNote = false }
    }
}

struct TemperatureBadge: View {
    @ObservedObject var weather: WeatherController
    var openPermissions: () -> Void = {}
    var body: some View {
        Button { if weather.temperature == nil { openPermissions() } else { weather.refresh() } } label: {
            Text(weather.temperature.map { "\(Int($0.rounded()))°" } ?? "—°")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .frame(minWidth: 28, minHeight: 24)
        }.help(weather.status)
    }
}

final class WeatherController: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var temperature: Double?
    @Published var status = "Enable local temperature in Settings"
    private let manager = CLLocationManager()
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionDataTask?
    private var timer: Timer?
    private var enabled = false
    private var requestedLocation = false
    private var suspended = false
    private var generation = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        generation += 1
        timer?.invalidate()
        if value {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in self?.refresh() }
        } else {
            manager.stopUpdatingLocation()
            task?.cancel()
            requestedLocation = false
            temperature = nil
        }
    }

    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        generation += 1
        timer?.invalidate()
        if value {
            manager.stopUpdatingLocation()
            task?.cancel()
            requestedLocation = false
        } else if enabled {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    func refresh() {
        guard enabled, !suspended else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            status = "Allow location access to show local temperature"
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            guard !requestedLocation else { return }
            requestedLocation = true
            status = "Updating local temperature…"
            manager.requestLocation()
        default:
            temperature = nil
            status = "Allow BetterNotch in System Settings → Privacy & Security → Location Services"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { refresh() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        requestedLocation = false
        guard enabled, !suspended else { return }
        guard let location = locations.last, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 300 else {
            temperature = nil
            status = "Location unavailable. Click to retry."
            return
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        let latitude = (location.coordinate.latitude * 100).rounded() / 100
        let longitude = (location.coordinate.longitude * 100).rounded() / 100
        components.queryItems = [URLQueryItem(name: "latitude", value: String(latitude)), URLQueryItem(name: "longitude", value: String(longitude)), URLQueryItem(name: "current", value: "temperature_2m")]
        guard let url = components.url else { return }
        task?.cancel()
        generation += 1
        let requestGeneration = generation
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        task = session.dataTask(with: request) { [weak self] data, response, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let value = (json?["current"] as? [String: Any])?["temperature_2m"] as? Double
            DispatchQueue.main.async {
                guard let self, self.enabled, self.generation == requestGeneration else { return }
                if (response as? HTTPURLResponse)?.statusCode == 200, let value, value.isFinite {
                    self.temperature = value
                    self.status = "Local temperature in °C · Open-Meteo · Click to refresh"
                } else {
                    self.temperature = nil
                    self.status = "Weather unavailable. Click to retry."
                }
            }
        }
        task?.resume()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard enabled, !suspended else { return }
        requestedLocation = false
        temperature = nil
        status = "Location unavailable. Click to retry."
    }
}

enum MusicSource: String, CaseIterable, Identifiable {
    case appleMusic = "Apple Music", spotify = "Spotify"
    var id: String { rawValue }
    var bundleID: String { self == .appleMusic ? "com.apple.Music" : "com.spotify.client" }
}

struct PlayingTrack {
    let application: String
    let title: String
    let artist: String
    let playing: Bool
    let artworkData: Data?
    let artworkURL: URL?
    var browserToken: String? = nil
    var canPrevious = true
    var canNext = true
    var sourceName: String {
        switch application {
        case "com.apple.Music": return "Apple Music"
        case "com.spotify.client": return "Spotify"
        case "com.apple.Safari": return "Safari"
        case "com.google.Chrome": return "Chrome"
        case "org.mozilla.firefox": return "Firefox"
        default: return "Media player"
        }
    }
    var identity: String { application + (browserToken ?? "") + title + artist }
}

enum PlaybackStatus: String {
    case idle = "Nothing playing", loading = "Checking playback", playing = "Playing", paused = "Paused", permission = "Permission needed", unavailable = "Unavailable"
}

struct PlaybackSummary {
    let state: PlaybackStatus
    let message: String
    let accessMessage: String?

    static func resolve(track: PlayingTrack?, playerDenied: Bool, browserUnavailable: Bool, playerFailed: Bool) -> PlaybackSummary {
        let access = browserUnavailable ? "Browser access unavailable. Check Firefox extension pairing, or Automation and JavaScript permissions for Chrome and Safari." : (playerDenied ? "Allow the player in System Settings → Privacy & Security → Automation." : nil)
        if let track {
            let state: PlaybackStatus = track.playing ? .playing : .paused
            return PlaybackSummary(state: state, message: "\(state.rawValue) · \(track.sourceName)", accessMessage: access)
        }
        if playerDenied {
            return PlaybackSummary(state: .permission, message: "Allow player access in System Settings → Privacy & Security → Automation.", accessMessage: access)
        }
        if browserUnavailable || playerFailed {
            return PlaybackSummary(state: .unavailable, message: browserUnavailable ? "Browser access unavailable. Open Permissions to connect your browser." : "The player did not respond. Try refreshing.", accessMessage: access)
        }
        return PlaybackSummary(state: .idle, message: "No active media in the selected sources.", accessMessage: nil)
    }
}

final class MusicController: ObservableObject {
    @Published var allAudioSources = false {
        didSet {
            FirefoxBridge.shared.setEnabled(allAudioSources && enabled)
            generation += 1
            track = nil
            artwork = nil
            artworkTask?.cancel()
            playbackStatus = .idle
            status = "Open the music section to check playback."
            controlMessage = nil
            accessMessage = nil
        }
    }
    @Published var source: MusicSource = .appleMusic {
        didSet {
            generation += 1
            track = nil
            artwork = nil
            artworkTask?.cancel()
            status = "Play music in \(source.rawValue)"
            playbackStatus = .idle
            controlMessage = nil
            accessMessage = nil
        }
    }
    @Published var track: PlayingTrack?
    @Published var artwork: NSImage?
    @Published var status = "Play music in the selected app"
    @Published var playbackStatus: PlaybackStatus = .idle
    @Published var controlMessage: String?
    @Published var accessMessage: String?
    private var enabled = true
    @Published private(set) var busy = false
    private var generation = 0
    private let queue = DispatchQueue(label: "app.betternotch.music")
    private let session = URLSession(configuration: .ephemeral)
    private var artworkTask: URLSessionDataTask?

    func setEnabled(_ value: Bool) {
        enabled = value
        FirefoxBridge.shared.setEnabled(value && allAudioSources)
        if !value {
            generation += 1
            track = nil
            artwork = nil
            artworkTask?.cancel()
            playbackStatus = .idle
            status = "Music is disabled. Enable it in Modules."
            controlMessage = nil
            accessMessage = nil
        }
    }

    func cancelRefresh() {
        FirefoxBridge.shared.stopUpdates()
        generation += 1
        artworkTask?.cancel()
        if playbackStatus == .loading {
            playbackStatus = .idle
            status = "Open the music section to check playback."
        }
    }

    func refresh() {
        guard enabled, !busy else { return }
        let applications = [source.bundleID].filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        let browsers = allAudioSources ? BrowserMedia.applications.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } : []
        guard !applications.isEmpty || !browsers.isEmpty else {
            track = nil
            artwork = nil
            playbackStatus = .idle
            status = allAudioSources ? "Open a supported player or browser to begin." : "Open \(source.rawValue) to begin."
            accessMessage = nil
            return
        }
        busy = true
        if track == nil { playbackStatus = .loading }
        let requestGeneration = generation
        queue.async { [weak self] in
            var tracks: [PlayingTrack] = []
            var denied = false
            var failed = false
            for application in applications {
                let music = application == "com.apple.Music"
                let art = music ? "try\nset coverData to raw data of artwork 1 of current track\nend try" : "set coverURL to artwork url of current track"
                let source = """
                with timeout of 3 seconds
                    tell application id "\(application)"
                        if player state is stopped then return {}
                        set coverData to ""
                        set coverURL to ""
                        \(art)
                        return {name of current track, artist of current track, player state as text, coverData, coverURL}
                    end tell
                end timeout
                """
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int
                    if code == -1743 || code == -10004 { denied = true } else { failed = true }
                    continue
                }
                guard let result, result.numberOfItems >= 5, let title = result.atIndex(1)?.stringValue, !title.isEmpty else { continue }
                let raw = result.atIndex(4)?.data
                let data = raw.flatMap { NSImage(data: $0) != nil ? $0 : nil }
                let url = result.atIndex(5)?.stringValue.flatMap(URL.init(string:))
                tracks.append(PlayingTrack(application: application, title: title, artist: result.atIndex(2)?.stringValue ?? "", playing: result.atIndex(3)?.stringValue == "playing", artworkData: data, artworkURL: url))
            }
            var browserTracks: [PlayingTrack] = []
            var browserDenied = false
            var unavailableBrowsers: [String] = []
            for browser in browsers {
                let result = BrowserMedia.read(browser)
                browserTracks.append(contentsOf: result.tracks)
                browserDenied = browserDenied || result.denied
                if result.denied { unavailableBrowsers.append(browser == "org.mozilla.firefox" ? "Firefox" : browser == "com.apple.Safari" ? "Safari" : "Chrome") }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard self.enabled, self.generation == requestGeneration else { return }
                let next = browserTracks.first(where: \.playing) ?? tracks.first(where: \.playing) ?? browserTracks.first ?? tracks.first
                if next?.identity != self.track?.identity { self.artwork = nil }
                self.track = next
                let summary = PlaybackSummary.resolve(track: next, playerDenied: denied, browserUnavailable: browserDenied, playerFailed: failed)
                self.playbackStatus = summary.state
                self.status = summary.message
                self.accessMessage = unavailableBrowsers.isEmpty ? summary.accessMessage : "Connect \(unavailableBrowsers.joined(separator: ", ")) in Permissions."
                if next == nil && !unavailableBrowsers.isEmpty { self.status = self.accessMessage! }
                if let next, self.artwork == nil { self.loadArtwork(next) }
            }
        }
    }

    private func loadArtwork(_ track: PlayingTrack) {
        if let data = track.artworkData { artwork = NSImage(data: data); return }
        guard let url = track.artworkURL, url.scheme == "https" else { return }
        artworkTask?.cancel()
        let requestGeneration = generation
        artworkTask = session.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self, self.enabled, self.generation == requestGeneration, self.track?.identity == track.identity else { return }
                self.artwork = data.flatMap(NSImage.init(data:))
            }
        }
        artworkTask?.resume()
    }

    func command(_ command: String) {
        guard let track, ["playpause", "next track", "previous track"].contains(command), !busy else { return }
        busy = true
        queue.async { [weak self] in
            var error: NSDictionary?
            if let token = track.browserToken {
                if !BrowserMedia.control(track.application, token: token, command: command) {
                    error = ["failed": true]
                }
            } else {
                NSAppleScript(source: "with timeout of 3 seconds\ntell application id \"\(track.application)\" to \(command)\nend timeout")?.executeAndReturnError(&error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if error != nil {
                    self.controlMessage = "Control failed. Check media permissions."
                } else {
                    self.controlMessage = nil
                    self.refresh()
                }
            }
        }
    }
}

struct NowPlayingView: View {
    @ObservedObject var music: MusicController
    let active: Bool
    var openPermissions: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            if let track = music.track {
                Group {
                    if let artwork = music.artwork { Image(nsImage: artwork).resizable().scaledToFill() }
                    else { Image(systemName: "music.note").font(.system(size: 24)).frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.08)) }
                }.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(track.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text(music.controlMessage ?? "\(track.playing ? "Playing" : "Paused") · \(track.sourceName)")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { music.command("previous track") } label: { Image(systemName: "backward.fill").frame(width: 28, height: 32) }.help("Previous track").disabled(!track.canPrevious)
                Button { music.command("playpause") } label: { Image(systemName: track.playing ? "pause.fill" : "play.fill").frame(width: 28, height: 32) }.help("Play or pause")
                Button { music.command("next track") } label: { Image(systemName: "forward.fill").frame(width: 28, height: 32) }.help("Next track").disabled(!track.canNext)
                if music.controlMessage != nil || music.accessMessage != nil {
                    Button(action: openPermissions) { Image(systemName: "exclamationmark.shield") }.help("Open Permissions")
                }
            } else {
                Image(systemName: "music.note").font(.system(size: 22))
                VStack(alignment: .leading, spacing: 5) {
                    Text(music.playbackStatus.rawValue).font(.system(size: 12, weight: .medium))
                    Text(music.status).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if music.playbackStatus == .unavailable || music.playbackStatus == .permission {
                    Button("Permissions", action: openPermissions)
                } else {
                    Button { music.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                }
            }
        }
        .task(id: active) {
            guard active else { return }
            while !Task.isCancelled {
                music.refresh()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
        .onChange(of: active) { if !$0 { music.cancelRefresh() } }
        .onDisappear { music.cancelRefresh() }
    }
}

struct NotchCalendar {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_GB")
        value.timeZone = .current
        value.firstWeekday = 2
        return value
    }

    static func days(in month: Date) -> [Date?] {
        let calendar = calendar
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return (0..<42).map { cell in
            let day = cell - offset
            return day >= 0 && day < range.count ? calendar.date(byAdding: .day, value: day, to: start) : nil
        }
    }
}

struct MiniCalendarView: View {
    @State private var month = Date()
    @State private var selected = Date()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let weekdays = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selected.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "en_GB"))))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("\(NotchCalendar.calendar.component(.day, from: selected))")
                    .font(.system(size: 36, weight: .light)).monospacedDigit()
                Text(selected.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_GB"))))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Today") { month = Date(); selected = Date() }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.1), in: Capsule())
            }.frame(width: 126, alignment: .leading)
            VStack(spacing: 4) {
                HStack {
                    Text(month.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_GB"))))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 20) }
                        .help("Previous month")
                    Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 20) }
                        .help("Next month")
                }
                LazyVGrid(columns: columns, spacing: 1) {
                    ForEach(0..<7, id: \.self) { index in
                        Text(weekdays[index]).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary).frame(height: 14)
                    }
                    ForEach(Array(NotchCalendar.days(in: month).enumerated()), id: \.offset) { _, date in
                        if let date {
                            let isSelected = NotchCalendar.calendar.isDate(date, inSameDayAs: selected)
                            let isToday = NotchCalendar.calendar.isDateInToday(date)
                            Button { selected = date } label: {
                                Text("\(NotchCalendar.calendar.component(.day, from: date))")
                                    .font(.system(size: 10, weight: isToday ? .bold : .regular))
                                    .frame(maxWidth: .infinity).frame(height: 16)
                                    .foregroundStyle(isSelected ? .black : .white)
                                    .background(isSelected ? .white : .clear, in: RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isToday && !isSelected ? .white.opacity(0.6) : .clear))
                            }.accessibilityLabel(date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "en_GB"))))
                        } else { Color.clear.frame(height: 16) }
                    }
                }
            }
        }.padding(.horizontal, 10)
    }

    private func moveMonth(_ offset: Int) {
        let calendar = NotchCalendar.calendar
        if let start = calendar.dateInterval(of: .month, for: month)?.start,
           let next = calendar.date(byAdding: .month, value: offset, to: start) { month = next }
    }
}

struct BrowserMedia {
    static let applications = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox"]
    static let query = #"""
    (() => {
      const media = [...document.querySelectorAll('video,audio')].filter(m => !m.ended && m.readyState >= 1 && !m.muted && m.volume > 0 && (!m.paused || m.currentTime > 0));
      const item = media.find(m => !m.paused) || media[0];
      if (!item) return '';
      if (!item.__betterNotchToken) item.__betterNotchToken = crypto.randomUUID();
      const meta = navigator.mediaSession && navigator.mediaSession.metadata;
      const artwork = meta && meta.artwork && meta.artwork.length ? meta.artwork[0].src : item.poster || '';
      const available = selector => { const b = document.querySelector(selector); return !!b && b.getAttribute('aria-disabled') !== 'true' && b.offsetParent !== null; };
      return JSON.stringify({token:item.__betterNotchToken, title:meta && meta.title || document.title || 'Browser media', artist:meta && meta.artist || 'Browser audio', playing:!item.paused, artwork, previous:available('.ytp-prev-button'), next:available('.ytp-next-button')});
    })()
    """#

    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

    static func script(_ application: String, javascript: String) -> String {
        let execution = application == "com.apple.Safari"
            ? "do JavaScript \(quote(javascript)) in browserTab"
            : "execute browserTab javascript \(quote(javascript))"
        return """
        with timeout of 4 seconds
            tell application id "\(application)"
                set matches to {}
                set failed to false
                set inspected to 0
                repeat with browserWindow in windows
                    repeat with browserTab in tabs of browserWindow
                        set inspected to inspected + 1
                        if inspected > 40 then return {matches, failed}
                        try
                            set payload to \(execution)
                            if payload is not "" then set end of matches to payload
                        on error
                            set failed to true
                        end try
                    end repeat
                end repeat
                return {matches, failed}
            end tell
        end timeout
        """
    }

    static func read(_ application: String) -> (tracks: [PlayingTrack], denied: Bool) {
        if application == "org.mozilla.firefox" { return FirefoxBridge.shared.snapshot() }
        guard applications.contains(application) else { return ([], false) }
        var error: NSDictionary?
        let result = NSAppleScript(source: script(application, javascript: query))?.executeAndReturnError(&error)
        guard error == nil, let result, let matches = result.atIndex(1) else { return ([], true) }
        var tracks: [PlayingTrack] = []
        if matches.numberOfItems > 0 {
            for index in 1...matches.numberOfItems {
                guard let raw = matches.atIndex(index)?.stringValue?.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      let track = decode(value, application: application) else { continue }
                tracks.append(track)
            }
        }
        return (tracks, result.atIndex(2)?.booleanValue ?? false)
    }

    static func decode(_ value: [String: Any], application: String) -> PlayingTrack? {
        guard let token = value["token"] as? String, UUID(uuidString: token) != nil,
              let title = value["title"] as? String else { return nil }
        let artwork = (value["artwork"] as? String).flatMap(URL.init(string:)).flatMap { url in
            ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
        var track = PlayingTrack(application: application, title: String(title.prefix(500)), artist: String((value["artist"] as? String ?? "Browser audio").prefix(500)), playing: value["playing"] as? Bool ?? false, artworkData: nil, artworkURL: artwork)
        track.browserToken = token
        track.canPrevious = value["previous"] as? Bool ?? false
        track.canNext = value["next"] as? Bool ?? false
        return track
    }

    static func control(_ application: String, token: String, command: String) -> Bool {
        guard applications.contains(application), UUID(uuidString: token) != nil,
              ["playpause", "previous track", "next track"].contains(command) else { return false }
        if application == "org.mozilla.firefox" { return FirefoxBridge.shared.control(token: token, command: command) }
        let action: String
        switch command {
        case "playpause": action = "if (item.paused) { item.play().catch(() => {}); } else { item.pause(); }"
        case "next track": action = "const button = document.querySelector('.ytp-next-button'); if (!button || button.getAttribute('aria-disabled') === 'true' || button.offsetParent === null) return ''; button.click();"
        default: action = "const button = document.querySelector('.ytp-prev-button'); if (!button || button.getAttribute('aria-disabled') === 'true' || button.offsetParent === null) return ''; button.click();"
        }
        let javascript = "(() => { const item = [...document.querySelectorAll('video,audio')].find(m => m.__betterNotchToken === '\(token)'); if (!item) return ''; \(action) return 'done'; })()"
        var error: NSDictionary?
        let result = NSAppleScript(source: script(application, javascript: javascript))?.executeAndReturnError(&error)
        return error == nil && (result?.atIndex(1)?.numberOfItems ?? 0) > 0
    }
}

struct AudioSettingsView: View {
    @ObservedObject var shelf: Shelf
    @ObservedObject var music: MusicController

    var body: some View {
        VStack(spacing: 16) {
            GroupBox("Player") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Music source", selection: $shelf.musicSource) {
                        ForEach(MusicSource.allCases) { Text($0.rawValue).tag($0) }
                    }.onChange(of: shelf.musicSource) { _ in shelf.modulesChanged?() }
                    Toggle("Include browser audio", isOn: $shelf.allAudioSources)
                        .onChange(of: shelf.allAudioSources) { _ in shelf.modulesChanged?() }
                    Text("Adds Firefox, Chrome, and Safari playback, including YouTube, alongside your selected player. Playing browser media takes priority. Firefox requires the companion extension. Off by default.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            GroupBox("Playback status") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(music.playbackStatus == .playing ? .white : .gray).frame(width: 6, height: 6)
                        Text(music.playbackStatus.rawValue).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("Refresh") { music.refresh() }
                            .disabled(music.busy || !shelf.enabledTabs.contains(.music))
                    }
                    Text(music.status).font(.system(size: 12)).foregroundStyle(.secondary)
                    if let message = music.accessMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = music.controlMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Playback updates pause when the notch is closed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            GroupBox("Connections") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Set up Apple Music, Spotify, Firefox, Chrome, and Safari from the Permissions page.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Permissions") { shelf.permissions?() }
                }
            }
        }
    }
}

final class FirefoxBridge {
    static let shared = FirefoxBridge()
    let key: String
    private let lock = NSLock()
    private var listener: NWListener?
    private var tracks: [PlayingTrack] = []
    private var received = Date.distantPast
    private var requested = Date.distantPast
    private var pending: [[String: String]] = []

    private init() {
        let defaults = UserDefaults.standard
        key = defaults.string(forKey: "firefoxPairingKey") ?? UUID().uuidString + UUID().uuidString
        defaults.set(key, forKey: "firefoxPairingKey")
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            listener?.cancel()
            listener = nil
            lock.lock()
            tracks = []; pending = []; requested = .distantPast; received = .distantPast
            lock.unlock()
            return
        }
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 49327)
        do {
            let server = try NWListener(using: parameters)
            server.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                self?.receive(connection, buffer: Data())
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { connection.cancel() }
            }
            server.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.listener?.cancel(); self?.listener = nil }
            }
            listener = server
            server.start(queue: .main)
        } catch { listener = nil }
    }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return listener != nil && received.timeIntervalSinceNow > -8
    }

    func snapshot() -> (tracks: [PlayingTrack], denied: Bool) {
        lock.lock(); defer { lock.unlock() }
        requested = Date()
        return received.timeIntervalSinceNow > -8 ? (tracks, false) : ([], true)
    }

    func stopUpdates() {
        lock.lock(); defer { lock.unlock() }
        requested = .distantPast
        pending = []
    }

    func control(token: String, command: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard received.timeIntervalSinceNow > -8, tracks.contains(where: { $0.browserToken == token }), pending.count < 8 else { return false }
        requested = Date()
        pending.append(["token": token, "command": command])
        return true
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 131072, error == nil else { connection.cancel(); return }
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                return
            }
            guard let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else { connection.cancel(); return }
            let lines = header.components(separatedBy: "\r\n")
            guard lines.first == "POST /media HTTP/1.1" else { self.respond(connection, code: 404, value: [:]); return }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
            }
            guard fields["authorization"] == "Bearer \(self.key)" else { self.respond(connection, code: 403, value: [:]); return }
            guard let length = fields["content-length"].flatMap(Int.init), length >= 0, length <= 120000 else { connection.cancel(); return }
            let body = buffer[boundary.upperBound...]
            if body.count < length {
                if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                return
            }
            guard let payload = try? JSONSerialization.jsonObject(with: Data(body.prefix(length))) as? [String: Any] else { self.respond(connection, code: 400, value: [:]); return }
            self.lock.lock()
            let active = self.requested.timeIntervalSinceNow > -6
            if active, let media = payload["tracks"] as? [[String: Any]] {
                self.tracks = media.prefix(40).compactMap { BrowserMedia.decode($0, application: "org.mozilla.firefox") }
            } else if !active { self.tracks = [] }
            self.received = Date()
            let commands = active ? self.pending : []
            self.pending = []
            self.lock.unlock()
            self.respond(connection, code: 200, value: ["active": active, "commands": commands])
        }
    }

    private func respond(_ connection: NWConnection, code: Int, value: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

final class PermissionChecks: ObservableObject {
    @Published var messages: [String: String] = [:]
    @Published var checking: Set<String> = []

    func connect(_ application: String) {
        guard !checking.contains(application) else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: application) else {
            messages[application] = "App not installed. Install it, then try again."
            return
        }
        checking.insert(application)
        messages[application] = "Opening app. Accept the macOS access request if shown…"
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil {
                DispatchQueue.main.async {
                    self.checking.remove(application)
                    self.messages[application] = "Could not open the app. Open it manually and retry."
                }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let browser = ["com.apple.Safari", "com.google.Chrome"].contains(application)
                let script = browser ? BrowserMedia.script(application, javascript: "'BetterNotch access check'") : "with timeout of 10 seconds\ntell application id \"\(application)\" to get player state\nend timeout"
                var failure: NSDictionary?
                let result = NSAppleScript(source: script)?.executeAndReturnError(&failure)
                let message: String
                if let failure {
                    let code = failure[NSAppleScript.errorNumber] as? Int
                    message = code == -1743 || code == -10004 ? "Access denied. Enable BetterNotch for this app in Automation Settings, then retry." : "The app did not respond. Open it and try again."
                } else if browser && result?.atIndex(2)?.booleanValue == true {
                    message = "Enable JavaScript from Apple Events in the browser menu, then retry with a regular web page open."
                } else if browser && (result?.atIndex(1)?.numberOfItems ?? 0) == 0 {
                    message = "Open a regular web page in this browser, then retry to verify JavaScript access."
                } else {
                    message = "Connected. Play media to show it in the notch."
                }
                DispatchQueue.main.async {
                    self.messages[application] = message
                    self.checking.remove(application)
                }
            }
        }
    }
}

struct PermissionsSettingsView: View {
    @ObservedObject var shelf: Shelf
    @ObservedObject var weather: WeatherController
    @StateObject private var checks = PermissionChecks()
    @State private var firefoxStatus = "Load the extension and pair it to connect Firefox."

    private func openSystem(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Only connect the features you use. macOS shows its consent dialog when access is first requested. Previously denied access must be enabled in System Settings.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach([("Apple Music", "com.apple.Music"), ("Spotify", "com.spotify.client"), ("Safari", "com.apple.Safari"), ("Chrome", "com.google.Chrome")], id: \.1) { name, id in
                GroupBox(name) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(checks.messages[id] ?? "Not checked. Connect to request and verify access.").font(.caption).foregroundStyle(.secondary)
                        if id == "com.apple.Safari" { Text("Safari → Develop → Allow JavaScript from Apple Events. If Develop is hidden, enable web developer features in Safari Settings → Advanced.").font(.caption) }
                        if id == "com.google.Chrome" { Text("Chrome → View → Developer → Allow JavaScript from Apple Events.").font(.caption) }
                        HStack {
                            Button(checks.checking.contains(id) ? "Checking…" : "Connect / Retry") {
                                if id == "com.apple.Music" || id == "com.spotify.client" {
                                    shelf.musicSource = id == "com.apple.Music" ? .appleMusic : .spotify
                                } else { shelf.allAudioSources = true }
                                shelf.setTab(.music, enabled: true)
                                shelf.modulesChanged?()
                                checks.connect(id)
                            }.disabled(checks.checking.contains(id))
                            Button("Automation Settings") { openSystem("com.apple.preference.security?Privacy_Automation") }
                        }
                    }
                }
            }
            GroupBox("Firefox") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(firefoxStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Firefox → about:debugging → This Firefox → Load Temporary Add-on → manifest.json. Refresh existing media tabs. Reload the extension after restarting Firefox.").font(.caption)
                    HStack {
                        Button("Show Extension") {
                            if let url = Bundle.main.resourceURL?.appendingPathComponent("FirefoxExtension") { NSWorkspace.shared.open(url) }
                        }
                        Button("Copy Pairing Key") {
                            shelf.allAudioSources = true
                            shelf.setTab(.music, enabled: true)
                            shelf.modulesChanged?()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(FirefoxBridge.shared.key, forType: .string)
                            firefoxStatus = "Paste the key into the Firefox extension popup and click Connect."
                        }
                    }
                    Button("Check Connection") {
                        shelf.allAudioSources = true
                        shelf.setTab(.music, enabled: true)
                        shelf.modulesChanged?()
                        firefoxStatus = "Checking the local extension connection…"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            firefoxStatus = FirefoxBridge.shared.isConnected ? "Connected. Play media and open the music section." : "No connection. Enable the extension, paste the pairing key, then retry."
                        }
                    }
                }
            }
            GroupBox("Location & Weather") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(weather.status).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Enable / Retry") {
                            shelf.showTemperature = true
                            shelf.modulesChanged?()
                            weather.refresh()
                        }
                        Button("Location Settings") { openSystem("com.apple.preference.security?Privacy_LocationServices") }
                    }
                    Text("If location is allowed but weather is unavailable, check your internet connection and retry.").font(.caption).foregroundStyle(.secondary)
                }
            }
            GroupBox("Start at Login") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(shelf.loginStatus.isEmpty ? "Enable automatic launch when you sign in." : shelf.loginStatus).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Enable / Retry") { shelf.loginChanged?(true) }
                        Button("Login Items Settings") { shelf.openLoginSettings?() }
                    }
                }
            }
            GroupBox("Files & AirDrop") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add files using the file picker or drag them from Finder. If an original moved or was deleted, remove its shelf reference and add the current file again. AirDrop needs Wi-Fi, Bluetooth, and a discoverable recipient.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Add Files") { shelf.choose?() }
                        Button("Wi-Fi") { openSystem("com.apple.wifi-settings-extension") }
                        Button("Bluetooth") { openSystem("com.apple.BluetoothSettings") }
                    }
                }
            }
        }
    }
}
