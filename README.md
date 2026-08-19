# Talkey — Windows için konuşmayı yazıya çeviren kısayol

Bir tuşa bas, konuş, aynı tuşa tekrar bas. Söylediklerin panoya metin olarak
girer, `Ctrl+V` ile istediğin yere yapıştırırsın.

- **F8** — Türkçe
- **F9** — İngilizce

Her şey kendi bilgisayarında çalışır. Ses hiçbir yere gönderilmez, internet
yalnızca ilk kurulumda model indirilirken gerekir.

## Kurulum

1. Zip'i bir klasöre çıkart.
2. O klasörde adres çubuğuna `powershell` yazıp Enter'a bas, sonra:
   ```
   powershell -ExecutionPolicy Bypass -File install.ps1
   ```
   İnternetten indirilen `.ps1` dosyaları Windows tarafından işaretlenir ve
   sağ tık → "Run with PowerShell" varsayılan ayarlarda reddedilir; yukarıdaki
   komut bunu aşar. (Alternatif: zip'e sağ tık → Özellikler → **Engellemeyi
   kaldır** işaretle, sonra çıkart ve sağ tık → Run with PowerShell.)
3. Kurucu sırayla mikrofonu ve model boyutunu sorar. İkisinde de Enter'a basıp
   varsayılanı seçebilirsin.

Kurucu, eksikse Python 3 ve AutoHotkey v2'yi `winget` ile kurar, dosyaları
`%LOCALAPPDATA%\Talkey` altına kopyalar, izole bir Python ortamı hazırlar ve
sistemi Windows açılışına ekler. Yönetici hakkı gerekmez.

İlk kurulumda model indirilir (medium için ~1.5 GB), bu birkaç dakika sürer.
Sonraki açılışlarda indirme yok.

## Kullanım

| Ne | Nasıl |
|---|---|
| Türkçe talkey | `F8` → konuş → `F8` |
| İngilizce talkey | `F9` → konuş → `F9` |
| Metni yapıştır | `Ctrl+V` |
| Son metni tekrar kopyala | Tepsi ikonu → "Son metni kopyala" |
| Kapat | Tepsi ikonu → "Çıkış" |

Ekranın köşesinde küçük bir baloncuk durumu gösterir: `dinliyorum` → `yazıya
çevriliyor…` → `Panoda`.

Metin **yalnızca panoya** yazılır, hiçbir pencereye kendiliğinden yazılmaz.
Yanlış pencereye yazma riski yok.

## Ayarlar

`%LOCALAPPDATA%\Talkey\config.ini`

| Anahtar | Ne işe yarar |
|---|---|
| `[audio] device` | Mikrofon. Boş = Windows varsayılanı. Cihaz adının bir parçası yeterli. |
| `[audio] max_seconds` | Durdurmayı unutursan kayıt bu süre sonunda kendi biter. |
| `[whisper] model` | `small`, `medium`, `large-v3`. Büyüdükçe daha doğru, daha yavaş. |
| `[whisper] compute` | `auto`, `cpu`, `cuda:float16`. Kurucu bunu senin makinene göre ayarlar. |
| `[lang] primary` / `secondary` | İki tuşun dilleri (`tr`, `en`, `de`, `fr`, …). |
| `[hotkeys] primary` / `secondary` | Kısayol tuşları. `F8`, `F9`, `^!d` (Ctrl+Alt+D) gibi. |
| `[daemon] idle_unload` | Model bu kadar saniye kullanılmazsa RAM'den düşer. |

Değişiklikten sonra:

- `[whisper]` veya `[daemon]` değiştiyse → tepsi ikonu → **Daemon'ı yeniden başlat**
- `[hotkeys]`, `[lang]` veya `[audio]` değiştiyse → tepsi ikonu → **Çıkış**, sonra
  Başlat menüsünden `Talkey` kısayolunu tekrar çalıştır (veya bilgisayarı yeniden başlat)

## Nasıl çalışıyor

```
F8  ──▶ dictate.ahk ──▶ dictate-record.py   (mikrofon → 16 kHz mono WAV)
                             │
F8  ──▶ dictate.ahk ─────────┘ dur
         │
         └─▶ dictate-client.py ──TCP 127.0.0.1──▶ dictate-daemon.py
                                                    (faster-whisper, model RAM'de)
         ◀────────────── metin ──────────────────────┘
         │
         └─▶ pano
```

Model arka planda bir "daemon" içinde açık durur; her talkey için baştan
yüklenmez, bu yüzden çeviri birkaç saniyede biter. Uzun süre kullanılmazsa
kendini RAM'den düşürür, sonraki kullanımda geri yükler.

Kayıt, işlemi öldürerek değil bir "dur" dosyası bırakılarak sonlandırılır —
böylece WAV başlığı her zaman düzgün kapanır ve bozuk/yarım kayıt oluşmaz.

## Sorun giderme

**Hiçbir şey olmuyor, tepsi ikonu da yok**
Başlat menüsünde `shell:startup` yazıp Enter'a bas, `Talkey.lnk` orada mı bak.
Yoksa `install.ps1` dosyasını tekrar çalıştır.

**"Mikrofon açılamadı"**
`%LOCALAPPDATA%\Talkey\record.log` dosyasına bak. Genelde Windows'un mikrofon
gizlilik izni kapalıdır: Ayarlar → Gizlilik ve güvenlik → Mikrofon → "Masaüstü
uygulamalarının mikrofona erişmesine izin ver" açık olmalı.

**Yanlış mikrofon dinleniyor**
`config.ini` içinde `[audio] device` satırına cihaz adının bir parçasını yaz.
Cihaz listesini görmek için:
```
%LOCALAPPDATA%\Talkey\venv\Scripts\python.exe %LOCALAPPDATA%\Talkey\dictate-record.py --list
```

**"Daemon başlatılamadı"**
`%LOCALAPPDATA%\Talkey\daemon.log` dosyasına bak. `cudnn` / `cublas` hatası
görürsen `config.ini` içinde `compute = cpu` yap ve daemon'ı yeniden başlat.

**Çeviri çok yavaş**
`config.ini` içinde `model = small` yap, daemon'ı yeniden başlat. Ayrıca ilk
talkey, model yüklenirken her zaman yavaştır; sonrakiler hızlıdır.

**F8 başka bir programda çalışıyor**
`config.ini` içinde `[hotkeys] primary` değerini değiştir, örneğin `^!d`
(Ctrl+Alt+D). `^` = Ctrl, `!` = Alt, `+` = Shift, `#` = Win.

## Kaldırma

`%LOCALAPPDATA%\Talkey\uninstall.ps1` → sağ tık → Run with PowerShell.
İndirilen modelleri ve kurulum klasörünü silmeyi ayrı ayrı sorar; Python ile
AutoHotkey'e dokunmaz.
