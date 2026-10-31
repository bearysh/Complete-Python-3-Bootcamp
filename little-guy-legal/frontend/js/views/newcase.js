// Screen 2: new case form.
import { h } from '../dom.js';
import { api, guarded } from '../api.js';
import { navigate } from '../router.js';
import { field } from '../ui.js';

export async function newCaseView(root) {
  document.title = 'New case — Little Guy Legal';
  const title = h('input', { type: 'text', required: true, maxlength: '200', placeholder: 'e.g. Main Street Café v. Landlord — rent dispute', autocomplete: 'off' });
  const county = h('input', { type: 'text', value: 'Tarrant', maxlength: '80' });
  const submit = h('button', { class: 'btn btn-primary', type: 'submit' }, 'Create case');
  const form = h('form', { class: 'card form-narrow', onsubmit: async (e) => {
    e.preventDefault();
    if (!title.value.trim()) { title.focus(); return; }
    submit.disabled = true;
    const c = await guarded(() => api.post('/api/cases', { title: title.value.trim(), county: county.value.trim() || 'Tarrant' }));
    if (c) navigate(`/cases/${encodeURIComponent(c.id)}`);
    else submit.disabled = false;
  } },
    field('Case title', title, 'A short name only you will see.'),
    field('County', county, 'Texas county where the property is located. Used to label the report.'),
    h('div', { class: 'actions' }, submit, h('a', { class: 'btn btn-quiet', href: '/' }, 'Cancel')));
  root.appendChild(h('div', { class: 'page narrow' },
    h('nav', { class: 'crumbs', 'aria-label': 'Breadcrumb' }, h('a', { href: '/' }, 'Cases'), ' / ', h('span', null, 'New case')),
    h('h1', null, 'New case'),
    h('p', { class: 'lede' }, 'Commercial lease disputes in Texas. You will add documents and a short intake on the next screen.'),
    form));
  title.focus();
}
