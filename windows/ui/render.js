import { marked } from './vendor/marked.js';
import purify from './vendor/purify.js';
export function markdown(el, text) {
  el.innerHTML = purify.sanitize(marked.parse(text || ''), {
    USE_PROFILES: { html: true }, ALLOWED_URI_REGEXP: /^(?:(?:https?|file):|[a-z]:[\\/]|(?!(?:[a-z][a-z0-9+.-]*:|\/\/|\\\\))[\s\S]*$)/i, FORBID_TAGS: ['img', 'style', 'input', 'form'], FORBID_ATTR: ['style'],
  });
}
export const basename = path => path.split(/[\\/]/).pop();
export const button = (text, action, cls = '') => {
  const b = document.createElement('button'); b.type = 'button'; b.textContent = text; b.className = cls;
  b.onclick = async () => {
    b.disabled = true;
    try { await action(); } catch (e) { window.dispatchEvent(new CustomEvent('pult-error', { detail: String(e) })); }
    finally { b.disabled = false; }
  };
  return b;
};


export function localFileTarget(raw) {
  if (typeof raw !== 'string' || !raw || /^[\\/]{2}/.test(raw)) throw new Error('Неверная ссылка на локальный файл');
  let fragment;
  if (raw.startsWith('file:')) {
    const url = new URL(raw); if (url.hostname && url.hostname !== 'localhost') throw new Error('Сетевые файловые ссылки не поддерживаются');
    fragment = url.hash; raw = url.pathname.replace(/^\/([a-z]:[\\/])/i, '$1');
  } else {
    if (/^[a-z][a-z0-9+.-]*:/i.test(raw) && !/^[a-z]:[\\/]/i.test(raw)) throw new Error('Неподдерживаемый протокол ссылки');
    const hash = raw.indexOf('#'); if (hash >= 0) { fragment = raw.slice(hash); raw = raw.slice(0, hash); }
  }
  raw = decodeURIComponent(raw);
  const match = /^(.*?):(\d+)(?::(\d+))?$/.exec(raw);
  const path = match ? match[1] : raw;
  if (!path || path.includes('\0')) throw new Error('Неверный путь файла');
  const line = fragment?.match(/^#L(\d+)/)?.[1] || match?.[2];
  return { path, ...(line && {line:Number(line)}), ...(match?.[3] && {col:Number(match[3])}) };
}


const symbols = {
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/>',
  new: '<path d="M13 5H5v14h14v-8M10 14l1-4L19 2l3 3-8 8-4 1Z"/>',
  sidebar: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16M6 7v1m0 3v1"/>',
  paperclip: '<path d="m8 13 7-7a3 3 0 0 1 4 4L9 20a5 5 0 0 1-7-7L13 2m-7 13 9-9"/>',
  mic: '<rect x="9" y="2" width="6" height="13" rx="3"/><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3m-4 0h8"/>',
  wand: '<path d="m4 20 12-12 4 4L8 24M14 2v4m-2-2h4M4 4v6m-3-3h6m13 10v5m-2-3h5"/>',
  people: '<circle cx="12" cy="7" r="3"/><path d="M6 20v-3a6 6 0 0 1 12 0v3M4 5a3 3 0 0 0 0 6m16-6a3 3 0 0 1 0 6M2 20v-3m20 3v-3"/>',
  shield: '<path d="M12 2 3 6v6c0 5 9 10 9 10s9-5 9-10V6L12 2Z"/><path d="m8 12 3 3 5-6"/>',
  rules: '<path d="M4 5h16M4 10h12M4 15h7M4 20h7m4-2 2 2 4-5"/>',
  settings: '<path d="m9 3-1 3-3 1-2 5 2 5 3 1 1 3h6l1-3 3-1 2-5-2-5-3-1-1-3Z"/><circle cx="12" cy="12" r="3"/>',
  folder: '<path d="M2 6h8l2 3h10v11H2V6Zm0 0V4h8l2 2h8v3"/>',
  trash: '<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7m4-7v7"/>',
  arrow: '<path d="M12 20V4m-6 6 6-6 6 6"/>',
  stop: '<rect x="6" y="6" width="12" height="12" rx="1"/>',
  limits: '<path d="M4 20V11m8 9V4m8 16v-6"/>',
  cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4m6-4v4M9 18v4m6-4v4M2 9h4m-4 6h4m12-6h4m-4 6h4"/>',
  close: '<path d="m6 6 12 12M18 6 6 18"/>',
};
export function icon(name) {
  const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');
  svg.setAttribute('viewBox','0 0 24 24');svg.setAttribute('fill','none');svg.setAttribute('stroke','currentColor');svg.setAttribute('stroke-width','1.6');svg.setAttribute('stroke-linecap','round');svg.setAttribute('stroke-linejoin','round');svg.setAttribute('aria-hidden','true');svg.classList.add('icon');
  svg.innerHTML=symbols[name] || symbols.cpu;return svg;
}
export function iconButton(name, label, action, text = '') {
  const b=button('',action);b.setAttribute('aria-label',label);b.title=label;b.append(icon(name));if(text)b.append(document.createTextNode(text));return b;
}

// Кольца лимита: внешнее — 5 часов, внутреннее — неделя, в центре — меньший остаток. Общие для окна Пульта и дока.
export const tone = v => !Number.isFinite(v) ? 'unknown' : v < 10 ? 'low' : v < 30 ? 'mid' : 'ok';
export function rings(outer, inner, center) {
  const R = [30, 21], C = R.map(r => 2 * Math.PI * r);
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); svg.setAttribute('viewBox', '0 0 72 72'); svg.classList.add('dk-rings');
  svg.innerHTML = R.map((r, i) => `<circle cx="36" cy="36" r="${r}" class="track t${i}"/><circle cx="36" cy="36" r="${r}" class="arc a${i} ${tone([outer, inner][i])}" stroke-dasharray="${C[i]}" stroke-dashoffset="${C[i]}"/>`).join('')
    + `<text x="36" y="40.5" class="${tone(Math.min(...[outer, inner].filter(Number.isFinite)))}">${center}</text>`;
  requestAnimationFrame(() => [outer, inner].forEach((v, i) => { if (Number.isFinite(v)) svg.querySelector('.a' + i).style.strokeDashoffset = String(C[i] * (1 - Math.max(0, Math.min(100, v)) / 100)); }));
  return svg;
}
