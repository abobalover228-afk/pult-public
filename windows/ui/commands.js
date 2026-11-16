import './models.js';
import './coach.js';
import { ui, call, h } from './core.js';
ui.addCommand({ name: 'new', hint: 'Новый диалог', run: () => ui.chats.open() });
ui.addCommand({ name: 'clear', hint: 'Новый диалог', run: () => ui.chats.open() });
ui.addCommand({ name: 'settings', hint: 'Настройки', run: () => ui.openSettings() });
ui.addCommand({ name: 'limits', hint: 'Виджет лимитов', run: () => call('limits', 'toggle') });
ui.addCommand({ name: 'compact', hint: 'Сжать контекст', run: (_, c) => {
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  if (c.target === 'claude') return ui.chats.send('/compact', { chat: c, literal: true });
  if (c.target !== 'codex') throw new Error('Сжатие контекста доступно в Codex и Claude');
  return c.thread ? ui.chats.rpc(c, 'thread/compact/start', { threadId: c.thread }) : ui.toast('Сначала начни диалог');
} });
ui.addCommand({ name: 'model', hint: 'Сменить модель', run: async (name, c) => {
  if (c.target.startsWith('api:')) return ui.toast('Модель API меняется в настройках подключения');
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  if (!name.trim()) return ui.models.open(c);
  await ui.chats.configure(c, { model: name.trim() === 'default' ? '' : name.trim(), effort: '' });
  ui.toast(`Модель: ${c.model || 'по умолчанию'}`);
} });
ui.addCommand({ name: 'help', hint: 'Команды Пульта', run: () => ui.openPanel('commands') });
ui.addPanel({ id: 'commands', title: 'Команды Пульта', render: el => {
  for (const c of ui.commands.values()) el.append(h('p', {}, h('code', {}, `/${c.name}`), ` — ${c.hint}`));
} });
const note = (c, value) => ui.chats.note(typeof value === 'string' ? value : JSON.stringify(value, null, 2), c);
const command = (name, hint, run) => ui.addCommand({ name, hint, run });
const codex = async (c, method, params = {}) => {
  if (c.target !== 'codex') throw new Error('Эта команда доступна в Codex');
  const result = await ui.chats.rpc(c, method, params); note(c, result); return result;
};
command('stop', 'Остановить текущий ход', (_, c) => ui.chats.stop(c.id));
command('cd', 'Сменить папку проекта', async (path, c) => {
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  path = path.trim() || (await call('codex', 'pick', { folder: true, dir: c.cwd }))?.[0];
  if (!path) return;
  path = await call('codex', 'resolveDir', { path, cwd: c.cwd });
  ui.chats.open({ target: c.target, cwd: path, model: c.model, account: c.account });
});
command('pwd', 'Папка проекта', (_, c) => note(c, c.cwd));
command('status', 'Состояние диалога', (_, c) => note(c, `Провайдер: ${c.target}\nМодель: ${c.model || 'по умолчанию'}\nПапка: ${c.cwd}\nСессия: ${c.thread || c.session || 'новая'}\n${c.busy ? 'Работает' : 'Готов'}`));
command('usage', 'Квоты и токены', (_, c) => c.target === 'codex' ? codex(c, 'account/rateLimits/read') : note(c, c.usage || 'Квоты API смотри у провайдера; Claude — в виджете Лимитов'));
command('copy', 'Скопировать последний ответ', async (_, c) => { const answer = c.messages.findLast(m => m.kind === 'agent'); if (!answer) throw new Error('Ответа пока нет'); await navigator.clipboard.writeText(answer.text); ui.toast('Ответ скопирован'); });
command('rename', 'Переименовать диалог', async (name, c) => { if (!name.trim()) throw new Error('/rename название'); if (c.target === 'codex' && c.thread) await ui.chats.rpc(c, 'thread/name/set', { threadId: c.thread, name }); c.title = name.trim(); ui.chats.refresh(c); await ui.chats.save(c); });
command('diff', 'Изменения проекта', (_, c) => ui.chats.exec('git', ['diff', '--no-ext-diff', '--no-textconv', 'HEAD', '--'], { chat: c }));
command('git', 'Состояние проекта', (_, c) => ui.chats.exec('git', ['status', '--short'], { chat: c }));
command('version', 'Версия CLI', (_, c) => ui.chats.exec(c.target === 'claude' ? 'claude' : 'codex', ['--version'], { chat: c }));
command('mcp', 'Настроить MCP', () => ui.openPanel('mcp'));
command('permissions', 'Настроить разрешения', () => ui.openSettings());
command('config', 'Настройки', () => ui.openSettings());
command('warnings', 'Ошибки текущего диалога', (_, c) => note(c, c.messages.filter(m => m.kind === 'error').map(m => m.text).join('\n') || 'Ошибок нет'));
command('recap', 'Подвести итог разговора', (_, c) => ui.chats.send('Подведи краткий итог: цель, сделано, осталось. Не выполняй новых действий.', { chat: c, literal: true }));
command('queue', 'Очередь: pause/resume/clear', async (arg, c) => {
  if (arg === 'pause') c.queuePaused = true;
  else if (arg === 'resume') await ui.chats.resumeQueue(c);
  else if (arg === 'clear') c.queue = [];
  note(c, `Очередь: ${c.queue.length}, ${c.queuePaused ? 'пауза' : 'готова'}\n${c.queue.map((j, i) => `${i + 1}. ${j.text}`).join('\n')}`);
});
command('goal', 'Цель Codex', (objective, c) => {
  if (!c.thread) throw new Error('Сначала начни диалог');
  const clear = ['clear', 'off', 'stop'].includes(objective.trim());
  return codex(c, clear ? 'thread/goal/clear' : objective ? 'thread/goal/set' : 'thread/goal/get', { threadId: c.thread, ...(objective && !clear && { objective, origin: 'user' }) });
});
command('experimental', 'Экспериментальные функции Codex', (arg, c) => {
  const words = arg.trim().split(/\s+/);
  return words.length === 2 && ['on', 'off'].includes(words[1])
    ? codex(c, 'experimentalFeature/enablement/set', { enablement: { [words[0]]: words[1] === 'on' } })
    : codex(c, 'experimentalFeature/list', { limit: 100 });
});
command('skills', 'Навыки проекта', async (arg, c) => {
  if (c.target === 'claude') return note(c, await call('claude', 'localFiles', { folder: 'skills', cwd: c.cwd }));
  const args = commandWords(arg);
  if (args.length === 2 && ['enable', 'disable'].includes(args[0])) return codex(c, 'skills/config/write', { path: await call('codex', 'resolvePath', { path: args[1], cwd: c.cwd }), enabled: args[0] === 'enable' });
  return codex(c, 'skills/list', { cwds: [c.cwd], forceReload: true });
});
command('apps', 'Подключённые приложения Codex', (_, c) => codex(c, 'app/list', {}));
command('plugins', 'Плагины: list/search/install/remove', plugins);
command('hooks', 'Хуки проекта', async (_, c) => {
  if (c.target === 'claude') { const path = await call('codex', 'resolvePath', { path: '.claude/settings.json', cwd: c.cwd }); return note(c, await call('api', 'readText', { path })); }
  return codex(c, 'hooks/list', { cwds: [c.cwd] });
});
command('export', 'Экспорт разговора в Markdown', (_, c) => {
  const text = `# ${c.title}\n\n${c.messages.map(m => `## ${m.kind}\n\n${m.text}${m.output ? `\n\n\`\`\`\n${m.output}\n\`\`\`` : ''}`).join('\n\n')}`;
  const url = URL.createObjectURL(new Blob([text], { type: 'text/markdown;charset=utf-8' }));
  const a = document.createElement('a'); a.href = url; a.download = 'pult-conversation.md'; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
});

