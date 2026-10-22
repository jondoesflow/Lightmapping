// App shell: project list, editor layout, panels, projector mode.

import { h, clear, button, select, menu, toast, updateMeters, closeMenus } from './ui.js';
import { Engine } from './engine.js';
import { Stage } from './stage.js';
import { listProjects, saveProject, deleteProject, requestPersistence } from './storage.js';
import { newProject, demoProject, timelineDuration } from './model.js';
import { surfacesPanel, layerPanel, performPanel, timelinePanel, exportPanel, settingsPanel, photoShapeFlow, libraryModal } from './panels.js';
import { layerFromPreset } from './model.js';

const app = document.getElementById('app');
let engine = null;

const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const standalone = matchMedia('(display-mode: standalone)').matches || navigator.standalone;

// MARK: Home

async function showHome() {
  engine?.destroy();
  engine = null;
  document.body.className = 'home';
  const projects = await listProjects();
  clear(app, h('div.home-wrap',
    h('header.home-head', h('img', { src: '/icon-192.png', alt: '', width: 48, height: 48 }), h('div', h('h1', 'Lightmapping'), h('p', 'Projection mapping studio for your phone'))),
    isIOS && !standalone ? h('div.install', '📲 Install: tap ', h('strong', 'Share'), ' then ', h('strong', 'Add to Home Screen'), '. It then opens full screen like an app.') : null,
    h('div.home-actions',
      button('＋ New project', async () => {
        const name = prompt('Project name', `Projection ${projects.length + 1}`);
        if (name == null) return;
        const p = newProject(name || 'Untitled');
        await saveProject(p);
        openProject(p);
      }, 'primary big'),
      button('✨ Start from a demo', async () => { const p = demoProject(); await saveProject(p); openProject(p); }, 'big'),
      h('a.button.big', { href: '/receive.html' }, '📡 Receiver mode')),
    h('h2', 'Projects'),
    projects.length ? null : h('p.hint', 'No saved projects yet. Projects are saved on this device.'),
    h('div.list', projects.map((p) => h('div.item',
      h('button.grow', { type: 'button', onClick: () => openProject(p) },
        h('strong', p.name), h('small', ` ${p.surfaces.length} surfaces · ${p.scenes.length} scenes · ${new Date(p.modified).toLocaleDateString()}`)),
      button('✕', async () => { if (confirm(`Delete “${p.name}”?`)) { await deleteProject(p.id); showHome(); } }, 'icon danger')))),
    h('p.foot', 'Receiver mode turns a laptop, TV browser or spare tablet into a projector player. ', h('a', { href: '/about.html' }, 'About & help'))));
}

// MARK: Editor

