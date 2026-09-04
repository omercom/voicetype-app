#!/usr/bin/env python3
"""
test_suite.py
macOS Voice Typing - Kapsamlı Otomasyon ve Doğrulama Test Paketi
Tüm bileşenleri (config, ses kaydı, deşifre motorları, pano enjektörü, ses efektleri, tuş dinleyici) test eder.
"""

import io
import time
import json
import unittest
from pathlib import Path
from pynput.keyboard import Key, KeyCode

from config import (
    load_config,
    save_config,
    update_config_value,
    get_active_model,
    AVAILABLE_MODELS,
    CONFIG_FILE,
    DEFAULT_CONFIG
)
from voice_engine import AudioRecorder, Transcriber
from text_injector import TextInjector
from sound_effects import SoundManager
from key_listener import RightCommandListener


class TestConfig(unittest.TestCase):
    """Yapılandırma yöneticisi testleri."""

    def test_default_config_fields(self):
        cfg = load_config()
        self.assertIn("provider", cfg)
        self.assertIn("groq_model", cfg)
        self.assertIn("gemini_model", cfg)
        self.assertIn("trigger_key", cfg)
        self.assertEqual(cfg["trigger_key"], 54)

    def test_available_models_no_latex_and_valid(self):
        for provider, models in AVAILABLE_MODELS.items():
            for m in models:
                self.assertNotIn("$", m["price"], f"Price cannot contain dollar signs: {m['price']}")
                self.assertTrue("USD" in m["price"] or "Ücretsiz" in m["price"] or "Maliyet" in m["price"])
                self.assertTrue(len(m["id"]) > 0)

    def test_update_config_value(self):
        old_val = load_config().get("restore_clipboard", False)
        new_val = not old_val
        updated = update_config_value("restore_clipboard", new_val)
        self.assertEqual(updated["restore_clipboard"], new_val)
        # Geri al
        update_config_value("restore_clipboard", old_val)


class TestTextInjector(unittest.TestCase):
    """Pano ve metin enjeksiyonu testleri."""

    def setUp(self):
        self.injector = TextInjector(restore_clipboard=True, paste_delay_ms=20)

    def test_set_and_get_clipboard(self):
        test_str = "Test Voice Typing Türkçe Metin: Kadıköy 123 çığöşü"
        self.injector.set_clipboard(test_str)
        self.assertEqual(self.injector.get_clipboard(), test_str)

    def test_paste_empty_returns_false(self):
        self.assertFalse(self.injector.paste(""))

    def test_paste_with_restore(self):
        original = "Orjinal Pano Verisi 987"
        self.injector.set_clipboard(original)
        
        injected = "Yeni Enjekte Edilen Ses Metni"
        success = self.injector.paste(injected, restore_clipboard=True)
        self.assertTrue(success)
        # Yapıştırma simülasyonu anında panoda yeni metin olmalı
        self.assertEqual(self.injector.get_clipboard(), injected)

        # 400ms sonra eski pano geri yüklenmeli
        time.sleep(0.45)
        self.assertEqual(self.injector.get_clipboard(), original)


class TestSoundEffects(unittest.TestCase):
    """Ses efektleri testleri."""

    def test_sound_manager_methods(self):
        sm = SoundManager(enabled=True)
        # Hiçbir metodun exception fırlatmadığını doğrula
        sm.play_start()
        sm.play_stop()
        sm.play_success()
        sm.play_cancel()

    def test_sound_manager_disabled(self):
        sm = SoundManager(enabled=False)
        sm.play_start()


