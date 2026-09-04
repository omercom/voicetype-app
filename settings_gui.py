#!/usr/bin/env python3
"""
settings_gui.py
macOS Voice Typing - Kapsamlı Ayarlar ve İzin Yönetimi Diyaloğu
macOS mikrofon ve erişilebilirlik izin yönetimi, canlı mikrofon VU-meter testi,
Groq ve Gemini model seçimi, API anahtar doğrulama ve genel tercihleri yönetir.
"""

import os
import sys
import time
import json
import webbrowser
import threading
import subprocess
from pathlib import Path
from typing import Dict, Any, Tuple, Optional

import tkinter as tk
from tkinter import ttk, messagebox
import numpy as np
import sounddevice as sd

from config import (
    load_config,
    save_config,
    update_config_value,
    AVAILABLE_MODELS,
    CONFIG_FILE,
    DEFAULT_CONFIG
)


# =============================================================================
# macOS İzin ve Sistem Yardımcıları (Permission Manager)
# =============================================================================

class PermissionManager:
    """macOS AVFoundation ve ApplicationServices izin yönetim servisi."""

    @staticmethod
    def get_microphone_status() -> Tuple[str, str, str]:
        """
        macOS AVFoundation üzerinden mikrofon izin durumunu sorgular.
        Döner: (status_code, status_text, badge_icon)
        status_code: 'authorized', 'denied', 'restricted', 'not_determined', 'unknown'
        """
        try:
            import objc
            objc.loadBundle(
                'AVFoundation',
                globals(),
                bundle_path='/System/Library/Frameworks/AVFoundation.framework'
            )
            AVCaptureDevice = objc.lookUpClass('AVCaptureDevice')
            # 'soun' = AVMediaTypeAudio
            status = AVCaptureDevice.authorizationStatusForMediaType_('soun')
            mapping = {
                0: ('not_determined', 'Henüz İstenmedi (Not Determined)', '🟡'),
                1: ('restricted', 'Kısıtlı (MDM / Ebeveyn Denetimi)', '🟠'),
                2: ('denied', 'Erişim Reddedildi (Denied)', '🔴'),
                3: ('authorized', 'Yetki Verildi (Authorized - Tam Erişim)', '🟢')
            }
            return mapping.get(status, ('unknown', f'Bilinmeyen Durum ({status})', '⚪'))
        except Exception as e:
            return ('unknown', f'Sorgulanamadı: {e}', '⚪')

    @staticmethod
    def get_accessibility_status() -> Tuple[str, str, str]:
        """
        macOS ApplicationServices üzerinden Erişilebilirlik (Accessibility) iznini sorgular.
        Sağ Command dinleme ve Cmd+V metin yapıştırma için gereklidir.
        """
        try:
            from ApplicationServices import AXIsProcessTrusted
            trusted = AXIsProcessTrusted()
            if trusted:
                return ('authorized', 'Yetki Verildi (Kısayol ve Metin Yapıştırma Aktif)', '🟢')
            else:
                return ('denied', 'Yetki Verilmedi (Erişilebilirlik İzni Bekleniyor)', '🔴')
        except Exception as e:
            return ('unknown', f'Sorgulanamadı: {e}', '⚪')

    @staticmethod
    def request_microphone_access():
        """macOS mikrofon izni penceresini tetikler."""
        try:
            import objc
            objc.loadBundle(
                'AVFoundation',
                globals(),
                bundle_path='/System/Library/Frameworks/AVFoundation.framework'
            )
            AVCaptureDevice = objc.lookUpClass('AVCaptureDevice')
            AVCaptureDevice.requestAccessForMediaType_completionHandler_('soun', lambda granted: None)
        except Exception:
            pass

        # Yedek: sounddevice ile anlık stream açarak TCC iznini uyar
        try:
            def _dummy(i, f, t, s):
                pass
            with sd.InputStream(samplerate=16000, channels=1, dtype='int16', callback=_dummy):
                time.sleep(0.1)
        except Exception:
            pass

    @staticmethod
    def request_accessibility_access():
        """macOS Erişilebilirlik sistem uyarı penceresini tetikler."""
        try:
            from ApplicationServices import AXIsProcessTrustedWithOptions
            AXIsProcessTrustedWithOptions({'AXTrustedCheckOptionPrompt': True})
        except Exception:
            pass

    @staticmethod
    def open_system_settings(pane: str):
        """macOS Sistem Ayarları'nda ilgili gizlilik sekmesini açar."""
        # pane: 'Microphone', 'Accessibility', 'ListenEvent', 'sound'
        if pane.lower() == "sound":
            url = "x-apple.systempreferences:com.apple.preference.sound"
        else:
            url = f"x-apple.systempreferences:com.apple.preference.security?Privacy_{pane}"
        try:
            subprocess.run(["open", url], check=False)
        except Exception:
            pass

    @staticmethod
    def get_default_microphone_info() -> str:
        """Sistemde aktif olan varsayılan ses giriş aygıtını döner."""
        try:
            default_dev_idx = sd.default.device[0]
            if default_dev_idx >= 0:
                dev = sd.query_devices(default_dev_idx)
                name = dev.get("name", "Bilinmeyen Aygıt")
                rate = int(dev.get("default_samplerate", 16000))
                return f"{name} ({rate} Hz)"
        except Exception:
            pass
        return "Sistem Varsayılan Mikrofonu"


# =============================================================================
# API Doğrulama ve Bağlantı Testi (API Validator)
# =============================================================================

