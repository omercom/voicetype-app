(() => {
  "use strict";
  if (globalThis.__voiceTypeReadAloud) return;
  globalThis.__voiceTypeReadAloud = true;
  const host = document.createElement("div");
  host.dataset.voicetypeWidget = "true";
  host.hidden = true;
  const root = host.attachShadow({ mode: "closed" });
  const style = new CSSStyleSheet();
  style.replaceSync(`
    :host { all:initial; position:fixed; z-index:2147483647; color-scheme:light dark; }
    :host([hidden]) { display:none; }
    .panel { display:flex; align-items:center; gap:10px; padding:6px; border:1px solid #94a3b8;
      border-radius:16px; background:#fff; color:#0f172a; box-shadow:0 8px 28px #0003;
      max-width:calc(100vw - 24px); font:14px/1.4 system-ui,sans-serif; }
    button { border:0; border-radius:11px; padding:10px 14px; min-height:48px; min-width:48px; background:#0f172a;
      color:#fff; cursor:pointer; white-space:nowrap; font:600 14px/1.4 system-ui,sans-serif; }
    button:focus-visible { outline:3px solid #0284c7; outline-offset:3px; }
    button[aria-disabled="true"] { cursor:wait; opacity:.65; }
    .controls { display:flex; gap:6px; flex-wrap:wrap; }
    .details { display:grid; gap:4px; min-width:0; max-width:270px; padding-right:6px; overflow-wrap:anywhere; }
    @media(max-width:480px) { .panel { flex-direction:column; align-items:stretch; } }
    .meta { color:#475569; font-size:12px; }
    progress { width:100%; height:6px; accent-color:#0284c7; }
    [hidden] { display:none; }
    @media(prefers-color-scheme:dark) {
      .panel { background:#0f172a; color:#f8fafc; border-color:#64748b; }
      button { background:#f8fafc; color:#0f172a; }
      .meta { color:#cbd5e1; }
    }
  `);
  root.adoptedStyleSheets = [style];
  const panel = document.createElement("div");
  panel.className = "panel";
  const button = document.createElement("button");
  button.type = "button";
  button.title = "VoiceType · Yerel yapay zekâ sesi · Türkçe";
  const stopButton = document.createElement("button");
  stopButton.type = "button";
  stopButton.textContent = "■ Durdur";
  stopButton.setAttribute("aria-label", "Seslendirmeyi durdur");
  stopButton.hidden = true;
  const controls = document.createElement("div");
  controls.className = "controls";
  controls.append(button, stopButton);
  const status = document.createElement("span");
  status.setAttribute("role", "status");
  status.setAttribute("aria-live", "polite");
  status.setAttribute("aria-atomic", "true");
  const details = document.createElement("div");
  details.className = "details";
  const meta = document.createElement("span");
  meta.className = "meta";
  const progress = document.createElement("progress");
  progress.setAttribute("aria-label", "Tamamlanan okuma bölümleri");
  progress.hidden = true;
  details.append(status, meta, progress);
  panel.append(controls, details);
  root.append(panel);
  document.documentElement.append(host);
  let selected = null;
  let requestID = null;
  let phase = "idle";
  let controlVersion = 0;
  let pollTimer;
  let elapsedTimer;
  let startedAt = 0;
  let pausedAt = 0;
  let pausedTotal = 0;
  let detail = null;
  let scheduled = false;
  const maximumCharacters = 30000;
  const number = (value) => value.toLocaleString("tr-TR");

  function isPrivate(element) {
    if (!(element instanceof Element)) return false;
    return Boolean(element.closest('[data-voicetype-private], input[type="password"]'))
      || /(?:password|one-time-code|cc-)/i.test(element.getAttribute("autocomplete") ?? "")
      || (getComputedStyle(element).webkitTextSecurity ?? "none") !== "none";
  }

  function selection() {
    const active = document.activeElement;
    if (isPrivate(active)) return null;
    if (active instanceof HTMLTextAreaElement || active instanceof HTMLInputElement) {
      if (active instanceof HTMLInputElement && !["text", "search", "url", "email", "tel"].includes(active.type)) return null;
      if (active.selectionStart == null || active.selectionEnd <= active.selectionStart) return null;
      const text = active.value.slice(active.selectionStart, active.selectionEnd).trim();
      return text ? { text, rect: active.getBoundingClientRect() } : null;
    }
    const range = window.getSelection();
    if (!range?.rangeCount || range.isCollapsed) return null;
    const bounds = range.getRangeAt(0);
    const element = bounds.commonAncestorContainer.nodeType === Node.ELEMENT_NODE
      ? bounds.commonAncestorContainer : bounds.commonAncestorContainer.parentElement;
    if (isPrivate(element) || host.contains(element)) return null;
    for (const privateArea of document.querySelectorAll("[data-voicetype-private]")) {
      if (bounds.intersectsNode(privateArea)) return null;
    }
    const text = range.toString().trim();
    const visible = Array.from(bounds.getClientRects()).filter(rect => rect.bottom > 0 && rect.top < innerHeight);
    return text ? { text, rect: visible.at(-1) ?? bounds.getBoundingClientRect() } : null;
  }

  function position() {
    if (!selected) return;
    const width = Math.min(panel.getBoundingClientRect().width || 280, innerWidth - 24);
    host.style.left = `${Math.max(12, Math.min(selected.rect.left, innerWidth - width - 12))}px`;
    host.style.top = `${Math.max(12, Math.min(selected.rect.bottom + 8, innerHeight - panel.getBoundingClientRect().height - 12))}px`;
  }

  function updateMeta() {
    const count = detail?.characters ?? Array.from(selected?.text ?? "").length;
    const elapsed = startedAt ? Math.floor(((pausedAt || performance.now()) - startedAt - pausedTotal) / 1000) : 0;
    meta.textContent = `${number(count)} / 30.000 karakter · Yerelde${startedAt ? ` · ${elapsed} sn` : ""}`;
  }

  function setPhase(value, message = "", result = null) {
    phase = value;
    if (result) detail = result;
    if (value === "paused" && !pausedAt) pausedAt = performance.now();
    else if (pausedAt && !["paused", "resuming"].includes(value)) {
      pausedTotal += performance.now() - pausedAt;
      pausedAt = 0;
    }
    const paused = value === "paused" || (value === "error" && requestID && detail?.state === "paused");
    const active = ["preparing", "playing", "paused", "pausing", "resuming"].includes(value) || (value === "error" && requestID);
    button.textContent = paused ? "▶ Devam et" : value === "pausing" ? "Duraklatılıyor…" : value === "resuming" ? "Devam ediyor…" : active ? "⏸ Duraklat" : value === "sending" ? "Gönderiliyor…" : value === "stopping" ? "Duruyor…" : value === "error" ? "↻ Tekrar dene" : "🔊 Oku";
    button.setAttribute("aria-label", paused ? "Seslendirmeye devam et" : active ? "Seslendirmeyi duraklat" : "Seçili metni Türkçe seslendir");
    const pending = ["sending", "stopping", "pausing", "resuming"].includes(value);
    button.setAttribute("aria-disabled", String(pending));
    stopButton.hidden = !requestID || value === "sending";
    stopButton.setAttribute("aria-disabled", String(pending));
    const section = detail?.totalChunks ? ` · Bölüm ${detail.currentChunk}/${detail.totalChunks}` : "";
    status.textContent = message || (value === "sending" ? "İstek gönderiliyor…"
      : value === "preparing" ? `${detail?.stage === "loading" ? "Metin alındı. Antalia Mini yükleniyor…" : "Metin alındı. Ses hazırlanıyor…"}${section}`
      : value === "playing" ? `Türkçe okunuyor${section}`
      : value === "paused" ? `Okuma duraklatıldı${section} · Kaldığınız yerden devam edebilirsiniz.`
      : value === "pausing" ? "Okuma duraklatılıyor…"
      : value === "resuming" ? "Okuma kaldığı yerden devam ediyor…"
      : value === "stopping" ? "Okuma durduruluyor…" : "Seçili metin okumaya hazır.");
    progress.setAttribute("aria-busy", String(["sending", "preparing"].includes(value)));
    progress.hidden = !["sending", "preparing", "playing", "paused", "pausing", "resuming"].includes(value);
    if (detail?.totalChunks && value !== "sending") {
      progress.max = detail.totalChunks;
      progress.value = detail.completedChunks ?? 0;
    } else { progress.removeAttribute("value"); }
    if (!["sending", "preparing", "playing", "stopping", "pausing", "resuming"].includes(value)) {
      clearInterval(elapsedTimer); elapsedTimer = null;
    } else if (!elapsedTimer) { elapsedTimer = setInterval(updateMeta, 1000); }
    updateMeta();
    position();
  }

  function updateSelection() {
    scheduled = false;
    if (requestID || root.activeElement) return;
    const next = selection();
    if (next && next.text === selected?.text) { selected = next; position(); return; }
    selected = next;
    detail = null;
    startedAt = 0;
    pausedAt = 0;
    pausedTotal = 0;
    host.hidden = !selected;
    if (selected) {
      const count = Array.from(selected.text).length;
      setPhase(count > maximumCharacters ? "error" : "idle", count > maximumCharacters
        ? `Seçim çok uzun: ${number(count)} karakter. En fazla 30.000 karakter seçin.` : "");
      position();
    }
  }

  function scheduleSelection() {
    if (!scheduled) { scheduled = true; requestAnimationFrame(updateSelection); }
  }

  async function command(action, id, text) {
    let timer;
    let expired = false;
    try {
      const pending = chrome.runtime.sendMessage({ type: "voicetype-command", action, id, ...(text ? { text } : {}) });
      const stopExpired = () => {
        chrome.runtime.sendMessage({ type: "voicetype-command", action: "stop", id }).catch(() => {});
      };
      pending.then(result => { if (expired && action === "speak" && result?.ok) stopExpired(); }, () => {});
      const result = await Promise.race([
        pending,
        new Promise((_, reject) => { timer = setTimeout(() => {
          expired = true;
          if (action !== "stop") stopExpired();
          reject(new Error("VoiceType yanıt vermedi. Uygulamayı kontrol edin; menüden okumayı durdurabilirsiniz."));
        }, 12000); }),
      ]);
      if (!result?.ok) throw new Error(result?.error || "VoiceType bağlantısı kurulamadı.");
      if (!["idle", "preparing", "playing", "paused"].includes(result.state)) throw new Error("VoiceType durumu alınamadı.");
      return result;
    } finally { clearTimeout(timer); }
  }

  async function poll() {
    const id = requestID;
    const version = controlVersion;
    if (!id) return;
    try {
      const result = await command("status", id);
      if (requestID !== id || version !== controlVersion || ["stopping", "pausing", "resuming"].includes(phase)) return;
      if (result.state === "idle") {
        requestID = null;
        const finished = result.totalChunks > 0 && result.completedChunks === result.totalChunks;
        setPhase("idle", finished ? "Okuma bitti." : "Okuma durduruldu.", result);
      } else {
        setPhase(result.state, "", result);
        pollTimer = setTimeout(poll, 500);
      }
    } catch (error) {
      if (requestID === id && version === controlVersion && !["stopping", "pausing", "resuming"].includes(phase)) { requestID = null; setPhase("error", error.message); }
    }
  }

  for (const control of [button, stopButton]) {
    control.addEventListener("pointerdown", (event) => {
      if (event.isTrusted) event.preventDefault(); // Keep the page selection and caret intact.
    });
  }
  button.addEventListener("click", async (event) => {
    if (!event.isTrusted || button.getAttribute("aria-disabled") === "true") return;
    clearTimeout(pollTimer);
    controlVersion += 1;
    try {
      if (requestID) {
        const id = requestID;
        const action = phase === "paused" || detail?.state === "paused" ? "resume" : "pause";
        setPhase(action === "pause" ? "pausing" : "resuming");
        const result = await command(action, id);
        if (requestID !== id) return;
        if (result.state === "idle") requestID = null;
        setPhase(result.state, result.state === "idle" ? "Okuma bitti veya durduruldu." : "", result);
        if (requestID) pollTimer = setTimeout(poll, 300);
        return;
      }
      const count = Array.from(selected?.text ?? "").length;
      if (!count || count > maximumCharacters) {
        setPhase("error", count > maximumCharacters
          ? `Seçim çok uzun: ${number(count)} karakter. En fazla 30.000 karakter seçin.` : "Önce metin seçin.");
        return;
      }
      requestID = crypto.randomUUID();
      detail = null;
      startedAt = performance.now();
      pausedAt = 0;
      pausedTotal = 0;
      clearInterval(elapsedTimer);
      elapsedTimer = setInterval(updateMeta, 1000);
      setPhase("sending");
      const id = requestID;
      const result = await command("speak", id, selected.text);
      if (requestID !== id) return;
      setPhase(result.state, "", result);
      pollTimer = setTimeout(poll, 300);
    } catch (error) {
      if (phase === "sending") requestID = null;
      setPhase("error", error.message);
    }
  });

  stopButton.addEventListener("click", async (event) => {
    if (!event.isTrusted || stopButton.getAttribute("aria-disabled") === "true" || !requestID) return;
    const id = requestID;
    controlVersion += 1;
    clearTimeout(pollTimer);
    setPhase("stopping");
    try {
      await command("stop", id);
      if (requestID !== id) return;
      requestID = null;
      const focusedStop = root.activeElement === stopButton;
      setPhase("idle", "Okuma durduruldu.");
      if (focusedStop) button.focus({ preventScroll: true });
    } catch (error) { if (requestID === id) setPhase("error", error.message); }
  });

  for (const type of ["selectionchange", "pointerup", "keyup", "focusin", "focusout"]) {
    document.addEventListener(type, scheduleSelection, { passive: true });
  }
  addEventListener("resize", position, { passive: true });
  addEventListener("scroll", () => { if (requestID) position(); else scheduleSelection(); }, { passive: true, capture: true });
  addEventListener("pagehide", () => { clearTimeout(pollTimer); clearInterval(elapsedTimer); });
  addEventListener("pageshow", () => {
    if (requestID) { clearInterval(elapsedTimer); elapsedTimer = setInterval(updateMeta, 1000); poll(); }
    else scheduleSelection();
  });
  chrome.runtime.onMessage.addListener((message, sender) => {
    if (message?.type !== "voicetype-focus" || sender.id !== chrome.runtime.id) return;
    if (!requestID) updateSelection();
    host.hidden = false;
    if (!selected) { host.style.left = "12px"; host.style.top = "12px"; setPhase("error", "Önce metin seçin."); }
    button.focus({ preventScroll: true });
  });
  setPhase("idle");
})();
