#!/usr/bin/env bash
# install.sh - macOS Voice Typing Kurulum ve Otomatik Başlatma Betiği
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="${1:-VoiceTyping}"
case "$APP_NAME" in
    ''|*[!a-zA-Z0-9_-]*) echo "Invalid app name" >&2; exit 1 ;;
esac
TARGET_APP="/Applications/${APP_NAME}.app"

echo "============================================================"
echo "📦 macOS Voice Typing Kurulumu Başlatılıyor..."
echo "📍 Hedef: $TARGET_APP"
echo "============================================================"

# 1. En son sürümü derle
echo "🔨 1/5. Native Swift binary ve .app paketi derleniyor..."
./build.sh

# 2. Çalışan eski süreçleri durdur
echo "🛑 2/5. Varsa önceki süreçler durduruluyor..."
launchctl unload "$HOME/Library/LaunchAgents/com.antigravity.VoiceTyping.plist" 2>/dev/null || true
# Never trust a stale PID file or terminate an unrelated process by name.
python3 - "$TARGET_APP" <<'PY_STOP'
import ctypes, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path.cwd()
allowed = {str(p.resolve()) for p in [
    pathlib.Path(sys.argv[1]) / "Contents/MacOS/VoiceTyping",
    pathlib.Path("/Applications/VoiceTyping.app/Contents/MacOS/VoiceTyping"),
    root / "VoiceTyping", root / "VoiceTyping.app/Contents/MacOS/VoiceTyping",
    root / ".build/release/VoiceTyping", root / ".build/debug/VoiceTyping",
]}
libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
def executable(pid):
    buf = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, buf, len(buf)) <= 0:
        return None
    return os.path.realpath(os.fsdecode(buf.value))
result = subprocess.run(["pgrep", "-x", "VoiceTyping"], capture_output=True, text=True)
for pid in map(int, result.stdout.split()):
    path = executable(pid)
    if path not in allowed:
        print(f"Leaving unrecognized VoiceTyping PID {pid} untouched")
        continue
    print(f"Stopping VoiceTyping PID {pid}: {path}")
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        continue
    for _ in range(50):
        if executable(pid) != path:
            break
        time.sleep(0.1)
    else:
        raise SystemExit("VoiceTyping did not exit; installation aborted safely")
PY_STOP

# 3. /Applications dizinine yükle
echo "📁 3/5. Uygulama /Applications klasörüne kopyalanıyor..."
rm -rf "$TARGET_APP"
cp -R VoiceTyping.app "$TARGET_APP"

# Eski sürümlerden kalan giriş yöntemini temizle (artık kullanılmıyor).
pkill -x VoiceTypingIME 2>/dev/null || true
rm -rf "$HOME/Library/Input Methods/VoiceTypingIME.app" "$HOME/.voice_typing/ime_token"