command('trash', 'Убрать текущий разговор в восстанавливаемую корзину', (_, c) => ui.chats.trash(c.localId ? `local:${c.localId}` : c.target === 'claude' && c.session ? `claude:${c.session}` : c.thread));
command('restore', 'Восстановить диалоги из корзины', () => ui.chats.restoreTrash());
command('pin', 'Закрепить текущий диалог', (_, c) => ui.chats.pin(c.localId ? `local:${c.localId}` : c.target === 'claude' && c.session ? `claude:${c.session}` : c.thread));
command('fork', 'Ветка текущего разговора', async (_, c) => {
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  if (c.target === 'codex' && c.thread) {
    const result = await ui.chats.rpc(c, 'thread/fork', { threadId: c.thread, cwd: c.cwd, ...(c.model && { model: c.model }) });
    if (!result?.thread?.id || result.thread.id === c.thread) throw new Error('Codex не создал новую ветку');
    ui.chats.open({ target: c.target, cwd: c.cwd, model: c.model, effort: c.effort, fast: !!c.fast, permissionMode: c.permissionMode, sandbox: c.sandbox, extraDirs: [...(c.extraDirs || [])], rulesOverride: c.rulesOverride, account: c.account, thread: result.thread.id, title: `${c.title} · ветка` });
    return;
  }
  const messages = c.messages.filter(m => ['user', 'agent', 'note'].includes(m.kind)).map(m => ({ ...m, id: crypto.randomUUID() }));
  const fork = ui.chats.open({ target: c.target, cwd: c.cwd, model: c.model, effort: c.effort, fast: !!c.fast, permissionMode: c.permissionMode, sandbox: c.sandbox, extraDirs: [...(c.extraDirs || [])], rulesOverride: c.rulesOverride, account: c.account, title: `${c.title} · ветка`, messages });
  if (c.target === 'claude' && c.session) { fork.session = c.session; fork.forkSession = true; }
  else if (c.target === 'codex' || c.target === 'claude') fork.seed = messages.map(m => `${m.kind}: ${m.text}`).join('\n\n');
  await ui.chats.save(fork);
});

