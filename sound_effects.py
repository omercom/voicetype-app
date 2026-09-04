#!/usr/bin/env python3
"""
sound_effects.py
macOS Voice Typing - Sistem Ses Efektleri Yöneticisi
Kullanıcıya görsel ekrana bakmadan anlık işitsel geri bildirim sağlar.
Tamamen in-process, Apple AppKit NSSound kullanarak sıfır gecikmeyle çalar.
"""

from typing import Dict, Optional, Any
try:
    from AppKit import NSSound
except ImportError:
    NSSound = None

class SoundManager:
    """macOS sistem seslerini bellekte önbelleğe alıp asenkron/gecikmesiz çalan yönetici."""
    
    SOUND_START = "Tink"      # Kayıt başladığında
    SOUND_STOP = "Pop"        # Kayıt bittiğinde / deşifre başladığında
    SOUND_SUCCESS = "Glass"   # Metin başarıyla yapıştırıldığında
    SOUND_CANCEL = "Basso"    # İptal edildiğinde veya hata oluştuğunda

    def __init__(self, enabled: bool = True):
        self.enabled = enabled
        self._cache: Dict[str, Optional[Any]] = {}
        if NSSound:
            self._preload()

    def _preload(self):
        """Sık kullanılan sesleri önceden belleğe yükler (ilk çalma gecikmesini önler)."""
        for sname in [self.SOUND_START, self.SOUND_STOP, self.SOUND_SUCCESS, self.SOUND_CANCEL]:
            try:
                snd = NSSound.soundNamed_(sname)
                if snd:
                    self._cache[sname] = snd
            except Exception:
                pass

    def play(self, sound_name: str):
        """Belirtilen macOS sistem sesini çalar."""
        if not self.enabled or not NSSound:
            return
        
        try:
            sound = self._cache.get(sound_name)
            if not sound:
                sound = NSSound.soundNamed_(sound_name)
                if sound:
                    self._cache[sound_name] = sound
            if sound:
                sound.play()
        except Exception:
            pass

    def play_start(self):
        self.play(self.SOUND_START)

    def play_stop(self):
        self.play(self.SOUND_STOP)

    def play_success(self):
        self.play(self.SOUND_SUCCESS)

    def play_cancel(self):
        self.play(self.SOUND_CANCEL)


# Kolay kullanım için tekil (singleton) örnek
sound_player = SoundManager(enabled=True)
