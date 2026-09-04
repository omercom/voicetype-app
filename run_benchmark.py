#!/usr/bin/env python3
"""
run_benchmark.py
Groq (whisper-large-v3, whisper-large-v3-turbo) ve Google Gemini modellerini
Türkçe ses deşifre (speech-to-text) performansı açısından kıyaslayan benchmark scripti.

Metrikler:
- Normalized WER (Word Error Rate - Kelime Hata Oranı) [%]
- Normalized CER (Character Error Rate - Karakter Hata Oranı) [%]
- Raw WER / CER (Noktalama ve büyük/küçük harf dahil)
- Gecikme Süresi (Latency) [saniye]
- Türkçe Özel Karakter Koruma Oranı (ç, ğ, ı, ö, ş, ü)
"""

import os
import re
import sys
import time
import json
import string
import argparse
from typing import Dict, List, Any, Optional

try:
    import jiwer
except ImportError:
    print("jiwer kütüphanesi eksik. Lütfen 'pip install jiwer' çalıştırın.")
    sys.exit(1)

def load_env_file(filepath: str = ".env"):
    """Basit bir .env yükleyici."""
    if not os.path.exists(filepath):
        return
    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            key = key.strip()
            val = val.strip().strip("'\"")
            if key not in os.environ:
                os.environ[key] = val

def turkish_lower(text: str) -> str:
    """Türkçe büyük/küçük harf kurallarına uygun küçültme (I -> ı, İ -> i)."""
    trans = str.maketrans({"I": "ı", "İ": "i"})
    return text.translate(trans).lower()

def normalize_turkish_text(text: str) -> str:
    """Benchmark için metni standartlaştırır (noktalamaları ve fazla boşlukları temizler)."""
    text = turkish_lower(text)
    # Noktalama işaretlerini boşlukla değiştir
    for ch in string.punctuation + "’‘“”«»…–—":
        text = text.replace(ch, " ")
    # Birden fazla boşluğu tek boşluğa indir
    text = re.sub(r"\s+", " ", text).strip()
    return text

def calculate_turkish_char_recall(ref: str, hyp: str) -> float:
    """Referans metindeki Türkçe karakterlerin (ç, ğ, ı, ö, ş, ü) hipotezde bulunma oranını ölçer."""
    tr_chars = set("çğıöşü")
    ref_counts = {c: ref.count(c) for c in tr_chars if ref.count(c) > 0}
    if not ref_counts:
        return 100.0
    
    hyp_counts = {c: hyp.count(c) for c in tr_chars}
    matched = 0
    total = 0
    for c, count in ref_counts.items():
        total += count
        matched += min(count, hyp_counts.get(c, 0))
        
    return (matched / total) * 100.0 if total > 0 else 100.0

