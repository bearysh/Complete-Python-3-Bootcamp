// Thin fetch wrapper. Every failure becomes an ApiError whose message is the
// server's `detail` (string, or a flattened FastAPI validation list).
import { toast } from './ui.js';

export class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

function detailToMessage(detail, fallback) {
  if (!detail) return fallback;
  if (typeof detail === 'string') return detail;
  if (Array.isArray(detail)) {
    return detail.map((d) => {
      const where = Array.isArray(d.loc) ? d.loc.filter((x) => x !== 'body').join('.') : '';
      return where ? `${where}: ${d.msg}` : d.msg;
    }).join('; ');
  }
  return fallback;
}

async function request(method, path, { json, form, signal } = {}) {
  const opts = { method, headers: { Accept: 'application/json' }, signal };
  if (json !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(json);
  } else if (form) {
    opts.body = form;
  }
  let res;
  try {
    res = await fetch(path, opts);
  } catch (err) {
    if (err.name === 'AbortError') throw err;
    throw new ApiError('Cannot reach the Little Guy Legal server. Is it still running?', 0);
  }
  if (res.status === 204) return null;
  let body = null;
  const text = await res.text();
  if (text) {
    try { body = JSON.parse(text); } catch { body = null; }
  }
  if (!res.ok) {
    throw new ApiError(detailToMessage(body && body.detail, `Request failed (${res.status})`), res.status);
  }
  return body;
}

export const api = {
  get: (p, o) => request('GET', p, o),
  post: (p, json, o) => request('POST', p, { ...o, json: json ?? {} }),
  put: (p, json, o) => request('PUT', p, { ...o, json }),
  patch: (p, json, o) => request('PATCH', p, { ...o, json }),
  del: (p, o) => request('DELETE', p, o),
  upload: (p, form) => request('POST', p, { form }),
};

/** Run an async action; on failure show the server message as a toast and return undefined. */
export async function guarded(fn, { onError } = {}) {
  try {
    return await fn();
  } catch (err) {
    if (err && err.name === 'AbortError') return undefined;
    toast(err.message || String(err), 'error');
    if (onError) onError(err);
    return undefined;
  }
}

const enc = encodeURIComponent;
export const caseUrl = (id, rest = '') => `/api/cases/${enc(id)}${rest}`;
export const enc_ = enc;