class ApiValidator:
    """Groq ve Google Gemini API anahtarlarının geçerliliğini ve gecikmesini test eder."""

    @staticmethod
    def test_groq_key(api_key: str) -> Tuple[bool, str, float]:
        """Groq API anahtarını modeller listesi sorgusu ile test eder."""
        key = (api_key or "").strip()
        if not key:
            return False, "API anahtarı boş bırakılamaz.", 0.0

        t0 = time.perf_counter()
        try:
            from groq import Groq
            client = Groq(api_key=key)
            models = client.models.list()
            latency = time.perf_counter() - t0
            model_count = len(getattr(models, "data", []))
            return True, f"Geçerli - Bağlantı Başarılı ({model_count} model aktif)", round(latency, 3)
        except Exception as e:
            latency = time.perf_counter() - t0
            err_msg = str(e)
            if "401" in err_msg or "invalid_api_key" in err_msg:
                err_msg = "Geçersiz API Anahtarı (401 Yetkilendirme Hatası)"
            elif "timeout" in err_msg.lower():
                err_msg = "Zaman aşımı - İnternet bağlantınızı kontrol edin."
            return False, f"Hata: {err_msg}", round(latency, 3)

    @staticmethod
    def test_gemini_key(api_key: str) -> Tuple[bool, str, float]:
        """Google Gemini API anahtarını modeller listesi sorgusu ile test eder."""
        key = (api_key or "").strip()
        if not key:
            return False, "API anahtarı boş bırakılamaz.", 0.0

        t0 = time.perf_counter()
        try:
            import requests
            url = f"https://generativelanguage.googleapis.com/v1beta/models?key={key}"
            resp = requests.get(url, timeout=7)
            latency = time.perf_counter() - t0
            if resp.status_code == 200:
                models = resp.json().get("models", [])
                return True, f"Geçerli - Bağlantı Başarılı ({len(models)} model aktif)", round(latency, 3)
            else:
                try:
                    err_msg = resp.json().get("error", {}).get("message", resp.text)
                except Exception:
                    err_msg = resp.text[:100]
                return False, f"Hata ({resp.status_code}): {err_msg}", round(latency, 3)
        except Exception as e:
            latency = time.perf_counter() - t0
            return False, f"Bağlantı hatası: {e}", round(latency, 3)


# =============================================================================
# Ana Ayarlar Grafik Arayüzü (Settings Window)
# =============================================================================

