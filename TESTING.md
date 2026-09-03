# Verification

## Automated checks

On macOS with Xcode command-line tools and Python 3:

```sh
bash Tests/run.sh
```

The checks cover meaningful-note detection, hiding and deleting notes, playback status and source labels, repeated animation reversals, layer anchoring after resizing, and activation coordinates across display origins. They compile the relevant production types into a temporary test executable. They do not activate media players or request browser permissions.

With Node.js installed, the script also checks extension JavaScript syntax, metadata extraction, pause commands, stable media targeting, and muted-media exclusion. Run these independently with:

```sh
node Tests/browser-media.cjs
```

Release compilation and these focused checks passed during the release preparation. A separate local integration check covered Firefox pairing rejection, metadata delivery, command delivery, and clearing inactive media. These checks do not replace testing against real browser tabs.

## Manual acceptance checks

- Visit each Settings category. Confirm readable controls, scrolling, and persistence after relaunch.
- Approach the notch from below and both sides with opening deadzone at zero. Confirm immediate expansion on contact and quick closing outside the configured distance. Repeat while dragging a file and while rapidly reversing direction.
- Toggle Files, Music, Calendar, and Notes independently. Confirm stacking order and that hidden sections leave no gaps.
- Drag a file into Finder. Confirm its shelf reference disappears while the original remains. Cancel a second drag and confirm the reference stays.
- Write a disposable note and quit. Choose Keep BetterNotch Open and confirm the text remains. Repeat with Discard Notes and Quit, relaunch, and confirm temporary notes are empty.
- Connect each installed media app from Permissions. Test initial consent, denied access, paused playback, and missing media. For Safari and Chrome, verify JavaScript access with a normal web page open.
- Load and pair the Firefox extension, refresh an existing video tab, then test play/pause from the notch. Disable browser audio and confirm collection stops. Confirm private Firefox windows are excluded.
- Enable local temperature. Test allowed and denied location access and an unavailable network connection.
- Sleep and wake with the panel both open and closed. Enter and leave fullscreen, switch Spaces, and connect or disconnect an external display. Verify panel placement and responsiveness.
- Compare idle CPU activity with the panel closed, open with media, and during dragging. No battery-life improvement has been benchmarked.

Physical display changes, sleep/wake behavior, actual browser consent dialogs, and real AirDrop transfers still require manual verification on the target Mac.
