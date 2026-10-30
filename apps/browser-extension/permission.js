// Camera-permission bridge. Chrome side panels often can't surface the camera
// permission prompt, so getUserMedia there rejects with NotAllowedError without
// ever asking. This page is opened in a normal popup window (where the prompt
// works reliably); granting here stores the decision for the whole extension
// origin, after which the side panel's getUserMedia resolves silently.

const msg = document.getElementById('msg');
const btn = document.getElementById('grant');

async function request() {
  btn.disabled = true;
  msg.textContent = 'Waiting for Chrome’s camera prompt…';
  msg.className = '';
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
    // We only needed the grant — release the camera immediately.
    stream.getTracks().forEach((t) => t.stop());
    msg.textContent = 'Camera allowed. You can close this window and return to the panel.';
    msg.className = 'ok';
    btn.style.display = 'none';
    try { chrome.runtime.sendMessage({ type: 'cf-camera-granted' }); } catch (e) { /* ignore */ }
    setTimeout(() => window.close(), 1200);
  } catch (e) {
    btn.disabled = false;
    msg.className = 'err';
    msg.textContent = e && e.name === 'NotAllowedError'
      ? 'Camera was blocked. Click the camera icon in the address bar (or chrome://settings/content/camera) to allow it, then try again.'
      : `Could not get the camera: ${e && e.name ? e.name + ' — ' : ''}${(e && e.message) || e}`;
    try { chrome.runtime.sendMessage({ type: 'cf-camera-denied', error: String(e && e.name || e) }); } catch (_) { /* ignore */ }
  }
}

btn.addEventListener('click', request);
// Ask straight away; the button is the retry affordance.
request();
