#!/usr/bin/env python3
"""
voice_engine.py
macOS Voice Typing - Yüksek Performanslı Ses Kaydı ve Deşifre Motoru
Sıfır disk I/O (tamamen RAM / in-memory BytesIO), Groq Whisper (~0.3s) ve Gemini STT desteği.
"""

import io
import time
import wave
import base64
import threading
import warnings
from typing import Optional, Dict, Any, Tuple
import numpy as np
import sounddevice as sd

warnings.filterwarnings("ignore", message=".*automatic function calling.*")
warnings.filterwarnings("ignore", category=DeprecationWarning, module="sounddevice")
warnings.filterwarnings("ignore", category=UserWarning)

class AudioRecorder:
    """Mikrofondan 16kHz mono ses kaydı yapan, sıfır gecikmeli bellek içi (in-memory) kaydedici."""
    def __init__(self, sample_rate: int = 16000):
        self.sample_rate = sample_rate
        self.frames = []
        self.stream: Optional[sd.InputStream] = None
        self.is_recording = False
        self.start_time = 0.0
        self._lock = threading.Lock()

    def _audio_callback(self, indata, frames_count, time_info, status):
        if self.is_recording:
            self.frames.append(indata.copy())

    def start(self):
        """Ses kaydını başlatır."""
        with self._lock:
            if self.is_recording:
                return
            self.frames = []
            self.is_recording = True
            self.start_time = time.time()
            try:
                self.stream = sd.InputStream(
                    samplerate=self.sample_rate,
                    channels=1,
                    dtype="int16",
                    callback=self._audio_callback
                )
                self.stream.start()
            except Exception as e:
                self.is_recording = False
                self.stream = None
                print(f"[Hata] Mikrofon akışı başlatılamadı: {e}")

    def stop(self) -> Tuple[Optional[io.BytesIO], float]:
        """Ses kaydını durdurur ve bellekteki WAV tamponunu ve süreyi döner."""
        with self._lock:
            if not self.is_recording:
                return None, 0.0
            self.is_recording = False
            duration = time.time() - self.start_time
            stream_to_close = self.stream
            self.stream = None
            recorded_frames = self.frames
            self.frames = []

        if stream_to_close:
            try:
                stream_to_close.stop()
                stream_to_close.close()
            except Exception:
                pass

        if not recorded_frames:
            return None, duration

        # RAM içinde ses verisini birleştir
        audio_data = np.concatenate(recorded_frames, axis=0)

        # Sessizlik / mikrofon kapalı kontrolü (enerji / tepe genlik)
        max_amplitude = int(np.max(np.abs(audio_data))) if audio_data.size > 0 else 0
        if max_amplitude < 30:
            # Saf dijital sessizlik veya mikrofon kapalı - gereksiz API harcamasını önle
            return None, duration

        # RAM içinde WAV dosyası oluştur (Disk I/O maliyeti 0 ms)
        wav_buffer = io.BytesIO()
        with wave.open(wav_buffer, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)  # 16-bit PCM
            wf.setframerate(self.sample_rate)
            wf.writeframes(audio_data.tobytes())

        wav_buffer.seek(0)
        wav_buffer.name = "audio.wav"
        return wav_buffer, duration


