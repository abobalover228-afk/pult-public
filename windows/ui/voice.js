import { call, ui, h, settings } from './core.js';
import { button } from './render.js';
import { sphere } from './sphere.js';
let listening = false, playback = false, epoch = 0, speak = false, handsfree = false, language = 'ru-RU', voice = '';
let dialog = false, dialogChat = null, host = null, state = 'idle', lastText = '', error = '';
const labels = { idle: 'На связи', listening: 'Слушаю тебя', thinking: 'Думаю', speaking: 'Отвечаю', error: 'Не удалось продолжить' };
function update(next = state) {
  state = next;
  document.documentElement.dataset.voice = state;
  if (!host?.isConnected) return;
  host.querySelector('.voice-scene').dataset.state = state;
  host.querySelector('.voice-status').textContent = labels[state];
  host.querySelector('.voice-caption').textContent = error || lastText || 'Скажи, что хочешь обсудить или сделать';
  const toggle = host.querySelector('.voice-toggle');
  toggle.textContent = dialog ? 'Завершить разговор' : 'Начать разговор';
  toggle.setAttribute('aria-pressed', String(dialog));
}
async function stop() {
  epoch++; silentTries = 0; dialog = false; dialogChat = null; listening = false; playback = false;
  update('idle'); await call('voice', 'stop');
}
function fail(err, run) {
  if (run !== epoch) return;
  dialog = false; dialogChat = null; listening = playback = false;
  error = String(err.message || err); update('error'); ui.toast(error);
}
let silentTries = 0;
async function listen(chat, continuous = false) {
  if (listening || playback || chat?.busy) return;
  const run = ++epoch; listening = true; error = ''; update('listening');
  try {
    const result = await call('voice', 'listen', { language });
    if (run !== epoch || ui.chats.current() !== chat) return;
    listening = false;
    const text = result?.text?.trim();
    // Тишина в разговоре — слушаем ещё раз (до трёх попыток), а не обрываем.
    if (!text) { if (continuous && dialog && ++silentTries < 3) { listening = false; error = ''; lastText = 'Не расслышал — говори, я слушаю'; return listen(chat, true); } if (continuous) await stop(); else update('idle'); return; }
    silentTries = 0; lastText = text;
    if (continuous || handsfree) {
      update('thinking'); await ui.chats.send(text, { chat, literal: true, origin: 'voice' });
    } else { ui.chats.insert(text); update('idle'); }
  } catch (err) { fail(err, run); }
  finally { if (run === epoch) listening = false; }
}
async function startDialog() {
  if (dialog) { await stop(); return; }
  const chat = ui.chats.current();
  if (!chat) throw Error('Открой чат для разговора');
  if (chat.busy) throw Error('Дождись ответа агента');
  dialog = true; dialogChat = chat; await listen(chat, true);
}
// Вслух — только разговорная часть: до «---», без кода и ссылок, не длиннее ~900 символов по границе предложения.
const spokenText = text => clip(text.split(/\n-{3,}\s*\n/)[0].replace(/```[\s\S]*?```/g, ' Код — в чате. ').replace(/!\[[^\]]*\]\([^)]*\)/g, '').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/https?:\/\/\S+/g, '').replace(/^\s*[-*+]\s+/gm, '').replace(/\|/g, ' ').replace(/[*_#`>]/g, '').replace(/\s+\n/g, '\n').trim());
function clip(text, limit = 900) {
  if (text.length <= limit) return text;
  const cut = text.slice(0, limit), end = Math.max(cut.lastIndexOf('. '), cut.lastIndexOf('! '), cut.lastIndexOf('? '), cut.lastIndexOf('\n'));
  return (end > 200 ? cut.slice(0, end + 1) : cut) + ' Остальное — в чате.';
}
// Перебить агента: тап по сфере во время озвучки сразу переключает на «слушаю».
async function bargeIn() {
  if (playback) { epoch++; playback = false; await call('voice', 'stop').catch(() => {}); if (dialog && dialogChat) return listen(dialogChat, true); update('idle'); return; }
  if (listening) return;
  return startDialog();
}
async function answer(e) {
  if (e.chat !== ui.chats.current()) return;
  if (e.failed) { if (dialog) await stop(); update('idle'); return; }
  if (!speak && !dialog) { update('idle'); return; }
  const start = e.chat.messages.map(m => m.kind).lastIndexOf('user');
  const text = spokenText([...e.chat.messages.slice(start + 1)].reverse().find(m => m.kind === 'agent')?.text || '');
  if (!text) { if (dialog) await stop(); update('idle'); return; }
  const run = ++epoch; playback = true; lastText = text; error = ''; update('speaking');
  try {
    await call('voice', 'speak', { text, language, voice });
    if (run !== epoch) return;
    playback = false; update('idle');
    if (dialog && dialogChat === e.chat) await listen(e.chat, true);
  } catch (err) { fail(err, run); }
  finally { if (run === epoch) playback = false; }
}
const saveVoice = () => settings.set('voice', { language, voice, speak, handsfree });
function voiceControls() {
  const select = h('select', { 'aria-label': 'Голос озвучки' }, h('option', { value: '' }, 'Системный голос'));
  const hint = h('span.voice-picker-hint', {}, 'Загружаю голоса…');
  select.onchange = async () => {
    if (listening || playback || dialog) { select.value = voice; ui.toast('Сначала останови разговор или озвучку'); return; }
    voice = select.value;
    try { await saveVoice(); } catch (err) { ui.toast(String(err)); }
  };
  call('voice', 'voices').then(result => {
    const voices = (result?.voices || []).filter(v => typeof v.id === 'string' && typeof v.name === 'string' && typeof v.language === 'string');
    const languages = [...new Set(voices.map(v => v.language))].sort((a, b) => (b.startsWith(language.split('-')[0]) - a.startsWith(language.split('-')[0])) || a.localeCompare(b));
    select.replaceChildren(h('option', { value: '' }, 'Системный голос'), ...languages.map(lang => h('optgroup', { label: lang }, ...voices.filter(v => v.language === lang).map(v => h('option', { value: v.id }, v.name)))));
    if (voice && !voices.some(v => v.id === voice)) select.append(h('option', { value: voice }, 'Сохранённый голос недоступен'));
    select.value = voice;
    const mine = voices.filter(v => v.language.startsWith(language.split('-')[0]));
    const good = mine.filter(v => ['premium', 'enhanced'].includes(v.quality));
    for (const option of select.querySelectorAll('option')) { const v = voices.find(v => v.id === option.value); if (v?.quality === 'premium') option.textContent += ' · премиум'; else if (v?.quality === 'enhanced') option.textContent += ' · улучшенный'; }
    hint.textContent = good.length ? `Лучший голос выбирается сам: ${good[0].name}` : mine.length
      ? 'Голос звучит роботом? Скачай улучшенный: Системные настройки → Универсальный доступ → Устный контент → Системный голос → Управлять голосами → Русский (Milena или Yuri «улучшенный»). Пульт подхватит его сам.'
      : `${voices.length} системных голосов`;
  }).catch(err => { hint.textContent = String(err); });
  const preview = button('Послушать', () => {
    if (listening || playback || dialog) { ui.toast('Сначала останови разговор или озвучку'); return; }
    const run = ++epoch;
    const text = language.startsWith('ru') ? 'Привет, брат. Я голос Пульта. Давай обсудим твой проект.' : 'Hello. I am the voice of Pult. Let us talk about your project.';
    playback = true; lastText = text; error = ''; update('speaking');
    call('voice', 'speak', { text, language, voice }).then(() => { if (run === epoch) { playback = false; update('idle'); } }).catch(err => fail(err, run));
  }, 'voice-preview');
  return h('div.voice-picker', {}, h('label', {}, h('span', {}, 'Голос'), select), preview, hint);
}
ui.addComposerButton({ id: 'voice', title: 'Диктовка', icon: 'Диктовка', run: () => { (listening ? stop() : listen(ui.chats.current())).catch(ui.toast); } });
ui.addComposerButton({ id: 'voice-sphere', title: 'Голосовой разговор', icon: 'Голосовой разговор', run: () => ui.openPanel('voice-sphere', 'main') });
ui.addPanel({ id: 'voice-sphere', title: 'Голосовой разговор', slot: 'main', render(el) {
  host = el;
  el.append(h('div.voice-scene', { 'data-state': state },
    h('div.voice-heading', {}, h('span', {}, 'ПУЛЬТ · ГОЛОС'), button('Вернуться в чат', () => ui.closePanel('voice-sphere'), 'voice-back')),
    h('div.voice-center', {}, h('button.voice-orbit', { type: 'button', 'aria-label': 'Говорить или перебить', title: 'Тап — говорить или перебить ответ', onclick: () => bargeIn().catch(ui.toast) }, sphere(240)),
      h('h1.voice-status', { role: 'status', 'aria-live': 'polite' }), h('p.voice-caption')),
    h('div.voice-actions', {}, voiceControls(), button('Начать разговор', () => { startDialog().catch(ui.toast); }, 'voice-toggle'), h('span', {}, 'Тап по сфере — перебить ответ · Esc — закончить'))));
  update();
}, dispose() { host = null; if (dialog || listening || playback) stop().catch(ui.toast); } });
ui.addSettings({ id: 'voice', title: 'Голос', render(el) {
  const lang = h('input', { value: language, placeholder: 'ru-RU' }), speech = h('input', { type: 'checkbox', checked: speak }), hands = h('input', { type: 'checkbox', checked: handsfree });
  el.append(h('p', {}, 'Системное распознавание и озвучка macOS / Windows. Голосовой разговор — по кнопке сферы рядом с полем сообщения.'), h('label', {}, 'Язык ', lang), voiceControls(), h('label', {}, speech, ' Озвучивать ответы в обычном чате'), h('label', {}, hands, ' Отправлять диктовку сразу'), button('Сохранить голос', async () => { language = lang.value.trim() || 'ru-RU'; speak = speech.checked; handsfree = hands.checked; await saveVoice(); }), button('Остановить голос', stop));
} });
await ui.ready;
document.addEventListener('keydown', e => { if (e.key === 'Escape' && (dialog || playback || listening) && host?.isConnected) { e.stopPropagation(); stop().catch(ui.toast); } }, true);
ui.chats.onEvent(e => {
  if ((e.type === 'open' || e.type === 'close') && (dialog || listening || playback)) { stop().catch(ui.toast); return; }
  if (e.chat !== ui.chats.current()) return;
  if (e.type === 'turnStart') update('thinking');
  if (e.type === 'message' && e.message.kind === 'agent' && !dialog && !playback) update('thinking');
  if (e.type === 'turnEnd') answer(e).catch(ui.toast);
});
const saved = await settings.get('voice');
if (saved) { language = saved.language || language; voice = typeof saved.voice === 'string' ? saved.voice : ''; speak = !!saved.speak; handsfree = !!saved.handsfree; }
