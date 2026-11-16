import { copyFileSync } from 'node:fs';
for (const [from, to] of [
  ['marked/lib/marked.esm.js', 'marked.js'], ['marked/LICENSE', 'marked.LICENSE.md'],
  ['dompurify/dist/purify.es.mjs', 'purify.js'], ['dompurify/LICENSE', 'dompurify.LICENSE'],
]) copyFileSync(`node_modules/${from}`, `ui/vendor/${to}`);
