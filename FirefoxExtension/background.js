const endpoint = 'http://127.0.0.1:49327/media';
let status = 'Paste the pairing key from BetterNotch settings.';
let collecting = false;
let reports = new Map();
let routes = new Map();
let active = false;

browser.runtime.onMessage.addListener((message, sender) => {
  if (message.type === 'status') return Promise.resolve({status});
  if (message.type !== 'frameMedia' || !collecting || !sender.tab || sender.tab.incognito || !message.track) return;
  const track = message.track;
  if (typeof track.token !== 'string' || typeof track.title !== 'string' || reports.size >= 40) return;
  reports.set(track.token, track);
  routes.set(track.token, {tabId: sender.tab.id, frameId: sender.frameId});
});

async function tick() {
  const {pairingKey} = await browser.storage.local.get('pairingKey');
  if (!pairingKey) { active = false; setTimeout(tick, 2000); return; }
  try {
    reports = new Map();
    routes = new Map();
    if (active) {
      collecting = true;
      const tabs = (await browser.tabs.query({})).filter(tab => !tab.incognito && /^https?:/.test(tab.url || '')).slice(0, 40);
      await Promise.allSettled(tabs.map(tab => browser.tabs.sendMessage(tab.id, {type: 'collect'})));
      collecting = false;
    }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 2500);
    let response;
    try {
      response = await fetch(endpoint, {
        method: 'POST', headers: {'Authorization': `Bearer ${pairingKey}`, 'Content-Type': 'application/json'},
        body: JSON.stringify({tracks: [...reports.values()]}), signal: controller.signal, cache: 'no-store'
      });
    } finally { clearTimeout(timeout); }
    if (!response.ok) throw new Error(response.status === 403 ? 'Pairing key rejected. Copy it again from BetterNotch.' : 'BetterNotch connection failed.');
    const result = await response.json();
    active = result.active === true;
    status = active ? 'Connected. Media sharing is active.' : 'Connected. Open the music section in BetterNotch.';
    for (const command of result.commands || []) {
      const route = routes.get(command.token);
      if (route) await browser.tabs.sendMessage(route.tabId, {type: 'control', token: command.token, command: command.command}, {frameId: route.frameId}).catch(() => {});
    }
  } catch (error) {
    active = false;
    status = error.message?.startsWith('Pairing key') ? error.message : 'Open BetterNotch and enable Music and Include browser audio.';
  } finally {
    collecting = false;
    reports.clear();
    routes.clear();
    setTimeout(tick, active ? 1000 : 2000);
  }
}
tick();
