// Optional live test. Requires Playwright, its Chromium browser, and the installed app.
// A closed shadow root is inspected through Chromium's accessibility tree, not bypassed.
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { setTimeout: delay } = require("node:timers/promises");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

const profile = process.env.VOICETYPE_E2E_PROFILE;
const output = process.env.VOICETYPE_E2E_OUTPUT;
if (!profile || !output) throw new Error("Set VOICETYPE_E2E_PROFILE and VOICETYPE_E2E_OUTPUT to dedicated test directories.");
const extension = path.resolve(__dirname, "../chrome");
const identifier = "nhbnnebmgoemjnaiglhnddflibjofcgd";
const longText = "İstanbul'da bugün hava açık. Toplantı yarın saat on dört otuzda başlayacak. "
  + "Lütfen raporu kontrol edip ekibe gönderin. Öğleden sonra ılık bir çay içtik. ";
const html = `<!doctype html><html lang="tr"><meta charset="utf-8"><title>Antalia yerel okuma testi</title>
<body><main><h1>Antalia yerel okuma testi</h1><p id="long">${longText.repeat(10)}</p>
<p id="short">Merhaba. Bu ses yapay zekâ ile üretilmiştir.</p>
<label for="private">Parola</label><input id="private" type="password" value="gizli-test"></main></body></html>`;

