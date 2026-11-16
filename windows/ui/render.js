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
