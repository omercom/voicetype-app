# Deneyler

Ana uygulama (Swift, `Sources/`) dışındaki deneme, test ve ölçüm çalışmaları.
Antalia deneyinin kilitli bağımlılıkları `setup-tts.sh` tarafından yerel motor kurulumunda kullanılır.
Diğer deneyler uygulamanın derlenmesine veya kurulumuna dahil değildir.

| Klasör | İçerik |
|---|---|
| [`antalia-mini-demo/`](antalia-mini-demo/) | Aktif yerel Türkçe TTS: CPU/MPS demosu, sekiz WAV örneği, hız ölçümleri ve motor testleri. |
| [`ema-lightning-demo/`](ema-lightning-demo/) | Önceki yerel Türkçe TTS motoru: karşılaştırma için korunan CPU/MPS demosu ve ölçümler. |
| [`gemini-tts-test/`](gemini-tts-test/) | Gemini TTS denemeleri: hazır sesler, ses klonlama (Voices API), çoklu API anahtarı döndürme. Bkz. `SES_KLONLAMA_REHBERI.md` |
| [`benchmark/`](benchmark/) | Sağlayıcı karşılaştırma (`run_benchmark.py`), örnek sesler (`samples/`), sonuçlar, sürüm ölçüm araçları (`tools/`) ve Python testleri (`tests/`). Protokol: kökteki `RELEASE_VALIDATION.md` |
| [`python-prototype/`](python-prototype/) | Uygulamanın eski Python sürümü (Swift'e geçmeden önceki prototip). Artık kullanılmıyor, arşiv amaçlı |

```bash
# Benchmark testleri
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s experiments/benchmark/tests -p 'test_*.py'
```
