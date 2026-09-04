#!/usr/bin/env python3
"""
text_injector.py
macOS Voice Typing - Metin Enjeksiyonu ve Pano Yöneticisi
Deşifre edilen metni o an odaklanılmış olan metin kutusuna (textbox / aktif uygulama)
panoyu (NSPasteboard) kullanarak ve Cmd+V simülasyonu yaparak sıfır gecikmeyle yapıştırır.
İsteğe bağlı olarak yapıştırma sonrası kullanıcının önceki panosunu geri yükler.
"""

import time
import threading
import subprocess
from typing import Optional

try:
    import Quartz
    from AppKit import NSPasteboard, NSPasteboardTypeString
    HAS_NATIVE = True
except ImportError:
    HAS_NATIVE = False


class TextInjector:
    """Aktif imlecin bulunduğu alana metin yapıştırma yöneticisi."""

    def __init__(self, restore_clipboard: bool = False, paste_delay_ms: int = 20):
        self.restore_clipboard = restore_clipboard
        self.paste_delay_ms = paste_delay_ms
        self._restore_timer: Optional[threading.Timer] = None

    def get_clipboard(self) -> str:
        """Mevcut panodaki metni okur."""
        if HAS_NATIVE:
            try:
                pb = NSPasteboard.generalPasteboard()
                return pb.stringForType_(NSPasteboardTypeString) or ""
            except Exception:
                pass
        try:
            res = subprocess.run(["pbpaste"], capture_output=True, text=True, timeout=1)
            return res.stdout
        except Exception:
            return ""

    def set_clipboard(self, text: str):
        """Panoya yeni metin yazar."""
        if HAS_NATIVE:
            try:
                pb = NSPasteboard.generalPasteboard()
                pb.clearContents()
                pb.setString_forType_(text, NSPasteboardTypeString)
                return
            except Exception:
                pass
        try:
            p = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE, text=True)
            p.communicate(input=text)
        except Exception:
            pass

    def simulate_cmd_v(self):
        """macOS üzerinde Cmd+V kısayolunu simüle eder."""
        if HAS_NATIVE:
            try:
                # Keycode 9: 'v' harfi
                event_down = Quartz.CGEventCreateKeyboardEvent(None, 9, True)
                Quartz.CGEventSetFlags(event_down, Quartz.kCGEventFlagMaskCommand)
                Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_down)
                Quartz.CGEventPost(Quartz.kCGSessionEventTap, event_down)

                time.sleep(0.015)

                event_up = Quartz.CGEventCreateKeyboardEvent(None, 9, False)
                Quartz.CGEventSetFlags(event_up, 0)
                Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_up)
                Quartz.CGEventPost(Quartz.kCGSessionEventTap, event_up)
                return
            except Exception as e:
                print(f"[Uyarı] Native Cmd+V başarısız, AppleScript deneniyor: {e}")

        # Yedek mekanizma: AppleScript
        try:
            script = 'tell application "System Events" to keystroke "v" using command down'
            subprocess.run(["osascript", "-e", script], check=True, timeout=2)
        except Exception as e:
            print(f"[Hata] Cmd+V gönderilemedi: {e}")

    def paste(self, text: str, restore_clipboard: Optional[bool] = None) -> bool:
        """
        Metni panoya yazar, aktif metin alanına Cmd+V ile yapıştırır.
        restore_clipboard True ise, önceki panoyu arka planda geri yükler.
        """
        if not text:
            return False

        should_restore = self.restore_clipboard if restore_clipboard is None else restore_clipboard
        old_clipboard = ""

        if should_restore:
            old_clipboard = self.get_clipboard()

        # 1. Metni panoya kopyala
        self.set_clipboard(text)

        # 2. Tuş bırakılmalarının OS tarafından işlenmesi için kısa bekleme
        if self.paste_delay_ms > 0:
            time.sleep(self.paste_delay_ms / 1000.0)

        # 3. Cmd+V gönder
        self.simulate_cmd_v()

        # 4. İsteğe bağlı olarak önceki panoyu geri yükle (arka planda, hedef uygulamanın okuması için süre tanıyarak)
        if should_restore and old_clipboard:
            def _restore_delayed():
                time.sleep(0.3)  # Hedef uygulamanın panodan yapıştırmayı tamamlaması için güvenli süre
                self.set_clipboard(old_clipboard)

            threading.Thread(target=_restore_delayed, daemon=True).start()

        return True


# Kolay erişim için tekil örnek
injector = TextInjector()