command('restart', 'Перезапустить CLI с сохранением разговора', async (_, c) => { await ui.chats.restart(c); note(c, 'CLI будет запущен заново на следующем ходе. Разговор сохранён.'); });
command('branch', 'Создать ветку разговора', (arg, c) => ui.commands.get('fork').run(arg, c));

command('effort', 'Глубина размышлений', async (arg, c) => {
  if (!arg.trim()) return ui.models.open(c);
  await ui.chats.configure(c, { effort: arg.trim() === 'auto' ? '' : arg.trim() });
  note(c, `Глубина размышлений: ${c.effort || 'auto'}`);
});
command('fast', 'Быстрый режим: on/off/status', async (arg, c) => {
  if (!['codex', 'claude'].includes(c.target)) throw new Error('Fast зависит от API-провайдера и здесь недоступен');
  arg = arg.trim().toLowerCase();
  if (!['', 'on', 'off', 'status'].includes(arg)) throw new Error('/fast [on|off|status]');
  if (arg !== 'status') await ui.chats.configure(c, { fast: arg ? arg === 'on' : !c.fast });
  note(c, `Fast ${c.fast ? 'запрошен' : 'выключен'} · ${c.target}. Применяется со следующего сообщения. Доступность и дополнительный расход определяет провайдер.`);
});
command('plan', 'Планирование Claude: on/off/status', async (arg, c) => {
  if (c.target !== 'claude') throw new Error('Эта команда доступна в Claude');
  arg = arg.trim().toLowerCase();
  if (!['', 'on', 'off', 'status'].includes(arg)) throw new Error('/plan [on|off|status]');
  if (arg !== 'status') await ui.chats.configure(c, { permissionMode: (arg ? arg === 'on' : c.permissionMode !== 'plan') ? 'plan' : 'default' });
  note(c, `Планирование Claude: ${c.permissionMode === 'plan' ? 'включено' : 'выключено'}`);
});


