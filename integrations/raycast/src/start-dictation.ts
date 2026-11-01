import { closeMainWindow, getFrontmostApplication, showHUD } from "@raycast/api";
import { requestDictation, sendVoiceTypeCommand, statusMessage } from "./automation";

export default async function Command() {
  try {
    const status = await requestDictation(
      () => closeMainWindow(),
      async () => (await getFrontmostApplication()).bundleId,
      (target) => sendVoiceTypeCommand("start", target),
    );
    await showHUD(statusMessage(status));
  } catch {
    await showHUD("VoiceType'ı ve macOS Otomasyon iznini kontrol edin.");
  }
}
