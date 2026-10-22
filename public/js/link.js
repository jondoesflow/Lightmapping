// Lightmapping Link: connect this device to a receiver (any browser, e.g. a laptop, TV
// box or spare tablet plugged into the projector) by typing its 4-digit code.
//  - "Send show": transfers an exported video; the receiver saves it and loops it, so the
//    sending phone can be closed and put away.
//  - "Live output": streams the canvas in real time, so your phone keeps the controls
//    while the projector shows only the clean output.
// Uses WebRTC via PeerJS; the public PeerJS server only brokers the connection.

const PEERJS = 'https://cdn.jsdelivr.net/npm/peerjs@1.5.4/dist/peerjs.min.js';
export const PEER_PREFIX = 'lightmapping-link-';
const CHUNK = 64 * 1024;

let loading;
export function loadPeer() {
  loading ??= new Promise((resolve, reject) => {
    if (window.Peer) return resolve(window.Peer);
    const s = document.createElement('script');
    s.src = PEERJS;
    s.onload = () => resolve(window.Peer);
    s.onerror = () => reject(new Error('Could not load the link library. Check your connection.'));
    document.head.appendChild(s);
  });
  return loading;
}

export class LinkSender {
  constructor() { this.peer = null; this.call = null; }

  async open() {
    if (this.peer && !this.peer.destroyed) return this.peer;
    const Peer = await loadPeer();
    this.peer = new Peer();
    await new Promise((resolve, reject) => { this.peer.on('open', resolve); this.peer.on('error', reject); });
    return this.peer;
  }

  /** Send a file (Blob) to receiver `code`, reporting progress 0..1. */
  async sendFile(code, blob, name, onProgress) {
    const peer = await this.open();
    const conn = peer.connect(PEER_PREFIX + code, { reliable: true });
    await new Promise((resolve, reject) => {
      conn.on('open', resolve);
      conn.on('error', reject);
      peer.on('error', reject);
      setTimeout(() => reject(new Error('No receiver with that code. Is Receiver open on the other device?')), 15000);
    });
    conn.send({ type: 'begin', name, size: blob.size, mime: blob.type || 'video/mp4' });
    const buf = await blob.arrayBuffer();
    for (let off = 0; off < buf.byteLength; off += CHUNK) {
      conn.send({ type: 'chunk', data: buf.slice(off, off + CHUNK) });
      // Back-pressure: let the data channel drain.
      while (conn.dataChannel?.bufferedAmount > 4 * 1024 * 1024) await new Promise((r) => setTimeout(r, 30));
      onProgress?.(Math.min(1, (off + CHUNK) / buf.byteLength));
    }
    conn.send({ type: 'end' });
    await new Promise((resolve) => conn.on('data', (d) => d?.type === 'saved' && resolve()));
    conn.close();
  }

  /** Stream a MediaStream (the output canvas) live to receiver `code`. */
  async streamLive(code, stream) {
    const peer = await this.open();
    this.stopLive();
    this.call = peer.call(PEER_PREFIX + code, stream);
    return this.call;
  }

  stopLive() { this.call?.close(); this.call = null; }
}
