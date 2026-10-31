// History-API router (no hashes). Routes are matched in order; a view is an async function
// (root, params) => cleanup|void. A navigation token discards results of superseded renders.

const routes = [];
let notFound = null;
let token = 0;
let cleanup = null;
let rootEl = null;

export function addRoute(pattern, view) {
  // '/cases/:id/progress' -> regex with named params
  const keys = [];
  const rx = new RegExp('^' + pattern.replace(/:([a-z]+)/gi, (_, k) => { keys.push(k); return '([^/]+)'; }) + '/?$');
  routes.push({ rx, keys, view });
}
export function setNotFound(view) { notFound = view; }

export function navigate(path, { replace = false } = {}) {
  if (path === location.pathname + location.search) { render(); return; }
  history[replace ? 'replaceState' : 'pushState']({}, '', path);
  render();
}

export function currentQuery() { return new URLSearchParams(location.search); }

export function startRouter(root) {
  rootEl = root;
  window.addEventListener('popstate', render);
  // Intercept same-origin link clicks so navigation stays in-app.
  document.addEventListener('click', (e) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = e.target.closest && e.target.closest('a[href]');
    if (!a || a.target || a.hasAttribute('download') || a.origin !== location.origin) return;
    if (a.pathname.startsWith('/api/') || a.pathname.startsWith('/static/')) return;
    e.preventDefault();
    navigate(a.pathname + a.search);
  });
  render();
}

async function render() {
  const my = ++token;
  if (typeof cleanup === 'function') { try { cleanup(); } catch { /* ignore */ } }
  cleanup = null;
  const path = location.pathname.replace(/\/+$/, '') || '/';
  let view = notFound, params = {};
  for (const r of routes) {
    const m = r.rx.exec(path);
    if (m) { view = r.view; params = Object.fromEntries(r.keys.map((k, i) => [k, decodeURIComponent(m[i + 1])])); break; }
  }
  rootEl.replaceChildren();
  window.scrollTo(0, 0);
  const result = await view(rootEl, params, () => my === token);
  if (my !== token) { if (typeof result === 'function') result(); return; }
  cleanup = result;
  rootEl.focus({ preventScroll: true });
}