export function commandWords(text) {
  const words = []; let word = '', quote = '', started = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === '\\' && quote !== "'" && /[\s'"\\]/.test(text[i + 1] || '\0')) { word += text[++i]; started = true; }
    else if (quote) { if (char === quote) quote = ''; else word += char; started = true; }
    else if (char === '"' || char === "'") { quote = char; started = true; }
    else if (/\s/.test(char)) { if (started) { words.push(word); word = ''; started = false; } }
    else { word += char; started = true; }
  }
  if (quote) throw new Error('Закрой кавычку в команде');
  if (started) words.push(word);
  return words;
}
command('cli', 'Подкоманды CLI в ленте: /cli --help', (arg, c) => {
  if (!['codex', 'claude'].includes(c.target)) throw new Error('CLI недоступен для API-подключения');
  return ui.chats.exec(c.target, commandWords(arg || '--help'), { chat: c, confirm: true });
});
command('sh', 'Команда в папке проекта', (arg, c) => { if (!arg.trim()) throw new Error('/sh команда'); return ui.chats.shell(arg, { chat: c }); });
command('doctor', 'Диагностика установленного CLI', (_, c) => {
  if (!['codex', 'claude'].includes(c.target)) throw new Error('Диагностика доступна в Codex и Claude');
  return ui.chats.exec(c.target, ['doctor'], { chat: c, confirm: true });
});
command('release-notes', 'Версия установленного CLI', (arg, c) => ui.commands.get('version').run(arg, c));
command('debug-config', 'Действующие настройки Codex', (_, c) => codex(c, 'config/read', { cwd: c.cwd, includeLayers: true }));
command('features', 'Флаги установленного Codex', (_, c) => { if (c.target !== 'codex') throw new Error('Команда доступна в Codex'); return ui.chats.exec('codex', ['features', 'list'], { chat: c }); });
command('config-set', 'Записать настройку Codex: ключ JSON', async (arg, c) => {
  if (c.target !== 'codex') throw new Error('Команда доступна в Codex');
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  const parts = /^(\S+)\s+(.+)$/s.exec(arg.trim()); if (!parts) throw new Error('/config-set ключ JSON');
  const value = JSON.parse(parts[2]);
  if (confirm(`Изменить настройку Codex?\n\n${parts[1]} = ${JSON.stringify(value)}`)) await codex(c, 'config/value/write', { keyPath: parts[1], value, mergeStrategy: 'replace' });
});
command('rollout', 'Путь текущей истории Codex', async (_, c) => { if (c.target !== 'codex' || !c.thread) throw new Error('Сначала начни диалог Codex'); note(c, await call('codex', 'rollout', { thread: c.thread, home: c.account }) || 'Файл пока не найден'); });
command('worktree', 'Создать отдельную рабочую копию Git', (path, c) => { if (!path.trim()) throw new Error('/worktree путь'); return ui.chats.exec('git', ['worktree', 'add', '--detach', path.trim()], { chat: c, confirm: true }); });
command('memory', 'Открыть CLAUDE.md проекта', (_, c) => call('codex', 'open', { path: 'CLAUDE.md', cwd: c.cwd }));
command('memories', 'Открыть память Codex', (_, c) => { if (c.target !== 'codex') throw new Error('Команда доступна в Codex'); return call('codex', 'open', { path: `${c.account}/memories`, cwd: c.cwd }); });
command('add-dir', 'Добавить рабочую папку Claude', async (path, c) => {
  if (c.target !== 'claude') throw new Error('Команда доступна в Claude');
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  if (!path.trim()) throw new Error('/add-dir путь');
  const dir = await call('codex', 'resolveDir', { path: path.trim(), cwd: c.cwd });
  if (c.claudeStarted) await ui.chats.restart(c);
  c.extraDirs = [...new Set([...(c.extraDirs || []), dir])]; await ui.chats.save(c); note(c, `Claude получит доступ к: ${c.extraDirs.join(', ')}`);
});
command('sandbox', 'Песочница текущего чата Codex', async (arg, c) => {
  if (c.target !== 'codex') throw new Error('Команда доступна в Codex');
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  if (!arg.trim()) return note(c, `Песочница: ${c.sandbox}\n/sandbox read-only|workspace-write|danger-full-access`);
  if (!['read-only', 'workspace-write', 'danger-full-access'].includes(arg.trim())) throw new Error('Неизвестный режим песочницы');
  c.sandbox = arg.trim(); c.loaded = false; await ui.chats.save(c); note(c, `Песочница: ${c.sandbox}. Применится на следующем ходе.`);
});
command('switch', 'Сменить аккаунт Codex по номеру', async (arg, c) => {
  const account = /^\d+$/.test(arg.trim()) && ui.chats.accounts()[Number(arg) - 1];
  if (!account) throw new Error('/switch номер аккаунта');
  await ui.chats.switchAccount(c, account.home); note(c, `Аккаунт: ${account.name}`);
});
command('resume', 'Выбрать сохранённый разговор в истории', () => ui.chats.history());
command('exit', 'Закрыть вкладку с сохранением истории', (_, c) => ui.chats.close(c));
command('quit', 'Закрыть вкладку', (arg, c) => ui.commands.get('exit').run(arg, c));
command('title', 'Название чата', (arg, c) => ui.commands.get('rename').run(arg, c));
command('chats', 'Открытые чаты и состояние', (_, c) => note(c, ui.chats.list().map((chat, i) => `${i + 1}. ${chat.title} · ${chat.target} · ${chat.busy ? 'работает' : 'готов'}`).join('\n')));
command('cost', 'Расход последнего хода', (_, c) => note(c, c.usage || 'Нет данных о расходе'));
command('context', 'Использование контекста', (_, c) => note(c, c.usage || 'Провайдер ещё не прислал данные о контексте'));
command('todos', 'Текущий план', (_, c) => note(c, c.messages.findLast(m => m.kind === 'plan')?.text || 'Плана пока нет'));
command('focus', 'Скрыть вывод инструментов', (_, c) => { c.focus = !c.focus; ui.chats.refresh(c); });
command('raw', 'Развернуть вывод инструментов', (_, c) => { c.raw = !c.raw; ui.chats.refresh(c); });
command('rules', 'Правила приложения и текущего чата', (_,c) => ui.chats.openRules(c));
command('vless', 'Настройки прокси', () => ui.openSettings());
command('bot', 'Панель торгового бота', () => ui.openPanel('support'));

