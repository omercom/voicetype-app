import { closeMainWindow, showHUD } from "@raycast/api";
import { sendVoiceTypeCommand, statusMessage } from "./automation";

export default async function Command() {
  try {
    await closeMainWindow();
    const status = await sendVoiceTypeCommand("settings");
    if (status !== "opened") await showHUD(statusMessage(status));
  } catch {
    await showHUD("VoiceType'ı ve macOS Otomasyon iznini kontrol edin.");
  }
}
