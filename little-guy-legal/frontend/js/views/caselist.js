// Screen 1: case list.
import { h, statusChip, fmtDate, fmtDateTime, replaceChildren, emptyState, spinnerBlock, plural } from '../dom.js';
import { api } from '../api.js';
import { navigate } from '../router.js';
import { alertBox } from '../ui.js';

export async function caseListView(root) {
  document.title = 'Cases — Little Guy Legal';
  const content = h('div', null, spinnerBlock('Loading cases…'));
  root.appendChild(h('div', { class: 'page' },
    h('div', { class: 'page-head' },
      h('div', null, h('h1', null, 'Cases'), h('p', { class: 'lede' }, 'Research matters stored on this computer. Nothing leaves this machine.')),
      h('a', { class: 'btn btn-primary', href: '/cases/new' }, 'New case')),
    content));

  try {
    const cases = await api.get('/api/cases');
    if (!cases.length) {
      replaceChildren(content, emptyState('No cases yet', 'Create a case, upload the lease and related documents, and run an analysis.'),
        h('p', { class: 'center' }, h('a', { class: 'btn btn-primary', href: '/cases/new' }, 'Create your first case')));
      return;
    }
    const rows = cases.map((c) => {
      const open = () => navigate(`/cases/${encodeURIComponent(c.id)}`);
      const titleLink = h('a', { href: `/cases/${encodeURIComponent(c.id)}`, class: 'row-link' }, c.title);
      return h('tr', { class: 'clickable', onclick: (e) => { if (!e.target.closest('a')) open(); } },
        h('td', null, titleLink, h('div', { class: 'muted small' }, `${c.county} County`)),
        h('td', null, statusChip(c.status)),
        h('td', { class: 'num' }, String(c.document_count)),
        h('td', null, fmtDate(c.created_at)),
        h('td', null, c.latest_report_status ? statusChip(c.latest_report_status) : h('span', { class: 'muted' }, 'No report')));
    });
    replaceChildren(content, h('div', { class: 'table-wrap' }, h('table', { class: 'table' },
      h('caption', { class: 'sr-only' }, plural(cases.length, 'case')),
      h('thead', null, h('tr', null,
        h('th', { scope: 'col' }, 'Case'), h('th', { scope: 'col' }, 'Status'), h('th', { scope: 'col', class: 'num' }, 'Documents'),
        h('th', { scope: 'col' }, 'Created'), h('th', { scope: 'col' }, 'Latest report'))),
      h('tbody', null, rows))));
  } catch (err) {
    replaceChildren(content, alertBox(err.message));
  }
}
