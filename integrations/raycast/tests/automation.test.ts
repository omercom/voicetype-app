import assert from "node:assert/strict";
import test from "node:test";
import { requestDictation, sendVoiceTypeCommand, statusMessage } from "../src/automation";

test("start passes the target as an argument instead of executable script text", async () => {
  const target = 'com.example.editor"; malicious command';
  const output = await sendVoiceTypeCommand("start", target, async (file, args) => {
    assert.equal(file, "/usr/bin/osascript");
    assert.equal(args[0], "-e");
    assert.match(args[1], /start dictation \(item 1 of argv\)/);
    assert.ok(!args[1].includes(target));
    assert.equal(args[2], target);
    return "requested\n";
  });
  assert.equal(output, "requested");
});

test("start requires an explicit target", async () => {
  await assert.rejects(sendVoiceTypeCommand("start", "  ", async () => "requested"));
});

test("stop and settings use fixed automation commands", async () => {
  const seen: string[] = [];
  const executor = async (_file: string, args: string[]) => {
    seen.push(args[1]);
    assert.equal(args.length, 2);
    return "idle\n";
  };
  assert.equal(await sendVoiceTypeCommand("stop", undefined, executor), "idle");
  assert.equal(await sendVoiceTypeCommand("settings", undefined, executor), "idle");
  assert.match(seen[0], /stop dictation/);
  assert.match(seen[1], /open voice settings/);
});

test("target changes and unknown statuses never claim success", () => {
  assert.match(statusMessage("target-changed"), /Hedef değişti/);
  assert.match(statusMessage("unexpected"), /hazır değil/);
  assert.match(statusMessage("requested"), /isteği/);
});

test("Raycast closes before selecting the target and sending the request", async () => {
  const steps: string[] = [];
  const status = await requestDictation(
    async () => { steps.push("close"); },
    async () => { steps.push("target"); return "com.example.editor"; },
    async (target) => { steps.push(`send:${target}`); return "requested"; },
  );
  assert.equal(status, "requested");
  assert.deepEqual(steps, ["close", "target", "send:com.example.editor"]);
});

test("no request is sent without a target application", async () => {
  let sent = false;
  const status = await requestDictation(
    async () => {},
    async () => undefined,
    async () => { sent = true; return "requested"; },
  );
  assert.equal(status, "missing-target");
  assert.equal(sent, false);
});
