// Shared UI primitives: toasts and the right-hand drawer.
import { h, append, clear } from './dom.js';

/** Show a transient message. kind: info | error | success. Errors stay until dismissed. */
export function toast(message, kind = 'info') {
  const host = document.getElementById('toasts');
  if (!host) return;
  const el = h('div', { class: `toast toast-${kind}`, role: kind === 'error' ? 'alert' : 'status' },
    h('span', { class: 'toast-msg' }, message),
    h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Dismiss message', onclick: () => el.remove() }, '×'));
  host.appendChild(el);
  if (kind !== 'error') setTimeout(() => el.remove(), 5000);
}

// ---- drawer -----------------------------------------------------------------
let drawerState = null;

/**
 * Open (or retarget) the side drawer. `title`/`subtitle` are strings; `body` is a Node,
 * or a Promise<Node> (a loading state is shown meanwhile). Returns a close() function.
 */
export function openDrawer({ title, subtitle, body, wide = false }) {
  if (!drawerState) createDrawer();
  const d = drawerState;
  if (!d.open) d.returnFocus = document.activeElement;
  d.open = true;
  d.root.classList.toggle('drawer-wide', wide);
  d.title.textContent = title || '';
  d.subtitle.textContent = subtitle || '';
  d.subtitle.hidden = !subtitle;
  d.root.hidden = false;
  document.body.classList.add('drawer-open');
  requestAnimationFrame(() => d.root.classList.add('is-open'));
  const token = ++d.token;
  clear(d.body);
  d.body.scrollTop = 0;
  if (body && typeof body.then === 'function') {
    d.body.appendChild(h('div', { class: 'loading', role: 'status' }, h('span', { class: 'spinner', 'aria-hidden': 'true' }), 'Loading…'));
    body.then((node) => { if (token === d.token) { clear(d.body); append(d.body, [node]); } })
      .catch((err) => {
        if (token !== d.token) return;
        clear(d.body);
        d.body.appendChild(h('div', { class: 'alert alert-error', role: 'alert' }, err.message || String(err)));
      });
  } else if (body) {
    append(d.body, [body]);
  }
  d.closeBtn.focus();
  return closeDrawer;
}

export function closeDrawer() {
  const d = drawerState;
  if (!d || !d.open) return;
  d.open = false;
  d.token++;
  d.root.classList.remove('is-open');
  document.body.classList.remove('drawer-open');
  d.root.hidden = true;
  if (d.returnFocus && document.contains(d.returnFocus)) d.returnFocus.focus();
}

function createDrawer() {
  const title = h('h2', { id: 'drawer-title' });
  const subtitle = h('p', { class: 'drawer-sub muted' });
  const closeBtn = h('button', { class: 'btn btn-quiet', type: 'button', 'aria-label': 'Close panel', onclick: closeDrawer }, 'Close');
  const body = h('div', { class: 'drawer-body' });
  const panel = h('aside', { class: 'drawer-panel', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': 'drawer-title' },
    h('div', { class: 'drawer-head' }, h('div', null, title, subtitle), closeBtn), body);
  const root = h('div', { class: 'drawer', hidden: true },
    h('div', { class: 'drawer-backdrop', onclick: closeDrawer }), panel);
  document.body.appendChild(root);
  drawerState = { root, title, subtitle, closeBtn, body, open: false, token: 0, returnFocus: null };

  document.addEventListener('keydown', (e) => {
    if (!drawerState.open) return;
    if (e.key === 'Escape') { e.preventDefault(); closeDrawer(); }
    // Keep keyboard focus inside the dialog.
    if (e.key === 'Tab') {
      const f = [...panel.querySelectorAll('a[href], button:not([disabled]), input, select, textarea, [tabindex]:not([tabindex="-1"])')];
      if (!f.length) return;
      const first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
      else if (!panel.contains(document.activeElement)) { e.preventDefault(); first.focus(); }
    }
  });
}

// ---- small shared widgets ---------------------------------------------------

/** Labelled form field wrapper. */
export function field(labelText, control, hint) {
  const id = control.id || `f${Math.random().toString(36).slice(2, 9)}`;
  control.id = id;
  return h('div', { class: 'field' },
    h('label', { for: id }, labelText),
    control,
    hint ? h('p', { class: 'hint' }, hint) : null);
}

export function alertBox(message, kind = 'error') {
  return h('div', { class: `alert alert-${kind}`, role: kind === 'error' ? 'alert' : 'status' }, message);
}