command('review', 'Ревью изменений проекта в Codex', (arg, c) => ui.chats.review(c, arg.trim()));
command('undo', 'Убрать последний ход из контекста Codex', (_, c) => ui.chats.undo(c));
command('init', 'Создать инструкции проекта', (_, c) => ui.chats.send(`Изучи этот проект и создай или актуализируй ${c.target === 'claude' ? 'CLAUDE.md' : 'AGENTS.md'} с краткими инструкциями по разработке, сборке и проверке.`, { chat: c, literal: true }));
command('multi', 'Передать задачу главному агенту команды', (arg, c, attachments = []) => {
  if (!arg.trim()) throw new Error('/multi задача');
  return ui.chats.send(`Работай как главный мультиагентной команды. Раздели задачу на независимые части и запусти субагентов параллельно. Каждому дай полное задание и свои файлы. Мелочь делай сам. Когда все закончат, проверь диффы, сборку и тесты, исправь ошибки. Дай итог: что сделано, чем проверено, что нет.\n\nЗадача:\n${arg}`, { chat: c, literal: true, attachments });
});
command('approvals', 'Автоподтверждение команд и правок: on/off', (arg, c) => {
  if (!['codex', 'claude'].includes(c.target)) throw new Error('API-подключение не запрашивает инструменты');
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  arg = arg.trim().toLowerCase();
  if (arg && !['on', 'off'].includes(arg)) throw new Error('/approvals [on|off]');
  if (arg === 'on' && !c.autoApprove && !confirm('Автоматически разрешать команды и изменения файлов в этом чате? Вопросы пользователя остаются ручными.')) return;
  if (arg) c.autoApprove = arg === 'on';
  note(c, `Автоподтверждение команд и правок: ${c.autoApprove ? 'включено' : 'выключено'}`);
});

