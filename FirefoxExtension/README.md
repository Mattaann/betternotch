# Firefox setup

1. In BetterNotch, enable Music and Include browser audio in Settings.
2. In Firefox, open `about:debugging`, choose This Firefox, then Load Temporary Add-on. Select `manifest.json` in this folder.
3. Refresh any already-open media tabs so the extension can connect to them.
4. In BetterNotch Settings → Permissions → Firefox, click Copy Pairing Key.
5. Open the BetterNotch extension from Firefox's toolbar, paste the key, and click Connect.
6. Play a video or audio track and open the BetterNotch music section. Allow a few seconds for the initial connection.

This development extension must be loaded again after Firefox restarts. Permanent installation in standard Firefox requires a Mozilla-signed release; this build is not signed or published.

The extension communicates only with BetterNotch at 127.0.0.1:49327 using a pairing key. Keep the key private. Only the pairing key is stored by the extension. Media titles, artists, artwork URLs, and playback state remain in memory. Private windows are excluded. Media collection pauses shortly after the notch closes; lightweight local connection checks continue while the extension is loaded. Disable the extension to stop them completely.

Play/pause works for accessible HTML audio/video. Next/previous are offered when YouTube provides the corresponding buttons. Protected pages, unsupported players, Web Audio without an HTML media element, and some embedded media are not supported. No audio is recorded. Browser permission to access websites is needed to find media elements; the extension does not transmit page contents or browsing history.

Chrome and Safari use BetterNotch's built-in Automation integration and do not need this extension.
