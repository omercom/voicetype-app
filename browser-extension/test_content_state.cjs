const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "chrome/content.js"), "utf8");

function functionSource(name, next) {
  const start = source.indexOf(`  ${name}`);
  const end = source.indexOf(`\n  ${next}`, start);
  assert.ok(start >= 0 && end > start);
  return source.slice(start, end);
}

test("Request metadata reaches the UI without changes", async () => {
  const response = { ok: true, state: "preparing", stage: "loading", totalChunks: 20, characters: 6600 };
  let cleared = false;
  const context = vm.createContext({
    chrome: { runtime: { sendMessage: async () => response } },
    setTimeout: () => 1, clearTimeout: () => { cleared = true; },
  });
  vm.runInContext(functionSource("async function command", "async function poll"), context);
  assert.equal(await context.command("speak", "id", "selected"), response);
  assert.equal(cleared, true);
});

test("Timeout cancels immediately and cancels a late accepted start", async () => {
  let expire, resolveStart;
  const calls = [];
  const context = vm.createContext({
    chrome: { runtime: { sendMessage: request => {
      calls.push(request);
      return request.action === "speak" ? new Promise(resolve => { resolveStart = resolve; })
        : Promise.resolve({ ok: true, state: "idle" });
    } } },
    setTimeout: callback => { expire = callback; return 1; }, clearTimeout() {},
  });
  vm.runInContext(functionSource("async function command", "async function poll"), context);
  const pending = context.command("speak", "owner", "selected");
  expire();
  await assert.rejects(pending, /VoiceType yanıt vermedi/);
  resolveStart({ ok: true, state: "preparing" });
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(calls.map(request => request.action), ["speak", "stop", "stop"]);
  assert.ok(calls.every(request => request.id === "owner"));
});

function selectionContext(next) {
  const calls = [];
  const context = vm.createContext({
    scheduled: true, requestID: null, root: { activeElement: null },
    selected: { text: "same" }, selection: () => next,
    detail: { characters: 4 }, startedAt: 100,
    maximumCharacters: 30000, number: value => value.toLocaleString("tr-TR"),
    host: { hidden: false }, position() {}, setPhase: (...args) => calls.push(args),
  });
  vm.runInContext(functionSource("function updateSelection", "function scheduleSelection"), context);
  context.updateSelection();
  return { context, calls };
}

test("Unchanged selection keeps errors and completion messages", () => {
  const { context, calls } = selectionContext({ text: "same", rect: {} });
  assert.equal(calls.length, 0);
  assert.equal(context.detail.characters, 4);
  assert.equal(context.startedAt, 100);
});

test("New oversized selection shows an actionable error before sending", () => {
  const { context, calls } = selectionContext({ text: "ş".repeat(30001), rect: {} });
  assert.equal(calls[0][0], "error");
  assert.match(calls[0][1], /30\.001.*30\.000/);
  assert.equal(context.startedAt, 0);
  assert.equal(context.host.hidden, false);
});

test("Pause shows Resume and freezes time without hiding Stop or progress", () => {
  const element = () => ({
    attributes: {}, setAttribute(name, value) { this.attributes[name] = value; },
    removeAttribute(name) { delete this.attributes[name]; },
  });
  let now = 1000;
  const context = vm.createContext({
    phase: "idle", requestID: "owner", detail: null,
    startedAt: 1000, pausedAt: 0, pausedTotal: 0, elapsedTimer: null,
    performance: { now: () => now }, selected: { text: "text" },
    number: value => String(value), button: element(), stopButton: element(),
    status: element(), meta: element(), progress: element(), position() {},
    setInterval: () => 1, clearInterval() {},
  });
  vm.runInContext(functionSource("function updateMeta", "function updateSelection"), context);
  const metadata = { state: "playing", currentChunk: 2, completedChunks: 1, totalChunks: 20, characters: 6000 };
  context.setPhase("preparing", "", { ...metadata, stage: "loading" });
  assert.match(context.status.textContent, /Antalia Mini yükleniyor/);
  assert.doesNotMatch(context.status.textContent, /EMA/);
  context.setPhase("playing", "", metadata);
  assert.match(context.button.textContent, /Duraklat/);
  now = 2000;
  context.setPhase("paused", "", { ...metadata, state: "paused" });
  assert.match(context.button.textContent, /Devam et/);
  assert.equal(context.button.attributes["aria-label"], "Seslendirmeye devam et");
  assert.equal(context.stopButton.hidden, false);
  assert.equal(context.progress.hidden, false);
  assert.equal(context.progress.value, 1);
  now = 6000;
  context.updateMeta();
  assert.match(context.meta.textContent, /1 sn$/);
  context.setPhase("playing", "", metadata);
  now = 7000;
  context.updateMeta();
  assert.match(context.meta.textContent, /2 sn$/);
});