command('plugin', 'Плагины установленного CLI', plugins);
async function plugins(arg, c) {
  const args = commandWords(arg), verb = args[0] || 'list';
  if (!['codex', 'claude'].includes(c.target)) throw new Error('Плагины доступны в Codex и Claude');
  if (c.target === 'claude') return ui.chats.exec('claude', ['plugin', ...(args.length ? args : ['list'])], { chat:c, confirm: !['list', 'search'].includes(verb) });
  if (['remove', 'uninstall'].includes(verb) && args.length === 2) {
    if (c.busy) throw new Error('Сначала заверши текущий ход');
    if (confirm(`Удалить плагин ${args[1]}?`)) await codex(c, 'plugin/uninstall', { pluginId:args[1] });
    return;
  }
  if (!['list', 'search', 'find', 'install', 'add'].includes(verb)) return ui.chats.exec('codex', ['plugin', ...args], {chat:c, confirm:true});
  const catalog = await ui.chats.rpc(c, 'plugin/list', {cwds:[c.cwd]});
  const all = (catalog.marketplaces || []).flatMap(m => (m.plugins || []).map(p => ({...p, market:m.name, marketplacePath:m.path})));
  if (['install', 'add'].includes(verb)) {
    if (c.busy) throw new Error('Сначала заверши текущий ход');
    const matches = all.filter(p => p.id === args[1] || p.name === args[1]);
    if (args.length !== 2 || matches.length !== 1) throw new Error('Уточни плагин: /plugins install имя@маркетплейс');
    const p = matches[0]; if (!confirm(`Установить плагин ${p.id} из ${p.market}?`)) return;
    return codex(c, 'plugin/install', {pluginName:p.name, installAttemptId:crypto.randomUUID(), ...(p.marketplacePath ? {marketplacePath:p.marketplacePath} : {remoteMarketplaceName:p.market})});
  }
  const query = args.slice(1).join(' ').toLowerCase();
  note(c, all.filter(p => !query || JSON.stringify(p).toLowerCase().includes(query)).slice(0,100).map(p => `${p.installed ? '✓' : '○'} ${p.interface?.displayName || p.name} · ${p.id}${p.interface?.shortDescription ? ' — ' + p.interface.shortDescription : ''}`).join('\n') || 'Плагинов не найдено');
}
command('agents', 'Агенты текущего провайдера', async (_, c) => c.target === 'claude' ? note(c, await call('claude', 'localFiles', {folder:'agents',cwd:c.cwd})) : codex(c, 'thread/loaded/list', {limit:100}));
command('reload-skills', 'Перечитать навыки проекта', (arg,c) => ui.commands.get('skills').run(arg,c));
command('reload-plugins', 'Перечитать плагины', (arg,c) => plugins(arg,c));
command('import', 'Найти конфигурацию других агентов', (_,c) => codex(c, 'externalAgentConfig/detect', {cwds:[c.cwd], includeHome:true}));
command('ps', 'Локальные процессы', async (_,c) => { const info = await call('app','info'); return ui.chats.exec(info.os === 'windows' ? 'tasklist' : 'ps', info.os === 'windows' ? ['/FO','TABLE'] : ['-axo','pid,etime,comm'], {chat:c}); });
command('mention', 'Отправить текстовый файл до 1 МБ', async (arg,c) => {
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  if (!arg.trim()) throw new Error('/mention путь');
  const path = await call('codex','resolvePath',{path:arg.trim(),cwd:c.cwd});
  const text = await call('api','readText',{path});
  return ui.chats.send(`Файл ${path}:\n\`\`\`\n${text}\n\`\`\``,{chat:c,literal:true});
});
command('login', 'Войти в аккаунт', async (_,c) => {
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  if (c.target === 'claude') return ui.chats.exec('claude',['auth','login'],{chat:c,confirm:true});
  const result = await codex(c,'account/login/start',{type:'chatgpt'}); if (result.authUrl) await call('limits','url',{url:result.authUrl});
});
command('logout', 'Выйти из текущего аккаунта', async (_,c) => {
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  if (!['codex','claude'].includes(c.target)) throw new Error('Авторизацией API управляет подключение');
  if (!confirm('Выйти из аккаунта? Для продолжения потребуется повторный вход.')) return;
  if (c.target === 'claude') return ui.chats.exec('claude',['auth','logout'],{chat:c});
  await codex(c,'account/logout'); await ui.chats.restart(c);
});
command('archive', 'Архивировать текущую историю Codex', async (_,c) => {
  if (c.busy || c.target !== 'codex' || !c.thread) throw new Error('Нужен свободный диалог Codex');
  await ui.chats.save(c); await ui.chats.rpc(c,'thread/archive',{threadId:c.thread});
  if (c.localId) await ui.chats.trash(`local:${c.localId}`);
  await ui.chats.trash(c.thread); await ui.chats.close(c);
});
command('unarchive', 'Восстановить историю Codex по ID', async (id,c) => {
  if (c.target !== 'codex' || !id.trim()) throw new Error('/unarchive ID диалога Codex');
  await codex(c,'thread/unarchive',{threadId:id.trim()}); await ui.chats.restoreTrash(id.trim());
});
command('delete', 'Удалить текущую историю Codex с подтверждением', async (_,c) => {
  if (c.busy || c.target !== 'codex' || !c.thread) throw new Error('Нужен свободный диалог Codex');
  if (!confirm(`Удалить историю текущего Codex-диалога и локальную копию Пульта без возможности восстановления?\n\n${c.thread}`)) return;
  await ui.chats.rpc(c,'thread/delete',{threadId:c.thread});
  if (c.localId) await call('codex','deleteLocal',{id:c.localId});
  c.messages=[]; c.thread=null; c.localId=null; c.turnMarks=[]; await ui.chats.close(c);
});

for (const [alias, name] of Object.entries({reset:'clear',cwd:'pwd',stats:'usage',clean:'stop'})) command(alias, ui.commands.get(name).hint, (arg,c) => ui.commands.get(name).run(arg,c));

for (const [name,panel] of Object.entries({mods:'mods',telegram:'telegram',update:'updater'})) command(name, 'Открыть ' + name, () => ui.openPanel(panel));
