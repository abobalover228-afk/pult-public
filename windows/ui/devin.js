export const devinProvider = 'api:devin';

export function devinSession(value) {
  value = typeof value === 'string' ? value.trim() : '';
  const id = (value.match(/^https:\/\/app\.devin\.ai\/sessions\/([^/?#]+)(?:[/?#].*)?$/i)?.[1] || value).replace(/^devin-/i, '');
  return /^[a-z0-9][a-z0-9-]*$/i.test(id || '') ? 'devin-' + id : '';
}

export function devinUrl(session) {
  if (!session) throw new Error('Сначала отправь сообщение или подключи сессию через /session');
  return 'https://app.devin.ai/sessions/' + session.replace(/^devin-/, '');
}

export async function devinClient(sdk) {
  const { org } = await sdk('settings.get');
  const key = await sdk('secrets.get', { key: 'DEVIN_API_KEY' });
  if (!key) throw new Error('Сохрани API-ключ в панели Devin');
  const legacy = key.startsWith('apk_');
  if (!legacy && !/^org-[a-z0-9-]+$/i.test(org?.trim())) throw new Error('Укажи org_id в панели Devin');
  const base = 'https://api.devin.ai' + (legacy ? '/v1' : '/v3/organizations/' + org.trim()) + '/sessions';

  async function request(path, body) {
    const result = await sdk('network.fetch', {
      url: base + path,
      method: body === undefined ? 'GET' : 'POST',
      headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (result.status === 401) throw new Error('Devin API 401. Обнови API-ключ в панели Devin.');
    if (result.status < 200 || result.status >= 300) throw new Error('Devin API ' + result.status);
    return result.body ? JSON.parse(result.body) : null;
  }

  const status = session => request('/' + session);
  async function messages(session, details, cursor = '', current = () => true) {
    const items = [];
    if (legacy) items.push(...((details || await status(session)).messages || []));
    else {
      while (current()) {
        const page = await request('/' + session + '/messages?first=100' + (cursor ? '&after=' + encodeURIComponent(cursor) : ''));
        items.push(...page.items);
        const next = page.end_cursor;
        if (!page.has_next_page) { cursor = next || cursor; break; }
        if (!next || next === cursor) throw new Error('Devin вернул некорректный курсор истории');
        cursor = next;
      }
    }
    return {
      cursor,
      items: items.flatMap(m => {
        const source = legacy ? ({ initial_user_message: 'user', user_message: 'user', devin_message: 'devin' })[m.type] : m.source;
        return m.event_id && m.message?.trim() && ['user', 'devin'].includes(source)
          ? [{ id: 'devin-event:' + m.event_id, kind: source === 'user' ? 'user' : 'agent', text: m.message }] : [];
      }),
    };
  }

  return {
    status, messages,
    create: async prompt => {
      const session = devinSession((await request('', { prompt }))?.session_id);
      if (!session) throw new Error('Devin не вернул ID новой сессии');
      return session;
    },
    send: (session, message) => request('/' + session + (legacy ? '/message' : '/messages'), { message }),
  };
}

export function devinWaiting(details) {
  return [details.status_detail, details.status_enum, details.status].some(status =>
    /^(blocked|expired|waiting_for_user|waiting_for_approval|finished|completed|suspended|exit|exited|error|failed|stopped|terminated|cancelled)$/i.test(status));
}

export async function watchDevin(client, session, cursor, current, receive, sent = false) {
  while (current()) {
    const details = await client.status(session);
    if (!current()) return;
    const page = await client.messages(session, details, cursor, current);
    if (!current()) return;
    cursor = page.cursor;
    const replied = await receive(page.items);
    if (devinWaiting(details) && (!sent || replied)) return;
    sent = false;
    await new Promise(resolve => setTimeout(resolve, 4000));
  }
}
