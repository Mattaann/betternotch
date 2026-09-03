document.querySelector('form').addEventListener('submit', async event => {
  event.preventDefault();
  const pairingKey = document.querySelector('#key').value.trim();
  await browser.storage.local.set({pairingKey});
  document.querySelector('#key').value = '';
  document.querySelector('#status').textContent = 'Connecting…';
});
async function update() {
  const result = await browser.runtime.sendMessage({type: 'status'});
  document.querySelector('#status').textContent = result.status;
}
update();
setInterval(update, 2000);
