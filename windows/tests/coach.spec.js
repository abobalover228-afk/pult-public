import { test, expect } from '@playwright/test';
test('coach validates structured responses and rejects incomplete first rounds', async ({ page }) => {
  await page.addInitScript(() => window.__TAURI__ = { core: { invoke: async () => null }, event: { listen: async () => () => {} } });
  await page.goto('/limits.html');
  const result = await page.evaluate(async () => {
    const { parseReply } = await import('/coach.js');
    const valid = { status: 'questions', summary: 'Цель', questions: [{ id: 'q', text: 'Критерий?', options: ['Тесты', 'Демо'] }], improvedPrompt: '' };
    const rejected = [];
    for (const value of [{ ...valid, questions: [] }, { ...valid, questions: [valid.questions[0], valid.questions[0]] }, { status: 'ready', summary: '', questions: [], improvedPrompt: 'Готовый промпт' }]) {
      try { parseReply(JSON.stringify(value), true); rejected.push(false); } catch { rejected.push(true); }
    }
    return { status: parseReply(JSON.stringify(valid), true).status, rejected };
  });
  expect(result).toEqual({ status: 'questions', rejected: [true, true, true] });
});