function openProject(project) {
  requestPersistence();
  document.body.className = 'editor';
  const canvas = h('canvas#out');
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.id = 'overlay';
  const hint = h('div.tool-hint');
  const stageEl = h('main.stage', h('div.canvas-box', canvas), svg, hint);
  const panelBody = h('div.panel-body');
  const panelTitle = h('h2');
  const panel = h('aside.panel', h('header', panelTitle, button('✕', () => ui.close(), 'icon')), panelBody);
  const topbar = h('header.topbar');
  const scenebar = h('footer.scenebar');
  clear(app, h('div.editor-wrap', topbar, stageEl, panel, scenebar));

  try {
    engine = new Engine(canvas, project);
  } catch (e) {
    clear(app, h('div.home-wrap', h('h1', 'Can’t start'), h('p', e.message), button('Back', showHome)));
    return;
  }
  const eng = engine;

  const titles = { surfaces: 'Surfaces', layer: 'Layer', perform: 'Perform', timeline: 'Timeline', export: 'Export & Link', settings: 'Inputs & output' };
  const views = { surfaces: surfacesPanel, layer: layerPanel, perform: performPanel, timeline: timelinePanel, export: exportPanel, settings: settingsPanel };
  const ui = {
    view: null, layerId: null, root: panelBody,
    open(view, opts = {}) {
      const changed = view !== ui.view || (opts.layerId && opts.layerId !== ui.layerId);
      Object.assign(ui, opts);
      ui.view = view;
      panel.classList.add('open');
      ui.refresh();
      if (changed) panelBody.scrollTop = 0;
    },
    close() { ui.view = null; panel.classList.remove('open'); },
    refresh() {
      if (!ui.view) return;
      // Keep the scroll position when a panel re-renders after an edit.
      const top = panelBody.scrollTop;
      panelTitle.textContent = titles[ui.view];
      clear(panelBody, views[ui.view](eng, ui));
      panelBody.scrollTop = top;
    },
    setTool(t) {
      stage.setTool(t);
      hint.textContent = t === 'outline' ? 'Trace around your object with one finger' : t === 'cutout' ? 'Draw the area to cut out of the selected surface' : '';
      hint.classList.toggle('show', t !== 'select');
      if (t !== 'select') hint.appendChild(button('Cancel', () => ui.setTool('select'), 'small'));
    },
  };
  const stage = new Stage(eng, canvas, svg, () => ui.setTool('select'));

  const tb = (label, title, fn, on) => { const b = button(label, fn, 'tb' + (on ? ' on' : '')); b.title = title; b.setAttribute('aria-label', title); return b; };
  const drawTopbar = () => clear(topbar,
    tb('☰', 'Projects', () => showHome()),
    h('button.title', { type: 'button', onClick: () => { const n = prompt('Rename project', eng.project.name); if (n) { eng.project.name = n; eng.commit(); } } }, eng.project.name),
    h('span.grow'),
    tb('＋', 'Add surface', (e) => addMenu(e.currentTarget)),
    tb('▦', 'Surfaces', () => toggleView('surfaces'), ui.view === 'surfaces' || ui.view === 'layer'),
    tb('◱', 'Outlines', () => { eng.showOutlines = !eng.showOutlines; eng.notify(); }, eng.showOutlines),
    tb('🎛', 'Perform', () => toggleView('perform'), ui.view === 'perform'),
    tb('⏱', 'Timeline', () => toggleView('timeline'), ui.view === 'timeline'),
    tb('⤓', 'Export', () => toggleView('export'), ui.view === 'export'),
    tb('⚙︎', 'Settings', () => toggleView('settings'), ui.view === 'settings'),
    tb('⛶', 'Projector', () => projector(true)));

  const toggleView = (v) => (ui.view === v ? ui.close() : ui.open(v));

  const addMenu = (anchor) => menu(anchor, [
    ['▢ Square', () => eng.addSurface({ type: 'quad' })],
    ['◯ Circle', () => eng.addSurface({ type: 'circle' })],
    ['T Text', () => { const t = prompt('Text', 'HELLO'); if (t) eng.addSurface({ type: 'text', text: t }); }],
    ['⬡ Box / cube', () => eng.addBox()],
    ['✍︎ Draw outline', () => ui.setTool('outline')],
    null,
    ['👤 Silhouette from photo', () => photoShapeFlow(eng, false)],
    ['🧊 Depth shape from photo', () => photoShapeFlow(eng, true)],
    null,
    ['✨ Surface from library', () => libraryModal((p) => eng.addSurface({ type: 'quad' }, { layer: layerFromPreset(p) }))],
  ]);

  const drawScenebar = () => {
    const p = eng.project;
    clear(scenebar,
      select(`${p.transition.style}|${p.transition.duration}`,
        ['cut|0', 'fade|0.5', 'fade|1.5', 'fade|3', 'dissolve|1', 'dissolve|2.5'].map((v) => { const [s, d] = v.split('|'); return [v, s === 'cut' ? 'Cut' : `${s[0].toUpperCase() + s.slice(1)} ${d}s`]; }),
        (v) => { const [s, d] = v.split('|'); p.transition = { style: s, duration: +d }; eng.commit(); }),
      h('div.scenes', p.scenes.map((s, i) => {
        const active = s.id === p.activeSceneId;
        return h('div.scene' + (active ? '.on' : '') + (eng.transition?.to === s.id ? '.next' : ''),
          h('button', { type: 'button', onClick: () => eng.goToScene(s.id) }, h('span', s.name), h('small', i + 1)),
          active ? button('⋯', (e) => menu(e.currentTarget, [
            ['Rename', () => { const n = prompt('Scene name', s.name); if (n) { s.name = n; eng.commit(); } }],
            ['Duplicate', () => eng.addScene(s)],
            ['Delete', () => p.scenes.length > 1 ? confirm(`Delete scene “${s.name}”?`) && eng.deleteScene(s.id) : toast('A project needs at least one scene')],
          ]), 'icon') : null);
      }), button('＋', () => eng.addScene(), 'icon add')));
  };

  let lastSelected = eng.selectedId;
  eng.onChange(() => {
    if (eng.selectedId !== lastSelected) {
      lastSelected = eng.selectedId;
      if (eng.selectedId && ui.view !== 'surfaces') ui.open('surfaces');
      else if (ui.view === 'layer') ui.view = 'surfaces';
    }
    drawTopbar();
    drawScenebar();
    ui.refresh();
    stage.render();
  });
  eng.onFrame((ctx) => {
    if (ui.view) updateMeters(panelBody, ctx);
    const ph = panelBody.querySelector('[data-playhead]');
    if (ph) {
      const dur = timelineDuration(eng.project.timeline) || 1;
      ph.style.left = (eng.position / dur) * 100 + '%';
      const t = panelBody.querySelector('[data-time]');
      const f = (x) => `${Math.floor(x / 60)}:${(x % 60).toFixed(1).padStart(4, '0')}`;
      if (t) t.textContent = `${f(eng.position)} / ${f(dur)}`;
    }
  });

  // Projector mode: hide every control; the output fills the screen.
  const projector = (on) => {
    document.body.classList.toggle('projector', on);
    closeMenus();
    if (on) {
      eng.showOutlinesBefore = eng.showOutlines;
      eng.showOutlines = false;
      document.documentElement.requestFullscreen?.().catch(() => {});
      toast('Double-tap to exit projector mode');
    } else {
      eng.showOutlines = eng.showOutlinesBefore ?? true;
      if (document.fullscreenElement) document.exitFullscreen?.().catch(() => {});
    }
    eng.notify();
  };
  stageEl.addEventListener('dblclick', () => document.body.classList.contains('projector') && projector(false));
  let lastTap = 0;
  stageEl.addEventListener('pointerup', () => {
    if (!document.body.classList.contains('projector')) return;
    const t = performance.now();
    if (t - lastTap < 350) projector(false);
    lastTap = t;
  });
  window.onkeydown = (e) => { if (e.key === 'Escape' && document.body.classList.contains('projector')) projector(false); };

  drawTopbar();
  drawScenebar();
  if (!project.surfaces.length) toast('Tap ＋ to add your first surface');
}

window.addEventListener('pagehide', () => engine?.saveNow());
document.addEventListener('visibilitychange', () => document.hidden && engine?.saveNow());

if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('/sw.js').catch(() => {});

showHome();
