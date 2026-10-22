// IndexedDB persistence: projects as JSON, media (photos, videos, masks, depth maps,
// audio, received shows) as Blobs referenced by id. Everything stays on the device.

const DB_NAME = 'lightmapping';
let dbPromise;

function db() {
  dbPromise ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      const d = req.result;
      d.createObjectStore('projects', { keyPath: 'id' });
      d.createObjectStore('assets');
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

async function tx(store, mode, fn) {
  const d = await db();
  return new Promise((resolve, reject) => {
    const t = d.transaction(store, mode);
    const req = fn(t.objectStore(store));
    t.oncomplete = () => resolve(req?.result);
    t.onerror = () => reject(t.error);
  });
}

export const listProjects = async () => ((await tx('projects', 'readonly', (s) => s.getAll())) || []).sort((a, b) => b.modified - a.modified);
export const saveProject = (p) => tx('projects', 'readwrite', (s) => s.put({ ...p, modified: Date.now() }));
export const deleteProject = (id) => tx('projects', 'readwrite', (s) => s.delete(id));
export const putAsset = (id, blob) => tx('assets', 'readwrite', (s) => s.put(blob, id));
export const getAsset = (id) => tx('assets', 'readonly', (s) => s.get(id));
export const deleteAsset = (id) => tx('assets', 'readwrite', (s) => s.delete(id));

/** Ask the browser not to evict our data under storage pressure (best effort). */
export const requestPersistence = () => navigator.storage?.persist?.().catch(() => false);

// MARK: Loaded media cache

const images = new Map(); // id -> HTMLImageElement | 'loading' | 'error'
const urls = new Map();

export async function assetURL(id) {
  if (urls.has(id)) return urls.get(id);
  const blob = await getAsset(id);
  if (!blob) return null;
  const url = URL.createObjectURL(blob);
  urls.set(id, url);
  return url;
}

/** Returns a decoded image, or null while it loads in the background. */
export function imageAsset(id) {
  const v = images.get(id);
  if (v instanceof HTMLImageElement) return v;
  if (!v) {
    images.set(id, 'loading');
    assetURL(id).then((url) => {
      if (!url) return images.set(id, 'error');
      const img = new Image();
      img.onload = () => images.set(id, img);
      img.onerror = () => images.set(id, 'error');
      img.src = url;
    });
  }
  return null;
}