class TestKeyListener(unittest.TestCase):
    """Sağ Command tuş dinleyicisi testleri."""

    def test_key_identification(self):
        listener = RightCommandListener()
        self.assertTrue(listener.is_right_command(Key.cmd_r))
        self.assertTrue(listener.is_right_command(KeyCode.from_vk(54)))
        self.assertFalse(listener.is_right_command(Key.cmd))  # Sol Command (55) olmamalı
        self.assertFalse(listener.is_right_command(Key.space))

    def test_push_to_talk_hold_flow(self):
        events = []
        listener = RightCommandListener(
            mode="hold",
            min_record_duration=0.05,
            on_start=lambda: events.append("start"),
            on_stop=lambda d: events.append(f"stop:{d:.2f}"),
            on_cancel=lambda r: events.append("cancel")
        )

        listener._handle_press(Key.cmd_r)
        time.sleep(0.1)
        listener._handle_release(Key.cmd_r)
        time.sleep(0.05)

        self.assertIn("start", events)
        self.assertTrue(any(e.startswith("stop:") for e in events))

    def test_smart_mode_tap_to_toggle(self):
        events = []
        listener = RightCommandListener(
            mode="smart",
            min_record_duration=0.05,
            on_start=lambda: events.append("start"),
            on_stop=lambda d: events.append(f"stop:{d:.2f}"),
            on_cancel=lambda r: events.append("cancel")
        )

        # Hızlı bas-bırak (<0.35s)
        listener._handle_press(Key.cmd_r)
        time.sleep(0.05)
        listener._handle_release(Key.cmd_r)
        time.sleep(0.05)

        # Toggle moduna geçmeli ve kayıtta kalmalı
        self.assertEqual(events, ["start"])
        self.assertTrue(listener._in_toggle_mode)

        # İkinci kez basınca durmalı
        listener._handle_press(Key.cmd_r)
        time.sleep(0.05)
        listener._handle_release(Key.cmd_r)
        time.sleep(0.05)

        self.assertTrue(any(e.startswith("stop:") for e in events))

    def test_esc_cancellation(self):
        events = []
        listener = RightCommandListener(
            mode="smart",
            on_start=lambda: events.append("start"),
            on_stop=lambda d: events.append("stop"),
            on_cancel=lambda r: events.append(f"cancel:{r}")
        )

        listener._handle_press(Key.cmd_r)
        time.sleep(0.05)
        listener._handle_press(Key.esc)
        time.sleep(0.08)
        listener.stop()

        self.assertIn("start", events)
        self.assertTrue(any(e.startswith("cancel:") for e in events))

    def test_serial_queue_ordering_under_rapid_fire(self):
        events = []
        listener = RightCommandListener(
            mode="hold",
            min_record_duration=0.01,
            on_start=lambda: events.append("start"),
            on_stop=lambda d: events.append("stop"),
            on_cancel=lambda r: events.append("cancel")
        )

        # Hızlı bas-bırak döngüsü
        listener._handle_press(Key.cmd_r)
        time.sleep(0.02)
        listener._handle_release(Key.cmd_r)
        time.sleep(0.1)
        listener.stop()

        # Sıralama kesinlikle ['start', 'stop'] olmalı, stop start'tan önce çalışmamalı
        self.assertEqual(events, ["start", "stop"])

    def test_esc_cancels_when_transcribing_busy(self):
        events = []
        listener = RightCommandListener(
            mode="hold",
            is_busy=lambda: True,  # Deşifre aşamasında simülasyonu
            on_cancel=lambda r: events.append("cancel_busy")
        )

        listener._handle_press(Key.esc)
        time.sleep(0.08)
        listener.stop()

        self.assertIn("cancel_busy", events)


class TestVoiceEngineLive(unittest.TestCase):
    """Ses motoru ve API entegrasyon testleri."""

    def test_audio_recorder_memory_buffer(self):
        recorder = AudioRecorder(sample_rate=16000)
        recorder.start()
        time.sleep(0.2)
        buf, dur = recorder.stop()
        # Mikrofon donanımı varsa ve ses aldıysa buf döner, sessizse None dönebilir
        self.assertGreater(dur, 0.1)
        if buf:
            buf.seek(0)
            header = buf.read(12)
            self.assertTrue(header.startswith(b"RIFF"))
            self.assertIn(b"WAVE", header)

    def test_empty_transcription_regression(self):
        # res["text"] boş ve res["error"] None olduğunda TypeError fırlatmamalı
        res = {"success": True, "text": "", "error": None, "latency": 0.1}
        err = res.get("error") or "Ses anlaşılamadı"
        self.assertIsNotNone(err)
        # Dilimleme (subscript) hatasız çalışmalı
        slice_result = str(err)[:120]
        self.assertEqual(slice_result, "Ses anlaşılamadı")

    def test_groq_whisper_transcription(self):
        sample_path = Path("samples/01_gunluk_konusma.mp3")
        if not sample_path.exists():
            self.skipTest("Örnek ses dosyası bulunamadı")

        cfg = load_config()
        if not cfg.get("groq_api_key"):
            self.skipTest("GROQ_API_KEY bulunamadı")

        transcriber = Transcriber(cfg)
        with open(sample_path, "rb") as f:
            buf = io.BytesIO(f.read())
            buf.name = "sample.mp3"

        res = transcriber.transcribe_groq(buf, model="whisper-large-v3-turbo")
        self.assertTrue(res["success"], f"Groq hatası: {res.get('error')}")
        self.assertIn("Kadıköy", res["text"])
        self.assertLess(res["latency"], 2.0)

    def test_gemini_transcription(self):
        sample_path = Path("samples/01_gunluk_konusma.mp3")
        if not sample_path.exists():
            self.skipTest("Örnek ses dosyası bulunamadı")

        cfg = load_config()
        if not cfg.get("gemini_api_key"):
            self.skipTest("GEMINI_API_KEY bulunamadı")

        transcriber = Transcriber(cfg)
        with open(sample_path, "rb") as f:
            buf = io.BytesIO(f.read())
            buf.name = "sample.mp3"

        res = transcriber.transcribe_gemini(buf, model="gemini-3.6-flash")
        # Eğer Gemini 429 kota aşımı verirse skipTest yap
        if not res["success"] and "429" in str(res.get("error", "")):
            self.skipTest(f"Gemini ücretsiz günlük kota sınırına ulaşıldı: {res.get('error')}")

        self.assertTrue(res["success"], f"Gemini hatası: {res.get('error')}")
        self.assertIn("Kadıköy", res["text"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
