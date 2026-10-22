// Export the mapped show as a video by recording the output canvas in real time
// (MediaRecorder), with the timeline's audio track mixed in.

export const RESOLUTIONS = { '720p': 720, '1080p': 1080, '4K': 2160 };

export function pickMime() {
  // MP4/H.264 first (plays everywhere, and is what Safari records); bare 'video/mp4' last
  // because some Chromium builds claim it but produce empty files.
  const options = ['video/mp4;codecs=avc1', 'video/mp4;codecs=avc1.42E01E', 'video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm', 'video/mp4'];
  return options.find((m) => window.MediaRecorder?.isTypeSupported?.(m)) || '';
}

export const canExport = () => !!(window.MediaRecorder && HTMLCanvasElement.prototype.captureStream);

/**
 * Record the show. Plays the timeline from the start when it has clips, otherwise
 * records the current scene for `fallbackDuration` seconds.
 * @returns {Promise<{blob: Blob, ext: string}>}
 */
export async function recordShow(engine, { resolution = '1080p', fps = 30, includeAudio = true, fallbackDuration = 30, onProgress, signal }) {
  if (!canExport()) throw new Error('This browser cannot record video. Try Safari 15+ or Chrome.');
  const p = engine.project, h = RESOLUTIONS[resolution];
  const w = Math.round((h * p.outputAspect) / 2) * 2;
  const mime = pickMime();
  const tl = p.timeline;
  const useTimeline = tl.clips.length > 0;
  const duration = useTimeline ? tl.clips.reduce((m, c) => Math.max(m, c.start + c.duration), 0) : fallbackDuration;

  engine.recordSize = [w, h];
  engine.layout();
  const stream = engine.canvas.captureStream(fps);
  if (includeAudio && tl.audioAssetId) {
    for (const t of engine.audio.recordingStream().getAudioTracks()) stream.addTrack(t);
  }
  const rec = new MediaRecorder(stream, { mimeType: mime || undefined, videoBitsPerSecond: Math.round(w * h * fps * 0.15) });
  const chunks = [];
  rec.ondataavailable = (e) => e.data.size && chunks.push(e.data);
  const stopped = new Promise((r) => { rec.onstop = r; });

  let finished = false;
  const finish = () => { if (!finished) { finished = true; rec.state !== 'inactive' && rec.stop(); } };
  signal?.addEventListener('abort', finish);

  if (useTimeline) {
    engine.onShowEnd = () => { finish(); return true; };
    await engine.playTimeline({ fromStart: true });
  }
  rec.start(1000);
  const t0 = performance.now();
  const timer = setInterval(() => {
    const t = (performance.now() - t0) / 1000;
    onProgress?.(Math.min(1, t / duration));
    if (t >= duration + 0.2) finish();
  }, 200);

  await stopped;
  clearInterval(timer);
  engine.onShowEnd = null;
  if (useTimeline) engine.stopTimeline();
  engine.recordSize = null;
  stream.getVideoTracks().forEach((t) => t.stop());
  if (signal?.aborted) throw new DOMException('Export cancelled', 'AbortError');
  const type = rec.mimeType || mime || 'video/webm';
  return { blob: new Blob(chunks, { type }), ext: type.includes('mp4') ? 'mp4' : 'webm' };
}

/** Save/share a file. On iPhone this opens the share sheet ("Save Video" puts it in Photos). */
export async function shareFile(blob, filename) {
  const file = new File([blob], filename, { type: blob.type });
  if (navigator.canShare?.({ files: [file] })) {
    try { await navigator.share({ files: [file], title: filename }); return; } catch (e) { if (e.name === 'AbortError') return; }
  }
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 5000);
}