class Transcriber:
    """Groq ve Gemini STT servisleri için yüksek hızlı deşifre motoru."""
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self._groq_client = None
        self._gemini_client = None
        self._init_clients()

    def update_config(self, new_config: Dict[str, Any]):
        """Yeni ayarları uygular ve istemcileri gerekirse yeniler."""
        self.config = new_config
        self._init_clients()

    def _init_clients(self):
        # Groq
        groq_key = self.config.get("groq_api_key", "").strip()
        if groq_key:
            try:
                from groq import Groq
                self._groq_client = Groq(api_key=groq_key)
            except Exception as e:
                print(f"[Uyarı] Groq istemcisi başlatılamadı: {e}")
                self._groq_client = None
        else:
            self._groq_client = None

        # Gemini
        gemini_key = self.config.get("gemini_api_key", "").strip()
        if gemini_key:
            try:
                from google import genai
                self._gemini_client = genai.Client(api_key=gemini_key)
            except Exception:
                self._gemini_client = None
        else:
            self._gemini_client = None

    def transcribe(self, audio_buffer: io.BytesIO, provider: Optional[str] = None, model: Optional[str] = None) -> Dict[str, Any]:
        """Seçili sağlayıcı ile sesi yazıya döker."""
        provider = (provider or self.config.get("provider", "groq")).lower()
        if provider == "groq":
            return self.transcribe_groq(audio_buffer, model=model)
        elif provider == "gemini":
            return self.transcribe_gemini(audio_buffer, model=model)
        else:
            return {"success": False, "error": f"Bilinmeyen sağlayıcı: {provider}", "text": "", "latency": 0.0}

    def transcribe_groq(self, audio_buffer: io.BytesIO, model: Optional[str] = None) -> Dict[str, Any]:
        """Groq Whisper ile ultra hızlı (~0.3s) deşifre."""
        model = model or self.config.get("groq_model", "whisper-large-v3-turbo")
        lang = self.config.get("language", "tr")

        if not self._groq_client:
            key = self.config.get("groq_api_key", "").strip()
            if not key:
                return {"success": False, "error": "GROQ_API_KEY girilmemiş!", "text": "", "latency": 0.0}
            try:
                from groq import Groq
                self._groq_client = Groq(api_key=key)
            except Exception as e:
                return {"success": False, "error": f"Groq başlatılamadı: {e}", "text": "", "latency": 0.0}

        start_time = time.perf_counter()
        try:
            audio_buffer.seek(0)
            if not getattr(audio_buffer, "name", None):
                audio_buffer.name = "audio.wav"
            kwargs = {
                "file": audio_buffer,
                "model": model,
                "response_format": "verbose_json"
            }
            if lang and lang != "auto":
                kwargs["language"] = lang

            response = self._groq_client.audio.transcriptions.create(**kwargs)
            latency = time.perf_counter() - start_time
            text = (getattr(response, "text", "") or "").strip()
            return {
                "success": True,
                "text": text,
                "latency": round(latency, 3),
                "provider": "groq",
                "model": model,
                "error": None
            }
        except Exception as e:
            latency = time.perf_counter() - start_time
            return {
                "success": False,
                "error": f"Groq hatası: {e}",
                "text": "",
                "latency": round(latency, 3),
                "provider": "groq",
                "model": model
            }

    def transcribe_gemini(self, audio_buffer: io.BytesIO, model: Optional[str] = None) -> Dict[str, Any]:
        """Google Gemini API ile bağlamsal deşifre."""
        model = model or self.config.get("gemini_model", "gemini-3.6-flash")
        gemini_key = self.config.get("gemini_api_key", "").strip()

        if not gemini_key:
            return {"success": False, "error": "GEMINI_API_KEY girilmemiş!", "text": "", "latency": 0.0}

        prompt = (
            "Sen bir ses deşifre (transcription) sistemisin. "
            "Bu ses kaydındaki konuşmayı harfi harfine, doğru imla ve noktalama ile yazıya dök. "
            "Eğer ses kaydında belirgin bir insan konuşması yoksa, ortam gürültüsü veya sessizlik varsa kesinlikle hiçbir şey yazma, sadece boş bırak. "
            "Asla selamlama, özet veya fazladan yorum ekleme. Sadece konuşulan metni döndür."
        )

        start_time = time.perf_counter()
        audio_buffer.seek(0)
        audio_bytes = audio_buffer.read()

        def _clean_text(raw_text: str) -> str:
            t = (raw_text or "").strip()
            # Yaygın sessizlik yanılsamalarını (hallucination) temizle
            lower_t = t.lower().strip("[]().")
            if lower_t in {"sessizlik", "ses yok", "boşluk", "konuşma yok", "gürültü"}:
                return ""
            return t

        last_error = None

        # 1. Öncelik: google.genai SDK (Hızlı & kararlı)
        if self._gemini_client:
            try:
                from google.genai import types
                response = self._gemini_client.models.generate_content(
                    model=model,
                    contents=[
                        types.Part.from_bytes(data=audio_bytes, mime_type="audio/wav"),
                        prompt
                    ]
                )
                latency = time.perf_counter() - start_time
                text = _clean_text(response.text)
                return {
                    "success": True,
                    "text": text,
                    "latency": round(latency, 3),
                    "provider": "gemini",
                    "model": model,
                    "error": None
                }
            except Exception as e:
                last_error = e

        # 2. Yedek: Doğrudan REST API
        try:
            import requests
            audio_b64 = base64.b64encode(audio_bytes).decode("utf-8")
            payload = {
                "contents": [{
                    "parts": [
                        {"text": prompt},
                        {"inline_data": {"mime_type": "audio/wav", "data": audio_b64}}
                    ]
                }]
            }
            url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={gemini_key}"
            resp = requests.post(url, json=payload, headers={"Content-Type": "application/json"}, timeout=30)
            latency = time.perf_counter() - start_time

            if resp.status_code == 200:
                data = resp.json()
                raw_text = data["candidates"][0]["content"]["parts"][0]["text"]
                text = _clean_text(raw_text)
                return {
                    "success": True,
                    "text": text,
                    "latency": round(latency, 3),
                    "provider": "gemini",
                    "model": model,
                    "error": None
                }
            else:
                try:
                    err_msg = resp.json().get("error", {}).get("message", resp.text)
                except Exception:
                    err_msg = resp.text
                return {
                    "success": False,
                    "error": f"Gemini HTTP {resp.status_code}: {err_msg}",
                    "text": "",
                    "latency": round(latency, 3),
                    "provider": "gemini",
                    "model": model
                }
        except Exception as e:
            latency = time.perf_counter() - start_time
            err_details = f"{e} (SDK: {last_error})" if last_error else str(e)
            return {
                "success": False,
                "error": f"Gemini hatası: {err_details}",
                "text": "",
                "latency": round(latency, 3),
                "provider": "gemini",
                "model": model
            }
