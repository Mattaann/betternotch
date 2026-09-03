import AppKit
import SwiftUI
import QuartzCore

@main
struct CoreChecks {
    @MainActor static func main() {
        let shelf = Shelf()
        shelf.music.setEnabled(false)
        precondition(shelf.nonemptyNoteCount == 0)
        shelf.addNote()
        shelf.notes[0].text = "   "
        precondition(shelf.nonemptyNoteCount == 0)
        shelf.notes[0].text = "Example draft"
        precondition(shelf.nonemptyNoteCount == 1)
        shelf.select(.notes)
        shelf.select(.notes)
        precondition(shelf.nonemptyNoteCount == 1)
        shelf.deleteNote()
        precondition(shelf.nonemptyNoteCount == 0)
        let playing = PlayingTrack(application: "com.spotify.client", title: "Example", artist: "Artist", playing: true, artworkData: nil, artworkURL: nil)
        let paused = PlayingTrack(application: "com.apple.Music", title: "Example", artist: "Artist", playing: false, artworkData: nil, artworkURL: nil)
        precondition(PlaybackSummary.resolve(track: playing, playerDenied: false, browserUnavailable: false, playerFailed: false).message == "Playing · Spotify")
        precondition(PlaybackSummary.resolve(track: paused, playerDenied: false, browserUnavailable: false, playerFailed: false).state == .paused)
        precondition(PlaybackSummary.resolve(track: nil, playerDenied: true, browserUnavailable: false, playerFailed: false).state == .permission)
        precondition(PlaybackSummary.resolve(track: nil, playerDenied: false, browserUnavailable: false, playerFailed: true).state == .unavailable)
        precondition(PlaybackSummary.resolve(track: nil, playerDenied: false, browserUnavailable: false, playerFailed: false).state == .idle)
        let view = PanelSurface(shelf: shelf)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 442)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let notch = NSRect(x: 220, y: 410, width: 200, height: 32)
        for _ in 0..<50 { view.reveal(notch, duration: 0.22); view.reveal(nil, duration: 0.3) }
        view.reveal(nil)
        precondition(CATransform3DIsIdentity(view.subviews[0].layer!.transform))
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 150)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        precondition(view.subviews[0].layer!.position == CGPoint(x: 360, y: 150))
        for offset in [CGPoint(x: 0, y: 0), CGPoint(x: -1920, y: 0), CGPoint(x: 0, y: 1080)] {
            let rect = NSRect(x: 500 + offset.x, y: 900 + offset.y, width: 200, height: 32)
            let zone = NotchActivationZone(notch: rect, extensionPoints: 0)
            precondition(zone.contains(CGPoint(x: rect.midX, y: rect.minY)))
            precondition(!zone.contains(CGPoint(x: rect.midX, y: rect.minY - 1)))
        }
        print("Passed: temporary-note protection conditions, playback states/source labels, 50 animation reversals, resized layer anchor, and translated display coordinates.")
    }
}
