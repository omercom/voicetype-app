#!/usr/bin/env python3
"""
app.py
macOS Voice Typing - Menü Çubuğu (Menu Bar) Uygulaması
Sağ Command tuşuna basıldığında konuşmayı dinler, Groq Whisper (~0.3s) veya Google Gemini
ile yazıya döker ve o an bulunulan metin kutusuna (textbox) anında yapıştırır.
"""

import os
import sys
import time
import json
import threading
from typing import Optional

import rumps
from PyObjCTools import AppHelper

from config import (
    load_config,
    save_config,
    update_config_value,
    get_active_model,
    AVAILABLE_MODELS,
    CONFIG_FILE
)
from voice_engine import AudioRecorder, Transcriber
from text_injector import TextInjector
from key_listener import RightCommandListener
from sound_effects import SoundManager


class VoiceTypingApp(rumps.App):
    """macOS Menü Çubuğunda çalışan sesle yazma uygulaması."""

    def __init__(self):
        super().__init__("VoiceTyping", title="🎙️", quit_button=None)
        
        # 1. Yapılandırma ve Motorlar
        self.config = load_config()
        self.recorder = AudioRecorder(sample_rate=16000)
        self.transcriber = Transcriber(self.config)
        self.sound = SoundManager(enabled=self.config.get("play_sounds", True))
        self.injector = TextInjector(
            restore_clipboard=self.config.get("restore_clipboard", False),
            paste_delay_ms=self.config.get("paste_delay_ms", 100)
        )

        # Durum Değişkenleri
        self.is_recording = False
        self.is_transcribing = False
        self._cancel_requested = False
        self._action_lock = threading.Lock()

        # 2. Menü Öğelerini Oluştur
        self._build_menu()

        # 3. Global Tuş Dinleyiciyi Başlat (Sağ Command)
        self.listener = RightCommandListener(
            mode=self.config.get("trigger_mode", "hold"),
            min_record_duration=self.config.get("min_record_duration", 0.20),
            on_start=self._on_key_start,
            on_stop=self._on_key_stop,
            on_cancel=self._on_key_cancel,
            is_busy=lambda: self.is_transcribing,
        )
        self.listener.start()

    # -------------------------------------------------------------------------
    # Menü Çubuğu Yapılandırması
    # -------------------------------------------------------------------------
    def _build_menu(self):
        """Menü öğelerini ve alt menüleri oluşturur."""
        self.menu.clear()

        # Durum Başlığı
        self.status_item = rumps.MenuItem("Durum: Hazır (Sağ Cmd Tuşuna Basın)")
        self.status_item.set_callback(None)
        self.menu.add(self.status_item)
        self.menu.add(rumps.separator)

        # 1. Sağlayıcı Seçimi
        current_provider = self.config.get("provider", "groq").lower()
        self.provider_menu = rumps.MenuItem("Sağlayıcı (Provider)")
        
        self.item_groq = rumps.MenuItem(
            "Groq Whisper (~0.3s Hızlı)",
            callback=lambda sender: self._set_provider("groq")
        )
        self.item_groq.state = (current_provider == "groq")
        self.provider_menu.add(self.item_groq)

        self.item_gemini = rumps.MenuItem(
            "Google Gemini (Doğal Dil)",
            callback=lambda sender: self._set_provider("gemini")
        )
        self.item_gemini.state = (current_provider == "gemini")
        self.provider_menu.add(self.item_gemini)
        self.menu.add(self.provider_menu)

        # 2. Groq Modelleri
        current_groq_m = self.config.get("groq_model", "whisper-large-v3-turbo")
        self.groq_models_menu = rumps.MenuItem("Groq Modeli")
        self.groq_model_items = {}
        for m in AVAILABLE_MODELS.get("groq", []):
            item = rumps.MenuItem(
                f"{m['name']} [{m['price']}]",
                callback=lambda s, mid=m["id"]: self._set_groq_model(mid)
            )
            item.state = (m["id"] == current_groq_m)
            self.groq_model_items[m["id"]] = item
            self.groq_models_menu.add(item)
        self.menu.add(self.groq_models_menu)

        # 3. Gemini Modelleri
        current_gemini_m = self.config.get("gemini_model", "gemini-3.6-flash")
        self.gemini_models_menu = rumps.MenuItem("Gemini Modeli")
        self.gemini_model_items = {}
        for m in AVAILABLE_MODELS.get("gemini", []):
            item = rumps.MenuItem(
                f"{m['name']} [{m['price']}]",
                callback=lambda s, mid=m["id"]: self._set_gemini_model(mid)
            )
            item.state = (m["id"] == current_gemini_m)
            self.gemini_model_items[m["id"]] = item
            self.gemini_models_menu.add(item)
        self.menu.add(self.gemini_models_menu)

        # 4. Tetikleme Modu
        current_mode = self.config.get("trigger_mode", "smart").lower()
        self.mode_menu = rumps.MenuItem("Tetikleme Modu")
        self.mode_items = {}
        modes = [
            ("smart", "Akıllı (Basılı Tut veya Tıkla)"),
            ("hold", "Basılı Tut (Push-to-Talk)"),
            ("toggle", "Aç / Kapa (Toggle)")
        ]
        for mode_key, mode_title in modes:
            item = rumps.MenuItem(
                mode_title,
                callback=lambda s, mk=mode_key: self._set_trigger_mode(mk)
            )
            item.state = (mode_key == current_mode)
            self.mode_items[mode_key] = item
            self.mode_menu.add(item)
        self.menu.add(self.mode_menu)

        self.menu.add(rumps.separator)

        # 5. API Anahtarları
        self.menu.add(rumps.MenuItem("Groq API Key Ayarla...", callback=self._prompt_groq_key))
        self.menu.add(rumps.MenuItem("Gemini API Key Ayarla...", callback=self._prompt_gemini_key))

        self.menu.add(rumps.separator)

        # 6. Seçenekler
        self.item_sounds = rumps.MenuItem(
            "Ses Efektleri (Tink/Pop)",
            callback=self._toggle_sounds
        )
        self.item_sounds.state = self.config.get("play_sounds", True)
        self.menu.add(self.item_sounds)

        self.item_restore_clip = rumps.MenuItem(
            "Önceki Panoyu Geri Yükle",
            callback=self._toggle_restore_clipboard
        )
        self.item_restore_clip.state = self.config.get("restore_clipboard", False)
        self.menu.add(self.item_restore_clip)

        self.menu.add(rumps.separator)

        # 7. Manuel Test ve Bilgi
        self.manual_test_item = rumps.MenuItem("Manuel Test Kaydı Başlat", callback=self._toggle_manual_recording)
        self.menu.add(self.manual_test_item)
        self.menu.add(rumps.MenuItem("Ayar Dosyasını Aç (config.json)", callback=self._open_config_file))
        self.menu.add(rumps.MenuItem("Hakkında ve Fiyatlandırma", callback=self._show_about))

        self.menu.add(rumps.separator)
        self.menu.add(rumps.MenuItem("Çıkış (Quit)", callback=self._quit_app))

    # -------------------------------------------------------------------------
    # Ayar Değiştiriciler
    # -------------------------------------------------------------------------
    def _set_provider(self, provider: str):
        self.config = update_config_value("provider", provider)
        self.item_groq.state = (provider == "groq")
        self.item_gemini.state = (provider == "gemini")
        self.transcriber.update_config(self.config)
        self._update_status_line()

    def _set_groq_model(self, model_id: str):
        self.config = update_config_value("groq_model", model_id)
        for mid, item in self.groq_model_items.items():
            item.state = (mid == model_id)
        self.transcriber.update_config(self.config)
        self._update_status_line()

    def _set_gemini_model(self, model_id: str):
        self.config = update_config_value("gemini_model", model_id)
        for mid, item in self.gemini_model_items.items():
            item.state = (mid == model_id)
        self.transcriber.update_config(self.config)
        self._update_status_line()

    def _set_trigger_mode(self, mode: str):
        self.config = update_config_value("trigger_mode", mode)
        for mkey, item in self.mode_items.items():
            item.state = (mkey == mode)
        self.listener.set_mode(mode)

    def _notify(self, title: str, subtitle: str, message: str):
        """macOS sistem bildirimlerini Info.plist eksikliğinde osascript ile gösterir."""
        try:
            rumps.notification(title, subtitle, message)
        except Exception:
            try:
                import subprocess
                clean_msg = message.replace('"', '\\"')
                clean_title = title.replace('"', '\\"')
                clean_sub = subtitle.replace('"', '\\"')
                script = f'display notification "{clean_msg}" with title "{clean_title}" subtitle "{clean_sub}"'
                subprocess.run(["osascript", "-e", script], timeout=2)
            except Exception:
                pass

    def _prompt_groq_key(self, _):
        curr = self.config.get("groq_api_key", "")
        masked = curr[:8] + "..." + curr[-4:] if len(curr) > 12 else curr
        w = rumps.Window(
            title="Groq API Anahtarı",
            message=f"Mevcut: {masked if curr else 'Tanımlanmamış'}\nYeni Groq API anahtarınızı (gsk_...) girin:\n(Ücretsiz günlük 8 saat Whisper kotası vardır)",
            default_text=curr,
            ok="Kaydet",
            cancel="İptal",
            dimensions=(360, 24)
        )
        res = w.run()
        if res.clicked:
            key = (res.text or "").strip()
            self.config = update_config_value("groq_api_key", key)
            self.transcriber.update_config(self.config)
            self._notify("Groq API", "Ayarlar Güncellendi", "Groq API anahtarınız başarıyla kaydedildi.")

    def _prompt_gemini_key(self, _):
        curr = self.config.get("gemini_api_key", "")
        masked = curr[:8] + "..." + curr[-4:] if len(curr) > 12 else curr
        w = rumps.Window(
            title="Google Gemini API Anahtarı",
            message=f"Mevcut: {masked if curr else 'Tanımlanmamış'}\nYeni Gemini API anahtarınızı (AIza...) girin:",
            default_text=curr,
            ok="Kaydet",
            cancel="İptal",
            dimensions=(360, 24)
        )
        res = w.run()
        if res.clicked:
            key = (res.text or "").strip()
            self.config = update_config_value("gemini_api_key", key)
            self.transcriber.update_config(self.config)
            self._notify("Gemini API", "Ayarlar Güncellendi", "Gemini API anahtarınız başarıyla kaydedildi.")

    def _toggle_sounds(self, _):
        curr = self.config.get("play_sounds", True)
        new_val = not curr
        self.config = update_config_value("play_sounds", new_val)
        self.item_sounds.state = new_val
        self.sound.enabled = new_val

    def _toggle_restore_clipboard(self, _):
        curr = self.config.get("restore_clipboard", False)
        new_val = not curr
        self.config = update_config_value("restore_clipboard", new_val)
        self.item_restore_clip.state = new_val
        self.injector.restore_clipboard = new_val

    def _open_config_file(self, _):
        if CONFIG_FILE.exists():
            os.system(f"open '{CONFIG_FILE}'")
        else:
            save_config(self.config)
            os.system(f"open '{CONFIG_FILE}'")

    def _show_about(self, _):
        msg = (
            "macOS Voice Typing v1.0\n"
            "------------------------------------\n"
            "Kullanım:\n"
            "• Sağ Command tuşuna basılı tutun ve konuşun.\n"
            "• Tuşu bıraktığınız anda konuşmanız deşifre edilip o anki aktif metin alanına (textbox) anında yazılır.\n"
            "• Konuşmaktan vazgeçerseniz Esc tuşuna basarak kaydı iptal edebilirsiniz.\n\n"
            "Fiyatlandırma & Modeller (Best Prices):\n"
            "• Groq Whisper Turbo: ~0.3s hız, 0.00018 USD/dakika (Günlük 8 saat ücretsiz kota)\n"
            "• Groq Whisper Large: En yüksek Türkçe doğruluk, 0.00018 USD/dakika\n"
            "• Google Gemini 3.6 Flash: Doğal dil & bağlam düzeltmeli, ücretsiz / düşük maliyet\n"
        )
        rumps.alert(title="Hakkında & Kullanım", message=msg)

    # -------------------------------------------------------------------------
    # Ses Kaydı ve Deşifre İşlem Hattı (Pipeline)
    # -------------------------------------------------------------------------
    def _update_status_line(self, text: Optional[str] = None):
        if text:
            self.status_item.title = text
        else:
            p = self.config.get("provider", "groq").upper()
            m = get_active_model(self.config)
            self.status_item.title = f"Durum: Hazır ({p} - {m})"

    def _on_key_start(self):
        with self._action_lock:
            if self.is_transcribing:
                return
            self.is_recording = True
            self._cancel_requested = False

        AppHelper.callAfter(self._ui_record_started)
        self.sound.play_start()
        self.recorder.start()

    def _on_key_stop(self, duration: float):
        with self._action_lock:
            if not self.is_recording:
                return
            self.is_recording = False
            self.is_transcribing = True

        audio_buffer, rec_duration = self.recorder.stop()
        AppHelper.callAfter(self._ui_transcribe_started)
        self.sound.play_stop()

        threading.Thread(target=self._process_transcription, args=(audio_buffer, rec_duration), daemon=True).start()

    def _on_key_cancel(self, reason: str = ""):
        with self._action_lock:
            self._cancel_requested = True
            was_recording = self.is_recording
            self.is_recording = False
            self.is_transcribing = False

        if was_recording:
            self.recorder.stop()

        self.sound.play_cancel()
        AppHelper.callAfter(self._ui_reset_ready)
        print(f"[İptal] {reason}")

    def _toggle_manual_recording(self, _):
        if not self.is_recording:
            self.manual_test_item.title = "⏹️ Kaydı Bitir ve Yapıştır"
            self._on_key_start()
        else:
            self.manual_test_item.title = "Manuel Test Kaydı Başlat"
            self._on_key_stop(1.0)

    # -------------------------------------------------------------------------
    # UI Durum Güncellemeleri (Cocoa Main Loop)
    # -------------------------------------------------------------------------
    def _ui_record_started(self):
        self.title = "🔴"
        self._update_status_line("🔴 Dinleniyor... (Konuşun)")

    def _ui_transcribe_started(self):
        self.title = "⚡"
        p = self.config.get("provider", "groq").upper()
        self._update_status_line(f"⚡ Deşifre Ediliyor ({p})...")

    def _ui_reset_ready(self):
        self.title = "🎙️"
        self.manual_test_item.title = "Manuel Test Kaydı Başlat"
        self._update_status_line()

    # -------------------------------------------------------------------------
    # Arka Plan Deşifre ve Metin Yapıştırma İşlemi
    # -------------------------------------------------------------------------
    def _process_transcription(self, audio_buffer, duration: float):
        try:
            if self._cancel_requested or not audio_buffer:
                if not self._cancel_requested:
                    # Boş veya sessiz ses
                    print("[Bilgi] Ses algılanamadı (sessiz veya mikrofon kapalı).")
                self.sound.play_cancel()
                return

            provider = self.config.get("provider", "groq")
            model = get_active_model(self.config)

            # Deşifre motorunu çağır
            res = self.transcriber.transcribe(audio_buffer, provider=provider, model=model)

            if self._cancel_requested:
                print("[İptal] Deşifre tamamlandı ancak kullanıcı iptal etti.")
                self.sound.play_cancel()
                return

            if res.get("success"):
                text = (res.get("text") or "").strip()
                latency = res.get("latency", 0.0)

                if text:
                    # Metni aktif textbox'a yapıştır
                    self.injector.paste(text)
                    self.sound.play_success()
                    print(f"[Başarılı] ({latency}s) \"{text}\"")
                else:
                    self.sound.play_cancel()
                    print("[Bilgi] Boş metin döndü (ses anlaşılamadı).")
            else:
                err = res.get("error") or "Bilinmeyen deşifre hatası"
                print(f"[Hata] {err}")
                self.sound.play_cancel()
                self._notify(
                    "Ses Deşifre Hatası",
                    f"{provider.capitalize()} Başarısız",
                    str(err)[:120]
                )
        except Exception as ex:
            print(f"[Kritik Hata] {ex}")
            self.sound.play_cancel()
        finally:
            with self._action_lock:
                self.is_transcribing = False
            AppHelper.callAfter(self._ui_reset_ready)

    def _quit_app(self, _):
        if self.listener:
            self.listener.stop()
        if self.recorder:
            self.recorder.stop()
        rumps.quit_application()


def main():
    print("=" * 60)
    print("macOS Voice Typing Menü Çubuğu Uygulaması Başlatılıyor...")
    print("Sağ Command (Right Command) tuşuna basılı tutarak konuşabilirsiniz.")
    print("=" * 60)
    app = VoiceTypingApp()
    app.run()


if __name__ == "__main__":
    main()
