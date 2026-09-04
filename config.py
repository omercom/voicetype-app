#!/usr/bin/env python3
"""
config.py
macOS Voice Typing - Yapılandırma ve Ortam Değişkeni Yöneticisi
Groq, Gemini API anahtarları, model seçimleri ve ses/kısayol ayarlarını yönetir.
"""

import os
import json
from pathlib import Path
from typing import Dict, Any

CONFIG_FILE = Path(__file__).parent / "config.json"
ENV_FILE = Path(__file__).parent / ".env"

DEFAULT_CONFIG: Dict[str, Any] = {
    "provider": "groq",  # "groq" veya "gemini"
    "groq_api_key": "",
    "gemini_api_key": "",
    "groq_model": "whisper-large-v3-turbo",  # "whisper-large-v3-turbo" (~0.3s) veya "whisper-large-v3"
    "gemini_model": "gemini-3.6-flash",
    "language": "tr",  # "tr", "en", "auto"
    "trigger_key": 54,  # Sağ Command tuşu (0x36 = 54)
    "trigger_mode": "hold",  # "hold" (basılı tut-konuş, bırakınca yaz), "smart" (akıllı), "toggle" (aç-kapa)
    "play_sounds": True,  # Ses efektleri (Tink/Pop)
    "restore_clipboard": False,  # Metin yapıştırıldıktan sonra önceki panoyu geri yükle
    "paste_delay_ms": 20,  # Yapıştırma öncesi bekleme süresi (ms)
    "min_record_duration": 0.20,  # Kazara basmaları önlemek için minimum süre (sn)
}

AVAILABLE_MODELS = {
    "groq": [
        {"id": "whisper-large-v3-turbo", "name": "Whisper Large v3 Turbo (~0.3s - En Hızlı)", "speed": "~0.3s", "price": "0.00018 USD/dk"},
        {"id": "whisper-large-v3", "name": "Whisper Large v3 (En Yüksek Doğruluk)", "speed": "~0.4s", "price": "0.00018 USD/dk"}
    ],
    "gemini": [
        {"id": "gemini-3.6-flash", "name": "Gemini 3.6 Flash (Doğal Dil & Bağlam)", "speed": "~2.5s", "price": "Ücretsiz / Düşük Maliyet"},
        {"id": "gemini-3.5-flash", "name": "Gemini 3.5 Flash (Hızlı & Dengeli)", "speed": "~2.0s", "price": "Düşük Maliyet"}
    ]
}

def load_env_vars() -> Dict[str, str]:
    """Mevcut .env dosyasındaki anahtarları okur."""
    env_vars = {}
    if ENV_FILE.exists():
        try:
            with open(ENV_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    env_vars[k.strip()] = v.strip().strip("'\"")
        except Exception:
            pass
    return env_vars

def save_env_vars(groq_key: str = "", gemini_key: str = ""):
    """API anahtarlarını .env dosyasına kalıcı olarak yazar."""
    current = load_env_vars()
    if groq_key:
        current["GROQ_API_KEY"] = groq_key
    if gemini_key:
        current["GEMINI_API_KEY"] = gemini_key
    
    lines = [f"{k}={v}\n" for k, v in current.items()]
    with open(ENV_FILE, "w", encoding="utf-8") as f:
        f.writelines(lines)

def load_config() -> Dict[str, Any]:
    """Ayarları yükler. config.json yoksa .env'deki anahtarlarla varsayılan oluşturur."""
    config = dict(DEFAULT_CONFIG)
    
    # 1. .env'den anahtarları al
    env_vars = load_env_vars()
    config["groq_api_key"] = env_vars.get("GROQ_API_KEY", os.environ.get("GROQ_API_KEY", ""))
    config["gemini_api_key"] = env_vars.get("GEMINI_API_KEY", os.environ.get("GEMINI_API_KEY", ""))

    # 2. config.json varsa üzerine yaz
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                saved = json.load(f)
                config.update(saved)
        except Exception:
            pass

    # .env'den gelen anahtarlar öncelikli olarak boşsa doldurulsun
    if not config.get("groq_api_key") and env_vars.get("GROQ_API_KEY"):
        config["groq_api_key"] = env_vars["GROQ_API_KEY"]
    if not config.get("gemini_api_key") and env_vars.get("GEMINI_API_KEY"):
        config["gemini_api_key"] = env_vars["GEMINI_API_KEY"]

    return config

def save_config(new_config: Dict[str, Any]):
    """Ayarları config.json ve .env dosyalarına kaydeder."""
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(new_config, f, indent=2, ensure_ascii=False)
    
    # .env ve os.environ ile eşitle
    groq_k = new_config.get("groq_api_key", "")
    gemini_k = new_config.get("gemini_api_key", "")
    if groq_k:
        os.environ["GROQ_API_KEY"] = groq_k
    if gemini_k:
        os.environ["GEMINI_API_KEY"] = gemini_k
    if groq_k or gemini_k:
        save_env_vars(groq_key=groq_k, gemini_key=gemini_k)

def update_config_value(key: str, value: Any) -> Dict[str, Any]:
    """Belirli bir ayar anahtarını günceller ve kaydeder."""
    cfg = load_config()
    cfg[key] = value
    save_config(cfg)
    return cfg

def get_active_model(config: Dict[str, Any]) -> str:
    """Aktif sağlayıcıya göre seçili model adını döner."""
    provider = config.get("provider", "groq").lower()
    if provider == "groq":
        return config.get("groq_model", "whisper-large-v3-turbo")
    return config.get("gemini_model", "gemini-3.6-flash")

