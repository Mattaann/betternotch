const tokens = new WeakMap();
const visibleButton = selector => {
  const button = document.querySelector(selector);
  return button && button.getAttribute('aria-disabled') !== 'true' && button.offsetParent !== null ? button : null;
};
browser.runtime.onMessage.addListener(async message => {
  if (message.type !== 'collect' && message.type !== 'control') return;
  const media = [...document.querySelectorAll('video,audio')];
  if (message.type === 'control') {
    const item = media.find(item => tokens.get(item) === message.token);
    if (!item) return {ok: false};
    if (message.command === 'playpause') {
      try { if (item.paused) await item.play(); else item.pause(); } catch { return {ok: false}; }
    } else {
      const selector = message.command === 'next track' ? '.ytp-next-button' : message.command === 'previous track' ? '.ytp-prev-button' : null;
      const button = selector && visibleButton(selector);
      if (!button) return {ok: false};
      button.click();
    }
    return {ok: true};
  }
  const items = media.filter(item => !item.ended && item.readyState >= 1 && !item.muted && item.volume > 0 && (!item.paused || item.currentTime > 0));
  const item = items.find(item => !item.paused) || items[0];
  let track = null;
  if (item) {
    if (!tokens.has(item)) tokens.set(item, crypto.randomUUID());
    const metadata = navigator.mediaSession?.metadata;
    track = {
      token: tokens.get(item), title: (metadata?.title || document.title || 'Firefox media').slice(0, 500),
      artist: (metadata?.artist || 'Browser audio').slice(0, 500), playing: !item.paused,
      artwork: (metadata?.artwork?.[0]?.src || item.poster || '').slice(0, 4000),
      previous: !!visibleButton('.ytp-prev-button'), next: !!visibleButton('.ytp-next-button')
    };
  }
  await browser.runtime.sendMessage({type: 'frameMedia', track});
});
