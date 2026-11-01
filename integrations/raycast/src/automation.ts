import { execFile } from "node:child_process";

export type VoiceTypeCommand = "start" | "stop" | "settings" | "status";
type Executor = (file: string, args: string[]) => Promise<string>;

const scripts: Record<VoiceTypeCommand, string> = {
  start: `on run argv
    tell application id "com.antigravity.VoiceTyping"
      return start dictation (item 1 of argv)
    end tell
  end run`,
  stop: `tell application id "com.antigravity.VoiceTyping" to stop dictation`,
  settings: `tell application id "com.antigravity.VoiceTyping" to open voice settings`,
  status: `tell application id "com.antigravity.VoiceTyping" to voice automation status`,
};

const execute: Executor = (file, args) =>
  new Promise((resolve, reject) => {
    execFile(file, args, { encoding: "utf8", timeout: 120_000 }, (error, stdout) => {
      if (error) reject(error);
      else resolve(stdout);
    });
  });

export async function sendVoiceTypeCommand(
  command: VoiceTypeCommand,
  targetBundle?: string,
  executor: Executor = execute,
): Promise<string> {
  if (command === "start" && !targetBundle?.trim()) {
    throw new Error("A target application is required.");
  }
  const args = ["-e", scripts[command]];
  if (command === "start") args.push(targetBundle!.trim());
  return (await executor("/usr/bin/osascript", args)).trim();
}

export async function requestDictation(
  closeWindow: () => Promise<void>,
  frontmostBundle: () => Promise<string | undefined>,
  send: (targetBundle: string) => Promise<string>,
): Promise<string> {
  await closeWindow();
  const target = await frontmostBundle();
  return target ? send(target) : "missing-target";
}

export function statusMessage(status: string): string {
  switch (status) {
    case "requested": return "Dikte başlatma isteği gönderildi.";
    case "stopping": return "Dikte tamamlanıyor.";
    case "cancelled": return "Dikte başlatma iptal edildi.";
    case "finishing": return "Dikte zaten tamamlanıyor.";
    case "idle": return "Etkin dikte yok.";
    case "opened": return "VoiceType ayarları açıldı.";
    case "busy": return "VoiceType başka bir dikteyle meşgul.";
    case "target-changed": return "Hedef değişti. Metin alanını seçip tekrar deneyin.";
    case "missing-target":
    case "unsupported-target": return "Önce bir uygulamada metin alanı seçin.";
    default: return "VoiceType hazır değil. Uygulamayı kontrol edin.";
  }
}
