#!/usr/bin/env python3
"""
key_listener.py
macOS Voice Typing - Global Sağ Command (Right Command) Tuş Dinleyicisi
macOS kCGEventFlagsChanged / KeyCode 54 (0x36) olaylarını yakalar.
Push-to-Talk (basılı tut-konuş), Toggle (aç-kapa) ve Smart (akıllı hibrit) modlarını destekler.
İptal etmek için Esc tuşunu dinler.
"""

import time
import queue
import threading
from typing import Callable, Optional
from pynput import keyboard


class RightCommandListener:
    """
    macOS Sağ Command (keycode 54) tuşu için optimize edilmiş,
    iş parçacığı güvenli (thread-safe, serial event queue) global dinleyici.
    """

    HOLD_THRESHOLD_SEC = 0.25  # Basılı tutma ile tıklamayı ayıran eşik (saniye)

    def __init__(
        self,
        mode: str = "hold",  # "hold" (varsayılan: basılı tut-konuş), "smart", "toggle"
        min_record_duration: float = 0.20,
        on_start: Optional[Callable[[], None]] = None,
        on_stop: Optional[Callable[[float], None]] = None,
        on_cancel: Optional[Callable[[str], None]] = None,
        is_busy: Optional[Callable[[], bool]] = None,
    ):
        self.mode = mode.lower()
        self.min_record_duration = min_record_duration
        self.on_start = on_start
        self.on_stop = on_stop
        self.on_cancel = on_cancel
        self.is_busy = is_busy or (lambda: False)

        self._listener: Optional[keyboard.Listener] = None
        self._lock = threading.Lock()
        self._key_down = False
        self._is_recording = False
        self._press_time = 0.0
        self._recording_start_time = 0.0
        self._in_toggle_mode = False

        # Sıralı işlem kuyruğu (start ve stop olaylarının sırayla çalışmasını garanti eder)
        self._event_queue: queue.Queue = queue.Queue()
        self._worker_running = True
        self._worker_thread = threading.Thread(target=self._worker_loop, daemon=True)
        self._worker_thread.start()

    def _worker_loop(self):
        """Olayları sırayla yürüten arka plan işçi döngüsü."""
        while self._worker_running:
            try:
                item = self._event_queue.get(timeout=0.2)
            except queue.Empty:
                continue

            if item is None:
                break

            action, arg = item
            try:
                if action == "start" and self.on_start:
                    self.on_start()
                elif action == "stop" and self.on_stop:
                    self.on_stop(arg)
                elif action == "cancel" and self.on_cancel:
                    self.on_cancel(arg)
            except Exception as e:
                print(f"[KeyListener İşçi Hatası] {e}")
            finally:
                self._event_queue.task_done()

    def is_right_command(self, key) -> bool:
        """Tuşun Sağ Command (keycode 54 / cmd_r) olup olmadığını doğrular."""
        if key == keyboard.Key.cmd_r:
            return True
        if hasattr(key, "vk") and key.vk == 54:
            return True
        if hasattr(key, "value") and hasattr(key.value, "vk") and key.value.vk == 54:
            return True
        return False

    def set_mode(self, new_mode: str):
        """Çalışma modunu dinamik olarak değiştirir ('hold', 'smart', 'toggle')."""
        with self._lock:
            self.mode = new_mode.lower()
            self._in_toggle_mode = False

    def _handle_press(self, key):
        # 1. Esc tuşu ile iptal kontrolü (Kayıtta veya deşifre aşamasındayken)
        if key == keyboard.Key.esc:
            with self._lock:
                was_recording = self._is_recording
                self._is_recording = False
                self._in_toggle_mode = False
                self._key_down = False

            # Kayıttaysa veya deşifre sürüyorsa iptal olayını ilet
            if was_recording or self.is_busy():
                self._event_queue.put(("cancel", "Kullanıcı Esc tuşuna bastı"))
            return

        # 2. Sağ Command kontrolü
        if not self.is_right_command(key):
            return

        with self._lock:
            if self._key_down:
                return  # Zaten basılı durumdaysa tekrar tetikleme
            self._key_down = True
            now = time.time()
            self._press_time = now

            if self.mode == "toggle":
                if not self._is_recording:
                    self._is_recording = True
                    self._recording_start_time = now
                    self._event_queue.put(("start", None))
                else:
                    duration = now - self._recording_start_time
                    self._is_recording = False
                    self._event_queue.put(("stop", duration))

            elif self.mode == "hold":
                if not self._is_recording:
                    self._is_recording = True
                    self._recording_start_time = now
                    self._event_queue.put(("start", None))

            elif self.mode == "smart":
                if not self._is_recording:
                    self._is_recording = True
                    self._recording_start_time = now
                    self._in_toggle_mode = False
                    self._event_queue.put(("start", None))
                else:
                    if self._in_toggle_mode:
                        duration = now - self._recording_start_time
                        self._is_recording = False
                        self._in_toggle_mode = False
                        self._event_queue.put(("stop", duration))

    def _handle_release(self, key):
        if not self.is_right_command(key):
            return

        with self._lock:
            if not self._key_down:
                return
            self._key_down = False
            now = time.time()
            hold_time = now - self._press_time
            total_duration = now - self._recording_start_time

            if self.mode == "hold":
                if self._is_recording:
                    self._is_recording = False
                    if total_duration < self.min_record_duration:
                        self._event_queue.put(("cancel", "Kayıt çok kısa"))
                    else:
                        self._event_queue.put(("stop", total_duration))

            elif self.mode == "smart":
                if self._is_recording and not self._in_toggle_mode:
                    if hold_time >= self.HOLD_THRESHOLD_SEC:
                        self._is_recording = False
                        if total_duration < self.min_record_duration:
                            self._event_queue.put(("cancel", "Kayıt çok kısa"))
                        else:
                            self._event_queue.put(("stop", total_duration))
                    else:
                        # Kısa bas-bırak -> Aç/Kapa moduna geç, kayda devam et
                        self._in_toggle_mode = True

    def start(self):
        """Dinleyiciyi arka planda başlatır."""
        if self._listener is None:
            self._listener = keyboard.Listener(
                on_press=self._handle_press,
                on_release=self._handle_release
            )
            self._listener.daemon = True
            self._listener.start()

    def stop(self):
        """Dinleyiciyi ve işçi döngüsünü durdurur."""
        if self._listener is not None:
            try:
                self._listener.stop()
            except Exception:
                pass
            self._listener = None

        self._worker_running = False
        self._event_queue.put(None)