class SettingsDialog(tk.Tk):
    """macOS Voice Typing - Modern Native Ayarlar Penceresi."""

    def __init__(self):
        super().__init__()

        self.title("macOS Voice Typing - Ayarlar & İlk Kurulum")
        self.geometry("720x690")
        self.minsize(660, 620)

        # macOS pencere odağı ve merkezleme
        self._center_window()
        self._bring_to_front()

        # Mevcut ayarları yükle
        self.current_config = load_config()

        # Test durumu değişkenleri
        self._mic_test_running = False
        self._mic_test_stop = threading.Event()

        # Tkinter UI Stili
        self._setup_styles()

        # Arayüz Bileşenlerini İnşa Et
        self._build_ui()

        # İlk İzin Durumunu Yükle
        self.refresh_permissions_status()

        # Kısayol Tuşları (Cmd+W, Cmd+S, Esc)
        self.bind("<Command-w>", lambda e: self.destroy())
        self.bind("<Command-s>", lambda e: self.save_settings())
        self.bind("<Escape>", lambda e: self.destroy())

    def _center_window(self):
        """Pencereyi ekranın ortasına konumlandırır."""
        self.update_idletasks()
        width = 720
        height = 690
        x = (self.winfo_screenwidth() // 2) - (width // 2)
        y = (self.winfo_screenheight() // 2) - (height // 2) - 40
        self.geometry(f"{width}x{height}+{x}+{y}")

    def _bring_to_front(self):
        """macOS üzerinde pencereyi ön plana taşır."""
        self.lift()
        self.attributes("-topmost", True)
        self.after_idle(self.attributes, "-topmost", False)
        try:
            from AppKit import NSApplication
            NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        except Exception:
            pass

    def _setup_styles(self):
        """macOS Aqua temasına uygun renk ve yazı tiplerini yapılandırır."""
        self.style = ttk.Style(self)
        try:
            self.style.theme_use("aqua")
        except Exception:
            pass

        # Standart fontlar
        self.font_title = ("SF Pro Display", 16, "bold")
        self.font_section = ("SF Pro Text", 13, "bold")
        self.font_bold = ("SF Pro Text", 11, "bold")
        self.font_regular = ("SF Pro Text", 11)
        self.font_small = ("SF Pro Text", 10)
        self.font_code = ("Menlo", 10)

    # -------------------------------------------------------------------------
    # Arayüz Ağacı (UI Layout)
    # -------------------------------------------------------------------------
    def _build_ui(self):
        """Sekmeli ayarlar penceresini oluşturur."""
        main_frame = ttk.Frame(self, padding="16 16 16 12")
        main_frame.pack(fill=tk.BOTH, expand=True)

        # Üst Başlık
        header_frame = ttk.Frame(main_frame)
        header_frame.pack(fill=tk.X, pady=(0, 10))

        title_lbl = ttk.Label(
            header_frame,
            text="🎙️ macOS Voice Typing - Sistem Yapılandırması",
            font=self.font_title
        )
        title_lbl.pack(side=tk.LEFT)

        subtitle_lbl = ttk.Label(
            header_frame,
            text="v1.0 (Sağ Command Tuşu)",
            font=self.font_small,
            foreground="#666666"
        )
        subtitle_lbl.pack(side=tk.RIGHT, pady=(4, 0))

        # Sekmeler (Notebook)
        self.notebook = ttk.Notebook(main_frame)
        self.notebook.pack(fill=tk.BOTH, expand=True, pady=(0, 12))

        # 1. Sekme: İzinler & İlk Kurulum (En başta - Öncelikli)
        self.tab_permissions = ttk.Frame(self.notebook, padding="14")
        self.notebook.add(self.tab_permissions, text="  🛡️ İzinler & İlk Kurulum  ")
        self._build_tab_permissions(self.tab_permissions)

        # 2. Sekme: Model & Sağlayıcı
        self.tab_models = ttk.Frame(self.notebook, padding="14")
        self.notebook.add(self.tab_models, text="  🤖 Model & Sağlayıcı  ")
        self._build_tab_models(self.tab_models)

        # 3. Sekme: API Anahtarları
        self.tab_api = ttk.Frame(self.notebook, padding="14")
        self.notebook.add(self.tab_api, text="  🔑 API Anahtarları  ")
        self._build_tab_api(self.tab_api)

        # 4. Sekme: Genel Tercihler
        self.tab_prefs = ttk.Frame(self.notebook, padding="14")
        self.notebook.add(self.tab_prefs, text="  ⚙️ Genel Tercihler  ")
        self._build_tab_prefs(self.tab_prefs)

        # Alt Çubuk (Status & Action Buttons)
        bottom_frame = ttk.Frame(main_frame)
        bottom_frame.pack(fill=tk.X, side=tk.BOTTOM, pady=(4, 0))

        self.status_bar_lbl = ttk.Label(
            bottom_frame,
            text="Hazır.",
            font=self.font_small,
            foreground="#555555"
        )
        self.status_bar_lbl.pack(side=tk.LEFT, pady=4)

        btn_close = ttk.Button(bottom_frame, text="İptal", command=self.destroy)
        btn_close.pack(side=tk.RIGHT, padx=(6, 0))

        btn_apply = ttk.Button(bottom_frame, text="Uygula", command=lambda: self.save_settings(close_after=False))
        btn_apply.pack(side=tk.RIGHT, padx=(6, 0))

        btn_save = ttk.Button(bottom_frame, text="Kaydet ve Kapat", command=lambda: self.save_settings(close_after=True))
        btn_save.pack(side=tk.RIGHT)

    # -------------------------------------------------------------------------
    # Sekme 1: İzinler ve İlk Kurulum Best Practices (Öncelikli Bölüm)
    # -------------------------------------------------------------------------
    def _build_tab_permissions(self, parent):
        """macOS Mikrofon ve Erişilebilirlik İzin Yönetimi & Canlı VU-Meter Testi."""
        # 1. Bilgilendirme Kartı (Best Practices Rehberi)
        info_card = ttk.LabelFrame(parent, text=" 📋 macOS İlk Kurulum ve İzin Yönetimi (Best Practices) ", padding="10")
        info_card.pack(fill=tk.X, pady=(0, 10))

        guidance_text = (
            "• macOS Güvenlik Mimarisi (TCC): Mikrofon ve tuş dinleme izinleri, uygulamanın çalıştığı ana sürece "
            "(Terminal, iTerm, VS Code veya Cursor) tanımlanır.\n"
            "• Mikrofon İzni: Konuşmanızın algılanabilmesi için sistemde mikrofon yetkisinin 'Açık' olması zorunludur.\n"
            "• Erişilebilirlik İzni: Sağ Command tuşunu arka planda dinlemek ve metni aktif imlece otomatik yapıştırmak için gereklidir.\n"
            "• İlk Kurulum Adımı: Aşağıdaki durum göstergelerini kontrol edin. 'Yetki Verilmedi' görünüyorsa 'macOS Ayarları' "
            "butonuyla ilgili izni açıp 'Yenile' butonuna tıklayın."
        )
        lbl_guidance = ttk.Label(info_card, text=guidance_text, font=self.font_small, justify=tk.LEFT, wraplength=640)
        lbl_guidance.pack(fill=tk.X)

        # 2. İzin Durum Kartı
        status_card = ttk.LabelFrame(parent, text=" 🛡️ Sistem İzin Durumu ", padding="10")
        status_card.pack(fill=tk.X, pady=(0, 10))

        # Mikrofon Durumu Satırı
        mic_row = ttk.Frame(status_card)
        mic_row.pack(fill=tk.X, pady=3)

        ttk.Label(mic_row, text="Mikrofon İzni:", font=self.font_bold, width=18).pack(side=tk.LEFT)
        self.lbl_mic_badge = ttk.Label(mic_row, text="Kontrol ediliyor...", font=self.font_regular)
        self.lbl_mic_badge.pack(side=tk.LEFT, padx=(4, 8))

        btn_mic_settings = ttk.Button(
            mic_row,
            text="⚙️ macOS Mikrofon Ayarları",
            command=lambda: PermissionManager.open_system_settings("Microphone")
        )
        btn_mic_settings.pack(side=tk.RIGHT, padx=2)

        btn_mic_req = ttk.Button(
            mic_row,
            text="İzin İste",
            command=self._on_request_mic_clicked
        )
        btn_mic_req.pack(side=tk.RIGHT, padx=2)

        # Aktif Mikrofon Cihazı Bilgisi
        dev_row = ttk.Frame(status_card)
        dev_row.pack(fill=tk.X, pady=(2, 6))
        ttk.Label(dev_row, text="Aktif Giriş Aygıtı:", font=self.font_small, width=18, foreground="#666666").pack(side=tk.LEFT)
        self.lbl_mic_device = ttk.Label(dev_row, text=PermissionManager.get_default_microphone_info(), font=self.font_small, foreground="#333333")
        self.lbl_mic_device.pack(side=tk.LEFT, padx=(4, 8))

        btn_sound_settings = ttk.Button(
            dev_row,
            text="Ses Giriş Ayarları",
            command=lambda: PermissionManager.open_system_settings("sound")
        )
        btn_sound_settings.pack(side=tk.RIGHT, padx=2)

        ttk.Separator(status_card, orient=tk.HORIZONTAL).pack(fill=tk.X, pady=6)

        # Erişilebilirlik (Accessibility) Satırı
        ax_row = ttk.Frame(status_card)
        ax_row.pack(fill=tk.X, pady=3)

        ttk.Label(ax_row, text="Erişilebilirlik İzni:", font=self.font_bold, width=18).pack(side=tk.LEFT)
        self.lbl_ax_badge = ttk.Label(ax_row, text="Kontrol ediliyor...", font=self.font_regular)
        self.lbl_ax_badge.pack(side=tk.LEFT, padx=(4, 8))

        btn_ax_settings = ttk.Button(
            ax_row,
            text="⚙️ macOS Erişilebilirlik Ayarları",
            command=lambda: PermissionManager.open_system_settings("Accessibility")
        )
        btn_ax_settings.pack(side=tk.RIGHT, padx=2)

        btn_ax_req = ttk.Button(
            ax_row,
            text="İzin İste",
            command=self._on_request_ax_clicked
        )
        btn_ax_req.pack(side=tk.RIGHT, padx=2)

        # Durumu Yenile Butonu
        refresh_row = ttk.Frame(status_card)
        refresh_row.pack(fill=tk.X, pady=(6, 0))
        btn_refresh = ttk.Button(
            refresh_row,
            text="🔄 İzin Durumunu ve Aygıtları Yenile",
            command=self.refresh_permissions_status
        )
        btn_refresh.pack(side=tk.LEFT)

        # 3. Canlı Mikrofon Seviye Testi (VU Meter)
        test_card = ttk.LabelFrame(parent, text=" 🎤 Canlı Mikrofon Donanım ve Seviye Testi (VU-Meter) ", padding="10")
        test_card.pack(fill=tk.X)

        test_info = ttk.Label(
            test_card,
            text="Mikrofonunuzun gerçekten ses alıp almadığını doğrulamak için aşağıdaki butona basın ve konuşun:",
            font=self.font_small,
            foreground="#555555"
        )
        test_info.pack(anchor=tk.W, pady=(0, 6))

        # Seviye Çubuğu (Progressbar)
        meter_row = ttk.Frame(test_card)
        meter_row.pack(fill=tk.X, pady=4)

        ttk.Label(meter_row, text="Ses Seviyesi:", font=self.font_bold, width=14).pack(side=tk.LEFT)
        self.vu_progress = ttk.Progressbar(meter_row, orient=tk.HORIZONTAL, mode="determinate", maximum=100)
        self.vu_progress.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(4, 10))

        self.lbl_vu_pct = ttk.Label(meter_row, text="%0", font=self.font_bold, width=6)
        self.lbl_vu_pct.pack(side=tk.RIGHT)

        # Test Butonu ve Sonuç Mesajı
        action_row = ttk.Frame(test_card)
        action_row.pack(fill=tk.X, pady=(6, 0))

        self.btn_run_test = ttk.Button(
            action_row,
            text="🎤 Testi Başlat (2 Saniye)",
            command=self._toggle_mic_test
        )
        self.btn_run_test.pack(side=tk.LEFT)

        self.lbl_test_result = ttk.Label(
            action_row,
            text="Hazır - Butona tıklayarak sesinizi test edin.",
            font=self.font_small,
            foreground="#666666"
        )
        self.lbl_test_result.pack(side=tk.LEFT, padx=(12, 0))

    def refresh_permissions_status(self):
        """Mikrofon ve Erişilebilirlik izin durumlarını anında sorgular ve günceller."""
        # 1. Mikrofon
        code, text, icon = PermissionManager.get_microphone_status()
        self.lbl_mic_badge.config(text=f"{icon} {text}")
        if code == "authorized":
            self.lbl_mic_badge.config(foreground="#1b5e20")
        elif code == "denied":
            self.lbl_mic_badge.config(foreground="#b71c1c")
        else:
            self.lbl_mic_badge.config(foreground="#e65100")

        # Aktif Aygıt
        dev_info = PermissionManager.get_default_microphone_info()
        self.lbl_mic_device.config(text=dev_info)

        # 2. Erişilebilirlik
        ax_code, ax_text, ax_icon = PermissionManager.get_accessibility_status()
        self.lbl_ax_badge.config(text=f"{ax_icon} {ax_text}")
        if ax_code == "authorized":
            self.lbl_ax_badge.config(foreground="#1b5e20")
        else:
            self.lbl_ax_badge.config(foreground="#b71c1c")

        self.status_bar_lbl.config(text=f"İzinler güncellendi: {time.strftime('%H:%M:%S')}")

    def _on_request_mic_clicked(self):
        PermissionManager.request_microphone_access()
        self.after(1000, self.refresh_permissions_status)

    def _on_request_ax_clicked(self):
        PermissionManager.request_accessibility_access()
        self.after(1000, self.refresh_permissions_status)

    def _toggle_mic_test(self):
        """Canlı mikrofon seviye ölçümünü asenkron iş parçacığında başlatır."""
        if self._mic_test_running:
            return

        self._mic_test_running = True
        self.btn_run_test.config(state=tk.DISABLED, text="Dinleniyor... (Konuşun)")
        self.vu_progress["value"] = 0
        self.lbl_vu_pct.config(text="%0")
        self.lbl_test_result.config(text="🔴 Kayıt yapılıyor, lütfen konuşun...", foreground="#d32f2f")

        def _test_worker():
            levels = []
            start_time = time.time()

            def _audio_callback(indata, frames, time_info, status):
                if not self._mic_test_running:
                    return
                # Tepe genlik hesapla (int16 aralığı 0 - 32767)
                peak = int(np.max(np.abs(indata)))
                # Görsel algı için ölçekle (%0 - %100)
                pct = min(100.0, (peak / 32768.0) * 100 * 3.5)
                levels.append(peak)
                self.after(0, lambda p=pct: self._update_vu_meter(p))

            try:
                with sd.InputStream(samplerate=16000, channels=1, dtype="int16", callback=_audio_callback):
                    while (time.time() - start_time) < 2.0 and self._mic_test_running:
                        time.sleep(0.05)
            except Exception as e:
                self.after(0, lambda: self._on_mic_test_error(str(e)))
                return

            max_amp = max(levels) if levels else 0
            self.after(0, lambda: self._on_mic_test_finished(max_amp))

        threading.Thread(target=_test_worker, daemon=True).start()

    def _update_vu_meter(self, pct: float):
        """VU meter çubuğunu ve yüzde etiketini günceller."""
        if self._mic_test_running:
            self.vu_progress["value"] = pct
            self.lbl_vu_pct.config(text=f"%{int(pct)}")

    def _on_mic_test_finished(self, max_amplitude: int):
        self._mic_test_running = False
        self.btn_run_test.config(state=tk.NORMAL, text="🎤 Testi Başlat (2 Saniye)")
        self.vu_progress["value"] = 0
        self.lbl_vu_pct.config(text="%0")

        if max_amplitude >= 400:
            self.lbl_test_result.config(
                text=f"🟢 Ses Sinyali Başarılı! (Tepe Genlik: {max_amplitude}) - Mikrofonunuz hazır.",
                foreground="#1b5e20"
            )
        else:
            self.lbl_test_result.config(
                text=f"🟡 Çok Düşük Sinyal ({max_amplitude}) - Lütfen mikrofon ses düzeyini kontrol edin.",
                foreground="#e65100"
            )

    # -------------------------------------------------------------------------
    # Sekme 2: Model & Sağlayıcı Seçimi
    # -------------------------------------------------------------------------
    def _build_tab_models(self, parent):
        """Groq Whisper ve Gemini model seçimleri ve fiyatlandırma bilgileri."""
        # 1. Sağlayıcı Seçimi Kartı
        provider_card = ttk.LabelFrame(parent, text=" 🌐 Aktif Deşifre Sağlayıcısı (Provider) ", padding="10")
        provider_card.pack(fill=tk.X, pady=(0, 10))

        self.var_provider = tk.StringVar(value=self.current_config.get("provider", "groq"))

        r_groq = ttk.Radiobutton(
            provider_card,
            text="Groq Whisper (~0.3s Ultra Hızlı - Önerilen)",
            value="groq",
            variable=self.var_provider,
            command=self._on_provider_changed
        )
        r_groq.pack(anchor=tk.W, pady=2)
        ttk.Label(
            provider_card,
            text="   Konuşmayı anında (~0.3 saniyede) ekrana yapıştırır. Gerçek zamanlı hızlı yazma için en iyisidir.\n   Best Prices: 0.00018 USD/dakika (Günlük 8 saat ücretsiz kota mevcuttur).",
            font=self.font_small,
            foreground="#555555"
        ).pack(anchor=tk.W, pady=(0, 6))

        r_gemini = ttk.Radiobutton(
            provider_card,
            text="Google Gemini (~2.0s - 2.5s Bağlamsal & Doğal Dil)",
            value="gemini",
            variable=self.var_provider,
            command=self._on_provider_changed
        )
        r_gemini.pack(anchor=tk.W, pady=2)
        ttk.Label(
            provider_card,
            text="   Doğal dil işleme ile noktalama, yazım hataları ve bağlam düzeltmesi yapar.\n   Best Prices: Gemini 3.6 Flash - Ücretsiz / Düşük Maliyet.",
            font=self.font_small,
            foreground="#555555"
        ).pack(anchor=tk.W)

        # 2. Model Detay Seçimi
        models_card = ttk.LabelFrame(parent, text=" 🤖 Model Seçenekleri ", padding="10")
        models_card.pack(fill=tk.X, pady=(0, 10))

        # Groq Modeli
        groq_m_frame = ttk.Frame(models_card)
        groq_m_frame.pack(fill=tk.X, pady=4)
        ttk.Label(groq_m_frame, text="Groq Modeli:", font=self.font_bold, width=16).pack(side=tk.LEFT)
        self.var_groq_model = tk.StringVar(value=self.current_config.get("groq_model", "whisper-large-v3-turbo"))
        
        self.groq_options = [
            ("whisper-large-v3-turbo", "Whisper Large v3 Turbo (~0.3s - En Hızlı, Önerilen)"),
            ("whisper-large-v3", "Whisper Large v3 (~0.4s - En Yüksek Doğruluk)")
        ]
        self.combo_groq_m = ttk.Combobox(
            groq_m_frame,
            values=[opt[1] for opt in self.groq_options],
            state="readonly",
            width=50
        )
        current_g_id = self.current_config.get("groq_model", "whisper-large-v3-turbo")
        for idx, (mid, label) in enumerate(self.groq_options):
            if mid == current_g_id:
                self.combo_groq_m.current(idx)
                break
        else:
            self.combo_groq_m.current(0)
        self.combo_groq_m.pack(side=tk.LEFT, fill=tk.X, expand=True)

        # Gemini Modeli
        gemini_m_frame = ttk.Frame(models_card)
        gemini_m_frame.pack(fill=tk.X, pady=4)
        ttk.Label(gemini_m_frame, text="Gemini Modeli:", font=self.font_bold, width=16).pack(side=tk.LEFT)
        self.var_gemini_model = tk.StringVar(value=self.current_config.get("gemini_model", "gemini-3.6-flash"))
        
        self.gemini_options = [
            ("gemini-3.6-flash", "Gemini 3.6 Flash (Doğal Dil & Bağlam Düzeltmeli - Önerilen)"),
            ("gemini-3.5-flash", "Gemini 3.5 Flash (Hızlı & Dengeli)")
        ]
        self.combo_gemini_m = ttk.Combobox(
            gemini_m_frame,
            values=[opt[1] for opt in self.gemini_options],
            state="readonly",
            width=50
        )
        current_gm_id = self.current_config.get("gemini_model", "gemini-3.6-flash")
        for idx, (mid, label) in enumerate(self.gemini_options):
            if mid == current_gm_id:
                self.combo_gemini_m.current(idx)
                break
        else:
            self.combo_gemini_m.current(0)
        self.combo_gemini_m.pack(side=tk.LEFT, fill=tk.X, expand=True)

        # Dil Tercihi
        lang_frame = ttk.Frame(models_card)
        lang_frame.pack(fill=tk.X, pady=4)
        ttk.Label(lang_frame, text="Konuşma Dili:", font=self.font_bold, width=16).pack(side=tk.LEFT)
        
        self.lang_options = [
            ("tr", "Türkçe (tr)"),
            ("en", "İngilizce (en)"),
            ("auto", "Otomatik Dil Algılama (auto)")
        ]
        self.combo_lang = ttk.Combobox(
            lang_frame,
            values=[opt[1] for opt in self.lang_options],
            state="readonly",
            width=30
        )
        current_lang = self.current_config.get("language", "tr")
        for idx, (code, name) in enumerate(self.lang_options):
            if code == current_lang:
                self.combo_lang.current(idx)
                break
        else:
            self.combo_lang.current(0)
        self.combo_lang.pack(side=tk.LEFT)

    def _on_provider_changed(self):
        """Seçili sağlayıcıya göre durum güncellemesi."""
        prov = self.var_provider.get()
        self.status_bar_lbl.config(text=f"Sağlayıcı seçildi: {prov.upper()}")

    # -------------------------------------------------------------------------
    # Sekme 3: API Anahtarları Yönetimi ve Canlı Doğrulama
    # -------------------------------------------------------------------------
    def _build_tab_api(self, parent):
        """Groq ve Google Gemini API anahtarları giriş ve doğrulama alanı."""
        # Bilgi Notu
        lbl_info = ttk.Label(
            parent,
            text="API anahtarlarınız yerel ortamınızda güvenle .env ve config.json dosyalarına kaydedilir.",
            font=self.font_small,
            foreground="#666666"
        )
        lbl_info.pack(anchor=tk.W, pady=(0, 8))

        # 1. Groq API Anahtarı Kartı
        groq_box = ttk.LabelFrame(parent, text=" ⚡ Groq Cloud API Anahtarı (Whisper STT) ", padding="10")
        groq_box.pack(fill=tk.X, pady=(0, 10))

        g_input_row = ttk.Frame(groq_box)
        g_input_row.pack(fill=tk.X, pady=2)

        ttk.Label(g_input_row, text="Groq API Key:", font=self.font_bold, width=16).pack(side=tk.LEFT)
        self.ent_groq_key = ttk.Entry(g_input_row, font=self.font_code, show="*", width=38)
        self.ent_groq_key.insert(0, self.current_config.get("groq_api_key", ""))
        self.ent_groq_key.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(4, 6))

        self.btn_groq_show = ttk.Button(
            g_input_row,
            text="👁️ Göster",
            width=8,
            command=lambda: self._toggle_show_key(self.ent_groq_key, self.btn_groq_show)
        )
        self.btn_groq_show.pack(side=tk.LEFT, padx=2)

        self.btn_groq_test = ttk.Button(
            g_input_row,
            text="🔑 Doğrula & Test Et",
            command=self._test_groq_key_async
        )
        self.btn_groq_test.pack(side=tk.LEFT, padx=2)

        # Groq Durum ve Link Satırı
        g_status_row = ttk.Frame(groq_box)
        g_status_row.pack(fill=tk.X, pady=(6, 2))

        self.lbl_groq_status = ttk.Label(
            g_status_row,
            text="Henüz doğrulanmadı.",
            font=self.font_small,
            foreground="#666666"
        )
        self.lbl_groq_status.pack(side=tk.LEFT)

        btn_groq_link = ttk.Button(
            g_status_row,
            text="🌐 Groq Console'dan Ücretsiz Key Al ➔",
            command=lambda: webbrowser.open("https://console.groq.com/keys")
        )
        btn_groq_link.pack(side=tk.RIGHT)

        # 2. Google Gemini API Anahtarı Kartı
        gemini_box = ttk.LabelFrame(parent, text=" 💎 Google Gemini API Anahtarı ", padding="10")
        gemini_box.pack(fill=tk.X, pady=(0, 10))

        gm_input_row = ttk.Frame(gemini_box)
        gm_input_row.pack(fill=tk.X, pady=2)

        ttk.Label(gm_input_row, text="Gemini API Key:", font=self.font_bold, width=16).pack(side=tk.LEFT)
        self.ent_gemini_key = ttk.Entry(gm_input_row, font=self.font_code, show="*", width=38)
        self.ent_gemini_key.insert(0, self.current_config.get("gemini_api_key", ""))
        self.ent_gemini_key.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(4, 6))

        self.btn_gemini_show = ttk.Button(
            gm_input_row,
            text="👁️ Göster",
            width=8,
            command=lambda: self._toggle_show_key(self.ent_gemini_key, self.btn_gemini_show)
        )
        self.btn_gemini_show.pack(side=tk.LEFT, padx=2)

        self.btn_gemini_test = ttk.Button(
            gm_input_row,
            text="🔑 Doğrula & Test Et",
            command=self._test_gemini_key_async
        )
        self.btn_gemini_test.pack(side=tk.LEFT, padx=2)

        # Gemini Durum ve Link Satırı
        gm_status_row = ttk.Frame(gemini_box)
        gm_status_row.pack(fill=tk.X, pady=(6, 2))

        self.lbl_gemini_status = ttk.Label(
            gm_status_row,
            text="Henüz doğrulanmadı.",
            font=self.font_small,
            foreground="#666666"
        )
        self.lbl_gemini_status.pack(side=tk.LEFT)

        btn_gemini_link = ttk.Button(
            gm_status_row,
            text="🌐 Google AI Studio'dan Key Al ➔",
            command=lambda: webbrowser.open("https://aistudio.google.com/app/apikey")
        )
        btn_gemini_link.pack(side=tk.RIGHT)

    def _toggle_show_key(self, entry_widget: ttk.Entry, button_widget: ttk.Button):
        """Parola alanını maskeleme veya açık metin olarak gösterir."""
        if entry_widget.cget("show") == "*":
            entry_widget.config(show="")
            button_widget.config(text="🔒 Gizle")
        else:
            entry_widget.config(show="*")
            button_widget.config(text="👁️ Göster")

    def _test_groq_key_async(self):
        key = self.ent_groq_key.get().strip()
        self.lbl_groq_status.config(text="⏳ Groq sunucuları test ediliyor...", foreground="#0d47a1")
        self.btn_groq_test.config(state=tk.DISABLED)

        def _worker():
            success, msg, latency = ApiValidator.test_groq_key(key)
            self.after(0, lambda: self._apply_groq_test_result(success, msg, latency))

        threading.Thread(target=_worker, daemon=True).start()

    def _apply_groq_test_result(self, success: bool, msg: str, latency: float):
        self.btn_groq_test.config(state=tk.NORMAL)
        if success:
            self.lbl_groq_status.config(text=f"🟢 {msg} (~{int(latency * 1000)}ms)", foreground="#1b5e20")
        else:
            self.lbl_groq_status.config(text=f"🔴 {msg}", foreground="#b71c1c")

    def _test_gemini_key_async(self):
        key = self.ent_gemini_key.get().strip()
        self.lbl_gemini_status.config(text="⏳ Google Gemini sunucuları test ediliyor...", foreground="#0d47a1")
        self.btn_gemini_test.config(state=tk.DISABLED)

        def _worker():
            success, msg, latency = ApiValidator.test_gemini_key(key)
            self.after(0, lambda: self._apply_gemini_test_result(success, msg, latency))

        threading.Thread(target=_worker, daemon=True).start()

    def _apply_gemini_test_result(self, success: bool, msg: str, latency: float):
        self.btn_gemini_test.config(state=tk.NORMAL)
        if success:
            self.lbl_gemini_status.config(text=f"🟢 {msg} (~{int(latency * 1000)}ms)", foreground="#1b5e20")
        else:
            self.lbl_gemini_status.config(text=f"🔴 {msg}", foreground="#b71c1c")

    # -------------------------------------------------------------------------
    # Sekme 4: Genel Tercihler ve Kısayol Ayarları
    # -------------------------------------------------------------------------
    def _build_tab_prefs(self, parent):
        """Tetikleme modu, ses efektleri, pano geri yükleme ve hassasiyet ayarları."""
        # 1. Tetikleme Modu Kartı
        trigger_box = ttk.LabelFrame(parent, text=" ⌨️ Tetikleme Modu (Sağ Command Tuşu) ", padding="10")
        trigger_box.pack(fill=tk.X, pady=(0, 10))

        self.var_trigger_mode = tk.StringVar(value=self.current_config.get("trigger_mode", "hold"))

        r_hold = ttk.Radiobutton(
            trigger_box,
            text="Basılı Tut - Konuş (Push-to-Talk) [Varsayılan & En Hızlı]",
            value="hold",
            variable=self.var_trigger_mode
        )
        r_hold.pack(anchor=tk.W, pady=2)
        ttk.Label(
            trigger_box,
            text="   Sağ Command tuşuna basılı tutarken konuşun, tuşu bıraktığınız an deşifre edilip yapıştırılır.",
            font=self.font_small,
            foreground="#555555"
        ).pack(anchor=tk.W, pady=(0, 4))

        r_toggle = ttk.Radiobutton(
            trigger_box,
            text="Aç / Kapa (Toggle)",
            value="toggle",
            variable=self.var_trigger_mode
        )
        r_toggle.pack(anchor=tk.W, pady=2)
        ttk.Label(
            trigger_box,
            text="   Tuşa bir kez basınca kayıt başlar, konuşmanız bitince tekrar basınca durdurulup yapıştırılır.",
            font=self.font_small,
            foreground="#555555"
        ).pack(anchor=tk.W, pady=(0, 4))

        r_smart = ttk.Radiobutton(
            trigger_box,
            text="Akıllı Hibrit (Smart)",
            value="smart",
            variable=self.var_trigger_mode
        )
        r_smart.pack(anchor=tk.W, pady=2)
        ttk.Label(
            trigger_box,
            text="   Kısa tıklamada Aç/Kapa, uzun basmada basılı tut-bırak davranışı gösterir.",
            font=self.font_small,
            foreground="#555555"
        ).pack(anchor=tk.W)

        # 2. Seçenekler ve Efektler Kartı
        options_box = ttk.LabelFrame(parent, text=" 🔊 Ses Efektleri & Pano Yönetimi ", padding="10")
        options_box.pack(fill=tk.X, pady=(0, 10))

        self.var_play_sounds = tk.BooleanVar(value=self.current_config.get("play_sounds", True))
        chk_sounds = ttk.Checkbutton(
            options_box,
            text="macOS Ses Efektlerini Çal (Kayıt başlama 'Tink', bitiş 'Pop', başarı 'Glass')",
            variable=self.var_play_sounds
        )
        chk_sounds.pack(anchor=tk.W, pady=3)

        self.var_restore_clip = tk.BooleanVar(value=self.current_config.get("restore_clipboard", False))
        chk_clip = ttk.Checkbutton(
            options_box,
            text="Metin Yapıştırıldıktan Sonra Önceki Pano İçeriğini Geri Yükle",
            variable=self.var_restore_clip
        )
        chk_clip.pack(anchor=tk.W, pady=3)
        ttk.Label(
            options_box,
            text="   Konuşmanız metin alanına yapıştırıldıktan ~400ms sonra daha önce kopyaladığınız metin geri yüklenir.",
            font=self.font_small,
            foreground="#555555"
        ).pack(anchor=tk.W)

        # 3. Gelişmiş Hassasiyet Sürgüleri (Sliders)
        sliders_box = ttk.LabelFrame(parent, text=" ⏱️ Süre & Gecikme Hassasiyeti ", padding="10")
        sliders_box.pack(fill=tk.X)

        # Yapıştırma Gecikmesi
        p_row = ttk.Frame(sliders_box)
        p_row.pack(fill=tk.X, pady=3)
        ttk.Label(p_row, text="Yapıştırma Gecikmesi:", font=self.font_regular, width=22).pack(side=tk.LEFT)
        self.var_paste_delay = tk.IntVar(value=int(self.current_config.get("paste_delay_ms", 20)))
        
        self.lbl_paste_delay_val = ttk.Label(p_row, text=f"{self.var_paste_delay.get()} ms", font=self.font_bold, width=8)
        self.lbl_paste_delay_val.pack(side=tk.RIGHT)

        slider_paste = ttk.Scale(
            p_row,
            from_=10,
            to=200,
            orient=tk.HORIZONTAL,
            variable=self.var_paste_delay,
            command=lambda v: self.lbl_paste_delay_val.config(text=f"{int(float(v))} ms")
        )
        slider_paste.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(4, 8))

        # Kazara Basma Eşiği (Min Record Duration)
        d_row = ttk.Frame(sliders_box)
        d_row.pack(fill=tk.X, pady=3)
        ttk.Label(d_row, text="Minimum Kayıt Süresi:", font=self.font_regular, width=22).pack(side=tk.LEFT)
        self.var_min_duration = tk.DoubleVar(value=float(self.current_config.get("min_record_duration", 0.20)))

        self.lbl_min_duration_val = ttk.Label(d_row, text=f"{self.var_min_duration.get():.2f} sn", font=self.font_bold, width=8)
        self.lbl_min_duration_val.pack(side=tk.RIGHT)

        slider_duration = ttk.Scale(
            d_row,
            from_=0.05,
            to=0.50,
            orient=tk.HORIZONTAL,
            variable=self.var_min_duration,
            command=lambda v: self.lbl_min_duration_val.config(text=f"{float(v):.2f} sn")
        )
        slider_duration.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(4, 8))

    # -------------------------------------------------------------------------
    # Ayarları Kaydetme ve Uygulama
    # -------------------------------------------------------------------------
    def save_settings(self, close_after: bool = True):
        """Tüm sekmelerdeki verileri toplar, config.json ve .env dosyalarına yazar."""
        # 1. Model id'lerini combobox seçimlerinden ayrıştır
        selected_groq_idx = self.combo_groq_m.current()
        groq_model_id = self.groq_options[selected_groq_idx][0] if selected_groq_idx >= 0 else "whisper-large-v3-turbo"

        selected_gemini_idx = self.combo_gemini_m.current()
        gemini_model_id = self.gemini_options[selected_gemini_idx][0] if selected_gemini_idx >= 0 else "gemini-3.6-flash"

        selected_lang_idx = self.combo_lang.current()
        lang_code = self.lang_options[selected_lang_idx][0] if selected_lang_idx >= 0 else "tr"

        # 2. Yeni yapılandırma sözlüğü
        new_config: Dict[str, Any] = {
            "provider": self.var_provider.get(),
            "groq_api_key": self.ent_groq_key.get().strip(),
            "gemini_api_key": self.ent_gemini_key.get().strip(),
            "groq_model": groq_model_id,
            "gemini_model": gemini_model_id,
            "language": lang_code,
            "trigger_key": 54,  # Sağ Command tuşu sabit
            "trigger_mode": self.var_trigger_mode.get(),
            "play_sounds": self.var_play_sounds.get(),
            "restore_clipboard": self.var_restore_clip.get(),
            "paste_delay_ms": int(self.var_paste_delay.get()),
            "min_record_duration": round(float(self.var_min_duration.get()), 2)
        }

        # 3. Dosyalara kaydet
        try:
            save_config(new_config)
            self.current_config = new_config
            self.status_bar_lbl.config(
                text=f"🟢 Ayarlar başarıyla kaydedildi ({time.strftime('%H:%M:%S')})",
                foreground="#1b5e20"
            )
            if close_after:
                self.after(300, self.destroy)
        except Exception as e:
            messagebox.showerror("Kayıt Hatası", f"Ayarlar kaydedilirken bir hata oluştu:\n{e}")


def open_settings_dialog():
    """Ayarlar penceresini ana iş parçacığında çalıştırır."""
    app = SettingsDialog()
    app.mainloop()


if __name__ == "__main__":
    open_settings_dialog()