class TranscriptionRunner:
    def __init__(self, groq_key: Optional[str] = None, gemini_key: Optional[str] = None):
        self.groq_key = groq_key or os.environ.get("GROQ_API_KEY")
        self.gemini_key = gemini_key or os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
        
        self.groq_client = None
        self.gemini_client = None
        
        if self.groq_key:
            try:
                from groq import Groq
                self.groq_client = Groq(api_key=self.groq_key)
            except Exception as e:
                print(f"[Uyarı] Groq istemcisi başlatılamadı: {e}")
                
        if self.gemini_key:
            try:
                from google import genai
                self.gemini_client = genai.Client(api_key=self.gemini_key)
            except Exception as e:
                print(f"[Uyarı] Gemini istemcisi başlatılamadı: {e}")

    def transcribe_groq(self, audio_path: str, model: str = "whisper-large-v3") -> Dict[str, Any]:
        if not self.groq_client:
            return {"error": "GROQ_API_KEY bulunamadı.", "latency": 0, "text": ""}
        
        start_time = time.perf_counter()
        try:
            with open(audio_path, "rb") as f:
                response = self.groq_client.audio.transcriptions.create(
                    file=(os.path.basename(audio_path), f.read()),
                    model=model,
                    language="tr",
                    response_format="verbose_json"
                )
            latency = time.perf_counter() - start_time
            return {
                "text": response.text.strip(),
                "latency": round(latency, 3),
                "duration": getattr(response, "duration", None)
            }
        except Exception as e:
            latency = time.perf_counter() - start_time
            return {"error": str(e), "latency": round(latency, 3), "text": ""}

    def transcribe_gemini(self, audio_path: str, model: str = "gemini-2.5-flash") -> Dict[str, Any]:
        if not self.gemini_client:
            return {"error": "GEMINI_API_KEY bulunamadı.", "latency": 0, "text": ""}
        
        from google.genai import types
        
        prompt = (
            "Sen uzman bir Türkçe ses deşifre (transcription) sistemisin. "
            "Bu ses kaydını dinle ve konuşulanları kelimesi kelimesine, eksiksiz, "
            "doğru Türkçe imla ve noktalama kurallarına uygun şekilde yazıya aktar. "
            "Asla özetleme yapma, yorum veya selamlama ekleme; SADECE konuşulan ham metni yaz."
        )
        
        start_time = time.perf_counter()
        try:
            with open(audio_path, "rb") as f:
                audio_bytes = f.read()
                
            mime_type = "audio/mp3" if audio_path.endswith(".mp3") else "audio/wav"
            
            response = self.gemini_client.models.generate_content(
                model=model,
                contents=[
                    types.Part.from_bytes(data=audio_bytes, mime_type=mime_type),
                    prompt
                ]
            )
            latency = time.perf_counter() - start_time
            raw_text = response.text.strip() if response.text else ""
            return {
                "text": raw_text,
                "latency": round(latency, 3),
                "duration": None
            }
        except Exception as e:
            latency = time.perf_counter() - start_time
            return {"error": str(e), "latency": round(latency, 3), "text": ""}

def evaluate_predictions(ground_truth: str, predicted: str) -> Dict[str, float]:
    """Tahmin ve referans metin arasındaki hata metriklerini hesaplar."""
    if not predicted:
        return {
            "wer_norm": 100.0,
            "cer_norm": 100.0,
            "wer_raw": 100.0,
            "cer_raw": 100.0,
            "tr_char_recall": 0.0
        }
    
    norm_ref = normalize_turkish_text(ground_truth)
    norm_hyp = normalize_turkish_text(predicted)
    
    # Jiwer WER ve CER
    wer_norm = jiwer.wer(norm_ref, norm_hyp) * 100.0
    cer_norm = jiwer.cer(norm_ref, norm_hyp) * 100.0
    
    wer_raw = jiwer.wer(ground_truth, predicted) * 100.0
    cer_raw = jiwer.cer(ground_truth, predicted) * 100.0
    
    tr_char_recall = calculate_turkish_char_recall(norm_ref, norm_hyp)
    
    return {
        "wer_norm": round(wer_norm, 2),
        "cer_norm": round(cer_norm, 2),
        "wer_raw": round(wer_raw, 2),
        "cer_raw": round(cer_raw, 2),
        "tr_char_recall": round(tr_char_recall, 2)
    }

