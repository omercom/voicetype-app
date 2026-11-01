const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const id = "01234567-89ab-4cde-8123-0123456789ab";

function fixture(fail = false) {
  let listener;
  const forwarded = [];
  const chrome = {
    runtime: {
      id: "ours",
      onMessage: { addListener: (value) => { listener = value; } },
      sendNativeMessage: async (name, request) => {
        forwarded.push({ name, request });
        if (fail) throw new Error("Host missing");
        return { ok: true, state: "preparing" };
      },
    },
    action: { onClicked: { addListener() {} } },
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "chrome/service-worker.js"), "utf8"), { chrome });
  return {
    forwarded,
    send: (message, sender = { id: "ours", tab: { id: 1 }, url: "https://example.org/" }) =>
      new Promise((resolve) => { assert.equal(listener(message, sender, resolve), true); }),
  };
}

test("Selected Turkish text reaches only the local host", async () => {
  const worker = fixture();
  const result = await worker.send({ type: "voicetype-command", action: "speak", id, text: "  İyi günler.  ", shell: "ignored" });
  assert.equal(result.ok, true);
  assert.equal(worker.forwarded[0].name, "com.voicetype.ema");
  assert.equal(JSON.stringify(worker.forwarded[0].request), JSON.stringify({ action: "speak", id, text: "İyi günler." }));
});

test("Pause and resume forward only the owner request ID", async () => {
  const worker = fixture();
  for (const action of ["pause", "resume"]) {
    const result = await worker.send({ type: "voicetype-command", action, id, text: "ignored", shell: "ignored" });
    assert.equal(result.ok, true);
    assert.equal(worker.forwarded.at(-1).name, "com.voicetype.ema");
    assert.equal(JSON.stringify(worker.forwarded.at(-1).request), JSON.stringify({ action, id }));
    assert.equal((await worker.send({ type: "voicetype-command", action, id: "bad" })).ok, false);
  }
  assert.equal(worker.forwarded.length, 2);
});

test("Foreign senders, protected pages and non-tab messages are rejected", async () => {
  const worker = fixture();
  for (const sender of [{ id: "foreign", tab: { id: 1 }, url: "https://example.org/" },
    { id: "ours", tab: { id: 1 }, url: "chrome://settings/" }, { id: "ours", url: "https://example.org/" }]) {
    assert.equal((await worker.send({ type: "voicetype-command", action: "status", id }, sender)).ok, false);
  }
  assert.equal(worker.forwarded.length, 0);
});

test("Bad commands and oversized text are rejected", async () => {
  const worker = fixture();
  for (const command of [{ action: "shell", id }, { action: "stop", id: "bad" },
    { action: "speak", id, text: " " }, { action: "speak", id, text: "ş".repeat(30001) }]) {
    assert.equal((await worker.send({ type: "voicetype-command", ...command })).ok, false);
  }
  assert.equal(worker.forwarded.length, 0);
});

test("Long selections and Unicode reach the host without truncation", async () => {
  const worker = fixture();
  const text = "ş😀".repeat(15000);
  const result = await worker.send({ type: "voicetype-command", action: "speak", id, text });
  assert.equal(result.ok, true);
  assert.equal(worker.forwarded[0].request.text, text);
});

test("Missing host returns a user-readable error", async () => {
  const result = await fixture(true).send({ type: "voicetype-command", action: "status", id });
  assert.equal(result.ok, false);
  assert.match(result.error, /setup-chrome/);
});