async function main() {
  await fs.mkdir(output, { recursive: true });
  const results = { createdAt: new Date().toISOString(), checks: [] };
  const server = http.createServer((request, response) => {
    response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    response.end(html);
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  let context, page, cdp;
  async function wavFiles() {
    const files = [];
    for (const folder of await fs.readdir(os.tmpdir())) {
      if (!folder.startsWith("voicetype-tts-")) continue;
      const directory = path.join(os.tmpdir(), folder);
      for (const name of await fs.readdir(directory).catch(() => [])) {
        if (name.endsWith(".wav")) files.push(path.join(directory, name));
      }
    }
    return files;
  }
  const baselineFiles = new Set(await wavFiles());
  const generatedFiles = new Set();
  async function rememberAudio() {
    const files = (await wavFiles()).filter(file => !baselineFiles.has(file));
    assert.ok(files.length > 0, "The app must create a real WAV during playback");
    for (const file of files) {
      generatedFiles.add(file);
      assert.equal((await fs.stat(file)).mode & 0o777, 0o600);
      assert.equal((await fs.stat(path.dirname(file))).mode & 0o777, 0o700);
    }
  }
  const check = (name, detail = null) => {
    results.checks.push({ name, detail });
    console.log("PASS:", name);
  };
  const tree = async () => (await cdp.send("Accessibility.getFullAXTree")).nodes.filter(node => !node.ignored);
  const text = nodes => nodes.map(node => node.name?.value || "").join("\n");
  async function until(predicate, label, timeout = 30000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      const nodes = await tree();
      if (predicate(nodes)) return nodes;
      await delay(150);
    }
    throw new Error(`Timed out: ${label}\n${text(await tree())}`);
  }
  async function click(pattern) {
    const nodes = await until(nodes => nodes.some(node => node.role?.value === "button" && pattern.test(node.name?.value)), "button " + pattern);
    const node = nodes.find(node => node.role?.value === "button" && pattern.test(node.name?.value));
    const { model } = await cdp.send("DOM.getBoxModel", { backendNodeId: node.backendDOMNodeId });
    const quad = model.content;
    await page.mouse.click((quad[0] + quad[2] + quad[4] + quad[6]) / 4,
                           (quad[1] + quad[3] + quad[5] + quad[7]) / 4);
  }
  async function select(selector) {
    await page.locator(selector).click();
    const selectedText = await page.locator(selector).evaluate(element => {
      const selection = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(element);
      selection.removeAllRanges();
      selection.addRange(range);
      return selection.toString().trim();
    });
    const count = Array.from(selectedText).length.toLocaleString("tr-TR");
    await until(nodes => text(nodes).includes(`${count} / 30.000 karakter`)
      && nodes.some(node => node.role?.value === "button" && /Seçili metni Türkçe seslendir/.test(node.name?.value)),
      "updated selection and read button");
  }
  try {
    context = await chromium.launchPersistentContext(profile, {
      channel: "chromium", headless: true, viewport: { width: 1100, height: 800 },
      args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`],
    });
    page = await context.newPage();
    cdp = await context.newCDPSession(page);
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    const worker = context.serviceWorkers().find(worker => worker.url().includes(identifier))
      || await context.waitForEvent("serviceworker", { timeout: 15000 });
    assert.ok(worker.url().includes(identifier));
    results.browser = context.browser()?.version() || await cdp.send("Browser.getVersion");
    check("Real unpacked extension loaded");
    await select("#long");
    check("Selected text exposes the read button");
    const started = Date.now();
    await click(/Seçili metni Türkçe seslendir/);
    await until(nodes => /Türkçe okunuyor/.test(text(nodes)), "actual playback");
    check("Click reaches the installed app and starts Antalia playback", { uiPlayingMs: Date.now() - started });
    await rememberAudio();
    await page.screenshot({ path: path.join(output, "playing.png") });

    await click(/Seslendirmeyi duraklat/);
    const paused = text(await until(nodes => /Okuma duraklatıldı/.test(text(nodes)), "paused"));
    const meta = paused.match(/[\d.]+ \/ 30\.000 karakter · Yerelde · \d+ sn/)?.[0];
    const section = paused.match(/Bölüm \d+\/\d+/)?.[0];
    assert.ok(meta && section);
    await delay(1800);
    const stillPaused = text(await tree());
    assert.ok(stillPaused.includes(meta) && stillPaused.includes(section));
    check("Pause freezes elapsed time and current section");
    await page.screenshot({ path: path.join(output, "paused.png") });
    let focusedResume = false;
    for (let attempt = 0; attempt < 5; attempt += 1) {
      await page.keyboard.press("Tab");
      focusedResume = (await tree()).some(node => /Seslendirmeye devam et/.test(node.name?.value)
        && node.properties?.some(property => property.name === "focused" && property.value.value === true));
      if (focusedResume) break;
    }
    assert.ok(focusedResume, "Tab must reach the resume button");
    await page.keyboard.press("Space");
    await until(nodes => /Türkçe okunuyor/.test(text(nodes)), "keyboard resume");
    check("Space resumes from the paused position");
    await until(nodes => /Türkçe okunuyor · Bölüm 2\//.test(text(nodes)), "second section playback", 60000);
    await rememberAudio();
    check("Long reading advances to the second section");
    await click(/Seslendirmeyi durdur/);
    await until(nodes => /Okuma durduruldu/.test(text(nodes)), "stop");
    check("Stop cancels the remaining sections");

    await select("#short");
    await click(/Seçili metni Türkçe seslendir/);
    await until(nodes => /Türkçe okunuyor/.test(text(nodes)), "short playback");
    await rememberAudio();
    await until(nodes => /Okuma bitti\./.test(text(nodes)), "normal completion");
    await delay(600);
    assert.match(text(await tree()), /Okuma bitti\./);
    check("Short reading finishes and preserves its completion message");
    await page.screenshot({ path: path.join(output, "completed.png") });
    const remainingFiles = new Set(await wavFiles());
    assert.ok([...generatedFiles].every(file => !remainingFiles.has(file)));
    check("Real WAV files use private permissions and are deleted after stop/completion");

    await page.locator("#private").evaluate(element => { element.focus(); element.select(); });
    await delay(400);
    assert.ok(!(await tree()).some(node => node.role?.value === "button"));
    check("Password selection exposes no read control");
    results.passed = true;
  } catch (error) {
    results.passed = false;
    results.error = String(error);
    if (page && cdp) {
      await page.screenshot({ path: path.join(output, "failure.png") }).catch(() => {});
      const nodes = await tree().catch(() => []);
      if (nodes.some(node => node.role?.value === "button" && /Seslendirmeyi durdur/.test(node.name?.value))) {
        await click(/Seslendirmeyi durdur/).catch(() => {});
        await until(nodes => /Okuma durduruldu/.test(text(nodes)), "failure cleanup", 5000).catch(() => {});
      }
    }
    throw error;
  } finally {
    await context?.close();
    await new Promise(resolve => server.close(resolve));
    await fs.writeFile(path.join(output, "result.json"), JSON.stringify(results, null, 2));
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