def main():
    parser = argparse.ArgumentParser(description="Groq Whisper vs Gemini Türkçe STT Benchmark")
    parser.add_argument("--groq-key", help="Groq API Key")
    parser.add_argument("--gemini-key", help="Gemini API Key")
    parser.add_argument("--gemini-model", default="gemini-2.5-flash", help="Gemini Model Adı (varsayılan: gemini-2.5-flash)")
    parser.add_argument("--skip-turbo", action="store_true", help="whisper-large-v3-turbo modelini atla")
    parser.add_argument("--audio", help="Belirli bir ses dosyasını doğrudan test et (örn: kayit.mp3)")
    parser.add_argument("--ground-truth", default="", help="--audio için beklenen doğru metin (WER/CER hesaplaması için opsiyonel)")
    args = parser.parse_args()

    load_env_file()

    runner = TranscriptionRunner(groq_key=args.groq_key, gemini_key=args.gemini_key)
    base_dir = os.path.dirname(__file__)

    # Tekil dosya modu veya tam benchmark seti modu
    if args.audio:
        if not os.path.exists(args.audio):
            print(f"Hata: Belirtilen ses dosyası bulunamadı: {args.audio}")
            sys.exit(1)
        samples = [{
            "id": os.path.splitext(os.path.basename(args.audio))[0],
            "category": "Özel Kullanıcı Kaydı",
            "filepath": os.path.abspath(args.audio),
            "ground_truth": args.ground_truth
        }]
    else:
        metadata_path = os.path.join(base_dir, "samples", "samples_metadata.json")
        if not os.path.exists(metadata_path):
            print(f"Hata: {metadata_path} bulunamadı. Lütfen önce 'python3 generate_samples.py' çalıştırın.")
            sys.exit(1)
        with open(metadata_path, "r", encoding="utf-8") as f:
            samples = json.load(f)

    # Modeller listesi
    models_to_test = [
        {"id": "groq_whisper_v3", "name": "Groq Whisper Large v3", "type": "groq", "model_param": "whisper-large-v3"},
    ]
    if not args.skip_turbo:
        models_to_test.append(
            {"id": "groq_whisper_turbo", "name": "Groq Whisper Large v3 Turbo", "type": "groq", "model_param": "whisper-large-v3-turbo"}
        )
    models_to_test.append(
        {"id": "gemini_flash", "name": f"Gemini ({args.gemini_model})", "type": "gemini", "model_param": args.gemini_model}
    )

    print("=" * 80)
    print("      TÜRKÇE SES DEŞİFRE (STT) BENCHMARK PROTOKOLÜ")
    print("=" * 80)
    print(f"Test edilecek örnek sayısı: {len(samples)}")
    print(f"Test edilecek modeller: {', '.join(m['name'] for m in models_to_test)}")
    print(f"Groq API Key Durumu: {'MEVCUT' if runner.groq_key else 'EKSİK'}")
    print(f"Gemini API Key Durumu: {'MEVCUT' if runner.gemini_key else 'EKSİK'}")
    print("=" * 80)

    if not runner.groq_key and not runner.gemini_key:
        print("\n[DİKKAT] Ne GROQ_API_KEY ne de GEMINI_API_KEY tanımlı değil!")
        print("Lütfen .env dosyasını doldurun veya komut satırından anahtarları verin:")
        print("  python3 run_benchmark.py --groq-key gsk_... --gemini-key AIza...")
        print("\nÖrnek .env şablonu için: cp .env.example .env")
        sys.exit(1)

    results_by_model: Dict[str, List[Dict[str, Any]]] = {m["id"]: [] for m in models_to_test}

    for sample in samples:
        print(f"\n➔ Test Örneği: [{sample['id']}] - {sample['category']}")
        print(f"  Referans: \"{sample['ground_truth']}\"")
        audio_path = sample["filepath"]
        
        for m in models_to_test:
            m_id = m["id"]
            m_name = m["name"]
            print(f"   Çalıştırılıyor: {m_name}...", end=" ", flush=True)
            
            if m["type"] == "groq":
                resp = runner.transcribe_groq(audio_path, model=m["model_param"])
            else:
                resp = runner.transcribe_gemini(audio_path, model=m["model_param"])
                
            if "error" in resp:
                print(f"HATA: {resp['error']}")
                metrics = evaluate_predictions(sample["ground_truth"], "")
            else:
                print(f"Tamamlandı ({resp['latency']} sn)")
                print(f"   Transkript: \"{resp['text']}\"")
                metrics = evaluate_predictions(sample["ground_truth"], resp["text"])
                print(f"   Normalized WER: %{metrics['wer_norm']} | CER: %{metrics['cer_norm']} | TR Karakter Başarımı: %{metrics['tr_char_recall']}")

            results_by_model[m_id].append({
                "sample_id": sample["id"],
                "category": sample["category"],
                "ground_truth": sample["ground_truth"],
                "predicted": resp.get("text", ""),
                "latency": resp.get("latency", 0),
                "error": resp.get("error", None),
                "metrics": metrics
            })

    # Özet ve Raporlama
    output_dir = os.path.join(base_dir, "benchmark_results")
    os.makedirs(output_dir, exist_ok=True)
    
    summary_data = []
    print("\n" + "=" * 85)
    print(f"{'Model':<30} | {'Ort. WER':<10} | {'Ort. CER':<10} | {'TR Karakter':<12} | {'Ort. Süre':<10}")
    print("-" * 85)
    
    for m in models_to_test:
        m_id = m["id"]
        res_list = results_by_model[m_id]
        valid_res = [r for r in res_list if r["error"] is None]
        
        if not valid_res:
            print(f"{m['name']:<30} | {'N/A (Hata)':<10} | {'N/A':<10} | {'N/A':<12} | {'N/A':<10}")
            continue
            
        avg_wer = sum(r["metrics"]["wer_norm"] for r in valid_res) / len(valid_res)
        avg_cer = sum(r["metrics"]["cer_norm"] for r in valid_res) / len(valid_res)
        avg_tr = sum(r["metrics"]["tr_char_recall"] for r in valid_res) / len(valid_res)
        avg_lat = sum(r["latency"] for r in valid_res) / len(valid_res)
        
        print(f"{m['name']:<30} | %{avg_wer:<9.2f} | %{avg_cer:<9.2f} | %{avg_tr:<11.2f} | {avg_lat:<8.2f} sn")
        
        summary_data.append({
            "model": m["name"],
            "model_id": m["id"],
            "avg_wer": round(avg_wer, 2),
            "avg_cer": round(avg_cer, 2),
            "avg_tr_recall": round(avg_tr, 2),
            "avg_latency": round(avg_lat, 2),
            "details": res_list
        })
    print("=" * 85)

    # JSON Çıktısı
    json_path = os.path.join(output_dir, "benchmark_results.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(summary_data, f, ensure_ascii=False, indent=2)

    # Markdown Raporu
    md_path = os.path.join(output_dir, "benchmark_report.md")
    with open(md_path, "w", encoding="utf-8") as f:
        f.write("# Türkçe Ses Deşifre (Speech-to-Text) Benchmark Raporu\n\n")
        f.write("Bu rapor, **Groq Whisper** ve **Google Gemini** modellerinin Türkçe konuşma tanıma başarımını karşılaştırır.\n\n")
        f.write("## Özet Tablo\n\n")
        f.write("| Model | Ortalama WER (%) | Ortalama CER (%) | TR Karakter İsabeti (%) | Ortalama Süre (sn) |\n")
        f.write("|---|---|---|---|---|\n")
        for s in summary_data:
            f.write(f"| {s['model']} | %{s['avg_wer']} | %{s['avg_cer']} | %{s['avg_tr_recall']} | {s['avg_latency']} sn |\n")
            
        f.write("\n## Detaylı Karşılaştırmalar\n\n")
        for s_idx, sample in enumerate(samples):
            f.write(f"### {sample['category']} (`{sample['id']}`)\n\n")
            f.write(f"- **Referans (Ground Truth):** \"{sample['ground_truth']}\"\n\n")
            for m in models_to_test:
                m_id = m["id"]
                rec = results_by_model[m_id][s_idx]
                if rec["error"]:
                    f.write(f"- **{m['name']}:** HATA: {rec['error']}\n")
                else:
                    f.write(f"- **{m['name']}** ({rec['latency']} sn):\n")
                    f.write(f"  - Deşifre: \"{rec['predicted']}\"\n")
                    f.write(f"  - WER: %{rec['metrics']['wer_norm']} | CER: %{rec['metrics']['cer_norm']} | TR Harf: %{rec['metrics']['tr_char_recall']}\n\n")

    print(f"\nRapor başarıyla kaydedildi: {md_path}")
    print(f"JSON verisi: {json_path}")

if __name__ == "__main__":
    main()
