// Receiver: shows a 4-digit code, accepts a show file (saved on this device and looped
// forever, even after the sender disconnects) or a live stream from the editor.

import { loadPeer, PEER_PREFIX } from './link.js';
import { getAsset, putAsset } from './storage.js';

const SHOW_KEY = 'received-show';
const video = document.getElementById('show');
const hud = document.getElementById('hud');
const codeEl = document.getElementById('code');
const statusEl = document.getElementById('status');
const setStatus = (t) => { statusEl.textContent = t; };
let showURL = null;

async function playSaved() {
  const blob = await getAsset(SHOW_KEY);
  if (!blob) { setStatus('Waiting for a show…'); return false; }
  if (showURL) URL.revokeObjectURL(showURL);
  showURL = URL.createObjectURL(blob);
  video.srcObject = null;
  video.src = showURL;
  video.loop = true;
  await video.play().catch(() => {});
  setStatus('Looping your saved show');
  hideSoon();
  return true;
}

function hideSoon() { setTimeout(() => hud.classList.add('hidden'), 4000); }

document.body.addEventListener('click', (e) => { if (!e.target.closest('button, a')) hud.classList.toggle('hidden'); });
document.getElementById('full').onclick = () => (document.documentElement.requestFullscreen?.() ?? video.webkitEnterFullscreen?.());
document.getElementById('unmute').onclick = () => { video.muted = !video.muted; video.play().catch(() => {}); };

// Keep the screen awake while playing.
async function wake() { try { await navigator.wakeLock?.request('screen'); } catch {} }
document.addEventListener('visibilitychange', () => !document.hidden && wake());
wake();

async function start(attempt = 0) {
  let code = localStorage.getItem('lm-receiver-code');
  if (!code || attempt > 0) {
    code = String(Math.floor(1000 + Math.random() * 9000));
    localStorage.setItem('lm-receiver-code', code);
  }
  codeEl.textContent = code;
  let Peer;
  try { Peer = await loadPeer(); } catch (e) { setStatus(e.message + ' Saved show still plays offline.'); return; }
  const peer = new Peer(PEER_PREFIX + code);
  peer.on('open', () => { if (!video.src) setStatus('Ready. Enter this code on your phone.'); });
  peer.on('error', (e) => {
    if (e.type === 'unavailable-id' && attempt < 5) { peer.destroy(); start(attempt + 1); }
    else setStatus('Link error: ' + e.type + '. Saved show still plays.');
  });
  peer.on('disconnected', () => setTimeout(() => peer.reconnect(), 2000));

  peer.on('connection', (conn) => {
    let parts = [], meta = null, got = 0;
    conn.on('data', async (msg) => {
      if (msg.type === 'begin') {
        meta = msg; parts = []; got = 0;
        hud.classList.remove('hidden');
        setStatus(`Receiving ${msg.name}…`);
      } else if (msg.type === 'chunk') {
        parts.push(msg.data);
        got += msg.data.byteLength;
        if (meta) setStatus(`Receiving… ${Math.round((got / meta.size) * 100)}%`);
      } else if (msg.type === 'end') {
        await putAsset(SHOW_KEY, new Blob(parts, { type: meta?.mime || 'video/mp4' }));
        parts = [];
        conn.send({ type: 'saved' });
        await playSaved();
      }
    });
  });

  peer.on('call', (call) => {
    call.answer();
    call.on('stream', (stream) => {
      video.src = '';
      video.srcObject = stream;
      video.loop = false;
      video.play().catch(() => {});
      setStatus('Live output');
      hideSoon();
    });
    call.on('close', () => playSaved());
  });
}

playSaved();
start();
