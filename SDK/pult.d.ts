/** Pult 2.4 / .pult format 2. Native calls are permission-checked on every request. */
type ChatID = string;
type Placement = 'main' | 'left' | 'right' | 'sheet';
type ChatInfo = {id: ChatID; title: string; status: string; cwd: string; provider: string; model: string; busy: boolean; active: boolean};
interface PultMethods {
  'app.info': [{}, {apiVersion: 2; version: string; modID: string; dataPath: string; assetsPath: string; project: string; remainingTurns: number}];
  'log': [{message: string}, {ok: boolean}];
  'ui.toast': [{text: string}, {ok: boolean}];
  'ui.openPanel': [{panel: string; placement?: Placement}, {ok: boolean}];
  'ui.openTeam': [{}, {ok: boolean}];
  'ui.teamSettings': [{}, {ok: boolean}];
  'ui.openChat': [{}, {ok: boolean}];
  'ui.modSettings': [{}, {ok: boolean}];
  'settings.get': [{}, Record<string, string>];
  'settings.set': [{key: string; value: string}, {ok: boolean}];
  'storage.get': [{key: string}, unknown | null];
  'storage.set': [{key: string; value: unknown | null}, {ok: boolean}];
  'secrets.get': [{key: string}, string | null];
  'secrets.set': [{key: string; value: string}, {ok: boolean}];
  'chats.list': [{}, ChatInfo[]];
  'chats.read': [{id?: ChatID; limit?: number}, ChatInfo & {messages: {id: string; kind: string; text: string; done: boolean}[]}];
  'chats.create': [{title?: string; cwd?: string; provider?: 'codex' | 'claude'; model?: string; select?: boolean}, ChatInfo];
  'chats.send': [{id?: ChatID; text: string}, {id: ChatID; remainingTurns: number}];
  'chats.stop': [{id?: ChatID}, {ok: boolean}];
  'chats.activate': [{id: ChatID}, {ok: boolean}];
  'chats.append': [{id?: ChatID; text: string}, {ok: boolean}];
  'files.list': [{id?: ChatID; path?: string}, string[]];
  'files.read': [{id?: ChatID; path: string}, string];
  'files.write': [{id?: ChatID; path: string; text: string}, {ok: boolean}];
  'git.status': [{id?: ChatID}, string];
  /** Returns diff --stat; read an explicitly selected file with files.read. */
  'git.diff': [{id?: ChatID}, string];
  'team.state': [{}, {connected: boolean; peers: number; identity: string; ready: boolean; working: boolean; canClaim: boolean; blockReason: string; board: {revision: number; repository: string; tasks: any[]}; running: {chat: string; task: string}[]; messages: {id: string; author: string; text: string}[]}];
  'team.send': [{text: string}, {ok: boolean}];
  'team.addTask': [{title: string; detail?: string}, {ok: boolean}];
  'team.claim': [{ids: string[]}, {ok: boolean}];
  'network.fetch': [{url: string; method?: string; headers?: Record<string, string>; body?: string}, {status: number; body: string}];
  'process.start': [{id: string; executable: string; arguments: string[]; environment?: Record<string, string>}, {pid: number; running: boolean}];
  'process.stop': [{id: string}, {ok: boolean}];
  'process.read': [{id: string}, {running: boolean; text: string}];
}
interface PultEvents {
  'app.tick': {time: number};
  'chats.changed': {chats: ChatInfo[]; activeID: ChatID};
  'chat.finished': {id: ChatID; failed: boolean; text: string; teamTask: string};
  'chat.question': {id: ChatID};
  'chat.approval': {id: ChatID};
  'settings.changed': {settings: Record<string, string>};
  'process.exited': {id: string; code: number};
}
declare const pult: {
  readonly apiVersion: 2;
  call<K extends keyof PultMethods>(method: K, params?: PultMethods[K][0]): Promise<PultMethods[K][1]>;
  on<K extends keyof PultEvents>(event: K, handler: (detail: PultEvents[K]) => void): () => void;
};
declare const pultSettings: Record<string, string>;