# Eğer özel isim verildiyse Info.plist içindeki isimleri güncelle
if [ "$APP_NAME" != "VoiceTyping" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true
fi

# 4. Güvenlik imzası uygula (macOS TCC izinlerinin yeniden derlemede kaybolmaması için sabit kimlik kullanılır)
echo "🔏 4/5. Güvenlik imzası uygulanıyor (codesign)..."
# SABİT KİMLİKLE İMZALA — her kurulumda, koşulsuz.
#
# Neden: macOS TCC izinlerini (Erişilebilirlik, Girdi İzleme, Konuşma Tanıma)
# imzaya bağlar. Ad-hoc imzada (`--sign -`) imza özeti binary her değiştiğinde
# değişir; bu yüzden her yeniden kurulum kullanıcının VERDİĞİ izinleri sessizce
# sıfırlar ve uygulama bir daha kısayolu duymaz. Sabit sertifika bu özeti
# korur, böylece izin bir kez verilir ve sonraki kurulumlarda ayakta kalır.
SIGN_IDENTITY="VoiceTyping Local Certificate"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$TARGET_APP" \
        || { echo "❌ Sabit sertifika ile imzalama başarısız."; exit 1; }
else
    # Sertifika yoksa ad-hoc imzaya düş ama kullanıcıyı UYAR: izinler
    # her kurulumda sıfırlanacaktır.
    echo "⚠️  '$SIGN_IDENTITY' bulunamadı; geçici (ad-hoc) imza kullanılıyor."
    echo "    Bu durumda macOS izinleri her kurulumda sıfırlanır."
    echo "    Kalıcı izin için README'deki sertifika adımını uygulayın."
    codesign --force --deep --sign - "$TARGET_APP"
fi
codesign --verify --deep --strict "$TARGET_APP"
plutil -lint "$TARGET_APP/Contents/Info.plist"

# macOS LaunchServices önbelleğini yenile (LSUIElement / Dinamik Dock için)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP" 2>/dev/null || true

# 4.5. Kullanıcı yapılandırmasını ve API anahtarlarını otomatik aktar / koru
echo "🔑 4.5/5. API anahtarları ve kullanıcı yapılandırması kontrol ediliyor..."
USER_CONFIG_DIR="$HOME/.voice_typing"
mkdir -p "$USER_CONFIG_DIR"

python3 - << 'PY_EOF'
import json
import os

user_cfg = os.path.expanduser("~/.voice_typing/config.json")
legacy_cfg = os.path.expanduser("~/.voice_typing_config.json")
project_cfg = os.path.abspath("config.json")
project_env = os.path.abspath(".env")

data = {}

if os.path.exists(user_cfg):
    try:
        with open(user_cfg, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        pass

if not data and os.path.exists(legacy_cfg):
    try:
        with open(legacy_cfg, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        pass

if os.path.exists(project_cfg):
    try:
        with open(project_cfg, "r", encoding="utf-8") as f:
            pdata = json.load(f)
            if not data:
                data = pdata
            else:
                for k in ["groq_api_key", "gemini_api_key", "assemblyai_api_key", "provider", "gemini_model", "groq_model"]:
                    if not data.get(k) and pdata.get(k):
                        data[k] = pdata[k]
    except Exception:
        pass

if os.path.exists(project_env):
    try:
        with open(project_env, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("GROQ_API_KEY=") and not data.get("groq_api_key"):
                    data["groq_api_key"] = line.split("=", 1)[1].strip("\"' ")
                elif line.startswith("GEMINI_API_KEY=") and not data.get("gemini_api_key"):
                    data["gemini_api_key"] = line.split("=", 1)[1].strip("\"' ")
                elif line.startswith("ASSEMBLYAI_API_KEY=") and not data.get("assemblyai_api_key"):
                    data["assemblyai_api_key"] = line.split("=", 1)[1].strip("\"' ")
    except Exception:
        pass

if data:
    data.pop("openai_api_key", None)
    data.pop("openai_model", None)
    if data.get("provider") == "openai":
        data["provider"] = "apple"
    with open(user_cfg, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    with open(legacy_cfg, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    groq_ok = "✅" if data.get("groq_api_key") else "⚪"
    gemini_ok = "✅" if data.get("gemini_api_key") else "⚪"
    assembly_ok = "✅" if data.get("assemblyai_api_key") else "⚪"
    print(f"   ➔ API Anahtarları korundu ve eşitlendi (Groq: {groq_ok}, Gemini: {gemini_ok}, AssemblyAI: {assembly_ok})")

# API anahtarlarının bulunduğu dosyaları yalnızca kullanıcı hesabına aç.
for protected_path in (user_cfg, legacy_cfg):
    if os.path.exists(protected_path):
        try:
            os.chmod(protected_path, 0o600)
        except OSError:
            pass
PY_EOF

# 5. LaunchAgent oluştur (Mac açıldığında otomatik başlama)
echo "🚀 5/5. Başlangıçta otomatik çalışma (LaunchAgent) yapılandırılıyor..."
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/com.antigravity.VoiceTyping.plist"
mkdir -p "$LAUNCH_AGENT_DIR"

# Eski servis varsa kaldır
launchctl unload "$LAUNCH_AGENT_PLIST" 2>/dev/null || true

cat <<PLIST_EOF > "$LAUNCH_AGENT_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.antigravity.VoiceTyping</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TARGET_APP/Contents/MacOS/VoiceTyping</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Uygulama kasıtlı olarak kapatılmadığı sürece çökme sonrası geri gelmelidir.
         SuccessfulExit=false: yalnızca hatalı çıkışta yeniden başlat, temiz çıkışta başlatma. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <!-- Teşhis logu: yalnızca bu kullanıcının okuyabildiği ~/.voice_typing altında. -->
    <key>StandardOutPath</key>
    <string>$HOME/.voice_typing/app.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.voice_typing/app.log</string>
</dict>
</plist>
PLIST_EOF

# Servisi yükle (Mac açıldığında otomatik çalışması için)
plutil -lint "$LAUNCH_AGENT_PLIST"
launchctl load "$LAUNCH_AGENT_PLIST"

# Başlatılan servisi göster; sessizce başka bir kopyayı açma.
sleep 0.5
launchctl list com.antigravity.VoiceTyping

echo ""
echo "============================================================"
echo "🎉 Kurulum Başarıyla Tamamlandı!"
echo "📍 Konum: $TARGET_APP"
echo "🚀 Durum: Uygulama başlatıldı ve menü çubuğuna yerleşti."
echo "🔄 Otomatik Başlatma: Mac her açıldığında arka planda otomatik çalışacak."
echo "⌨️ Kullanım: Herhangi bir metin alanında Sağ Command (⌘) tuşuna basılı tutup konuşun!"
echo "============================================================"
