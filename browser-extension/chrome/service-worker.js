"use strict";

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message?.type !== "voicetype-command") return;
  (async () => {
    try {
      if (sender.id !== chrome.runtime.id || !Number.isInteger(sender.tab?.id)
          || !/^https?:\/\//.test(sender.url ?? "")) throw new Error("Geçersiz sayfa.");
      const { action, id } = message;
      if (!["speak", "stop", "pause", "resume", "status"].includes(action)
          || typeof id !== "string" || !/^[\da-f]{8}(-[\da-f]{4}){3}-[\da-f]{12}$/i.test(id)) {
        throw new Error("Geçersiz komut.");
      }
      const request = { action, id };
      if (action === "speak") {
        if (typeof message.text !== "string" || !message.text.trim()
            || Array.from(message.text.trim()).length > 30000) throw new Error("En fazla 30.000 karakter seçin.");
        request.text = message.text.trim();
      }
      const result = await chrome.runtime.sendNativeMessage("com.voicetype.ema", request);
      if (typeof result?.ok !== "boolean") throw new Error("VoiceType yanıt vermedi.");
      respond(result);
    } catch {
      respond({ ok: false, error: "VoiceType bağlantısı kurulamadı. Uygulamayı ve setup-chrome.sh kurulumunu kontrol edin." });
    }
  })();
  return true;
});

chrome.action.onClicked.addListener(async (tab) => {
  try {
    await chrome.tabs.sendMessage(tab.id, { type: "voicetype-focus" });
    await chrome.action.setBadgeText({ tabId: tab.id, text: "" });
  } catch {
    // Protected Chrome pages cannot run content scripts. Show feedback on the icon.
    await chrome.action.setBadgeText({ tabId: tab.id, text: "!" });
    await chrome.action.setTitle({ tabId: tab.id, title: "Bu sayfa desteklenmiyor. Normal bir web sayfasında metin seçin." });
  }
});
