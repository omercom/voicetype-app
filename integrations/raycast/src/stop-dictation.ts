import { closeMainWindow, showHUD } from "@raycast/api";
import { sendVoiceTypeCommand, statusMessage } from "./automation";

export default async function Command() {
  try {
    await closeMainWindow();
    await showHUD(statusMessage(await sendVoiceTypeCommand("stop")));
  } catch {
    await showHUD("VoiceType'ı ve macOS Otomasyon iznini kontrol edin.");
  }
}
