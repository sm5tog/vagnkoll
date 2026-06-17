# Vagnkoll — Tekniska beslut och projektöversikt

Lever-dokument med viktiga beslut och deras motivering, så att projektet kan plockas upp snabbt i nya samtal.

## Syfte

Always-on display i husvagn som visar Victron-batteristatus (SoC, V, A, sol-effekt, larm). Körs på en dedikerad Honor 9 (Android 9, arm64). iPhone-användare har även fjärråtkomst via webbgränssnitt + Tailscale.

## Hårdvara

- **Display:** Honor 9 (Honor 9 STF-L09), Android 9 / EMUI 9, arm64-v8a
- **Victron-enheter:** SmartShunt 500A/50mV + SmartSolar MPPT 75/15 (med inbyggd BLE)
- **Batteri:** 150 Ah LiFePO4
- **Sol:** Max 160 W
- **Inverter:** 12V → 230V, idle ~0.5 A

## Tech stack

- **Flutter 3.29** (Dart), bygger för Android arm64
- **flutter_blue_plus** för BLE-advertisement-lyssning (passiv, ingen GATT-anslutning)
- **cryptography** för AES-CTR-dekryptering av Victron Instant Readout
- **sqflite** för historik och apparatbibliotek
- **shelf** för inbäddad HTTP-server (port 8080)
- **flutter_foreground_task** för background drift
- **shared_preferences** för EnergyCounter och Classifier-state
- **fl_chart** för grafer

## Byggsystem

- **GitHub Actions** bygger APK vid varje push
- Bygget tar ~3-5 min med full cache
- Cacheas: Gradle-paket, Pub-paket, Android SDK/NDK, Flutter .dart_tool
- `--split-per-abi` → bygger en APK per arkitektur; bara arm64 packas ut
- **Signering via GitHub Secrets**: KEYSTORE_BASE64, KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD
- Workflow patchar `flutter create`-genererade gradle-filer för Kotlin 2.1.0 och release-signering
- Tidsstämpel i Stockholm-tid via `TZ='Europe/Stockholm'`

## Arkitektur — översikt

```
HomeScreen (main.dart)
  ├── VictronScanner (BLE → VictronState stream)
  │     • Watchdog: starta om scan om inga paket på 20 sek
  │     • Parsar shunt + solar separat, behåller egna timestamps
  ├── EnergyCounter (integrerar Ah använt/laddat över dygn)
  ├── HistoryStore (SQLite, samplar var 10 sek, tunnas ut)
  ├── ApplianceStore (apparatbibliotek)
  ├── Classifier (matchar last mot apparater, subset matching)
  ├── AlarmEngine (SoC, inverter idle, hög förbrukning, apparat-varningar)
  ├── WebServer (HTTP på port 8080, auto-refresh 3s)
  └── ForegroundService (håller Android från att stänga ner appen)
```

## Viktiga designbeslut

### 1. BLE advertisement lyssning (inte GATT)

**Beslut:** Lyssna passivt på Victron Instant Readout-advertisements istället för att ansluta via GATT.

**Varför:**
- Konfliktar inte med VictronConnect (som tar GATT-slot)
- Lägre batteridrift
- Enklare kod

**Pris:** ~1 Hz sample rate (fundamentalt). Kan inte fånga snabba transienter som inrush-spikar.

### 2. Apparatidentifiering — TRÖSKEL-baserad, inte vågforms-baserad

**Beslut:** Apparater identifieras via förväntad effekt (W) + tolerans (%) + min varaktighet (s). Subset-matching över alla kombinationer.

**Varför:**
- Vågforms-baserad identifiering med Pearson-korrelation testades men gav inkonsekventa resultat pga BLE 1Hz sample rate (kunde inte fånga inrush-detaljer)
- Tröskel-baserad är enklare, mer förutsägbar och tillräcklig för användarens behov (skilja på t.ex. kaffe 970W från golvvärme 1500W)
- Kräver att användaren manuellt fyller i förväntad effekt (eller "Mät nu (5 sek)" som genväg)

### 3. Solar smoothing i klassificerare

**Beslut:** Solar och shunt utjämnas SEPARAT över 5 sek innan last beräknas.

**Varför:** Solar-paket och shunt-paket kommer i olika takt. Om solar uppdateras före shunt blir momentan last (solar - shunt) tillfälligt fel → falsklarm. Separat utjämning eliminerar timing-mismatch.

### 4. Foreground Service

**Beslut:** Använder `flutter_foreground_task` med minimal TaskHandler.

**Varför:** Användaren vill kunna **låsa telefonen** (säkerhet om stulen) utan att appen stannar. Foreground service hindrar Android från att pausa BLE-stream + webbserver i bakgrunden.

### 5. Hamilton-prioritering

**Beslut:** Under träning pausas Classifier, EnergyCounter, HistoryStore och telemetri-timer.

**Varför:** Honor 9 (Android 9) har begränsade resurser. Att alla system kör samtidigt orsakade lagg som störde 1Hz-samplingen. Endast BLE-stream + Trainer's captureTimer + tickFn körs under inspelning.

### 6. Persistent aktiv apparat-set

**Beslut:** `_activeIds` lagras i SharedPreferences.

**Varför:** App-omstart eller bakgrund-paus bör inte glömma vad som är "på". Aktiva apparater består tills classifier ser dem upphöra.

## Historik av övergivna spår

### Vågforms-baserad signatur med Pearson-korrelation

Implementerades fullt ut (3-cyklers ON/OFF-träning, on_trace + off_trace lagring, Pearson-matchning vid live-event). Övergavs eftersom:
- 1 Hz BLE sample rate räcker inte för inrush-fångst
- Solar-transienter under inspelning förstörde signaturen
- Användaren såg att resultaten var inkonsekventa

Ersattes med enkel tröskel-modell.

### Manuella commits via GitHub-webben

Användaren råkade använda Copilot via fel chat-flik och fick instruktioner om `--split-per-abi`. **Sparat i memory: ge aldrig instruktioner att redigera kod manuellt — jag har Edit/Write/Bash-verktyg.**

## GitHub-konto och repo

- **Repo:** https://github.com/sm5tog/vagnkoll (privat)
- **Användare:** sm5tog
- **Signing key:** En PKCS12-keystore. Samma lösenord för store och key (PKCS12-krav). Lagrad som KEYSTORE_BASE64 secret.

## Tailscale

- Användaren har Tailscale-konto (privaterelay Apple ID)
- Honor 9 har Tailscale-IP: **100.70.195.29**
- iPhone också ansluten
- Webbservern nås från iPhone: `http://100.70.195.29:8080`

## TODO inför release (kanonisk lista)

Detta är **den enda** TODO-listan. Övriga filer (PROMPT.md, README.md) ska peka hit.

### Blockers (måste fixas före release)
1. **Setup-skärm** — BLE-skanning, lista Victron-enheter, klistra in encryption keys, batterikapacitet/sol-max/larmtrösklar, spara i SharedPreferences. Ersätter hårdkodad `secrets.dart`.
2. **Onboarding-guide** — in-app steg-för-steg med skärmbilder för var i VictronConnect encryption keys finns.
3. **Översätta hela appen till engelska** — UI-strängar är på svenska idag.

### Bör finnas vid launch
4. Verifiera mörkt tema genomgående (särskilt webvyn).
5. Play Store-material — beskrivning EN+SV, skärmbilder, 30-sek skärminspelning.
6. Privacy Policy-URL (krävs av Google för BLE-appar).
7. README med komplett installationsguide — bygg, EMUI-inställningar (Skyddade appar, batterioptimering), Tailscale-setup.

### v1.1
8. Widget/notifikation med SoC på låsskärmen.
9. Exportera historik som CSV.
10. Konfigurerbar refresh-rate på webservern.
11. MagicDNS för Tailscale (`http://husvagnen:8080`).
12. iOS-build verifierad.

### Övrigt
13. Uppdateringsstrategi för always-on display-enhet.
14. AAB-build för Play Store (inte bara APK).

## Användarspecifika preferenser

Se `~/.claude/projects/C--claude/memory/MEMORY.md` för:
- "r" för roger (radio-amatör SM5TOG)
- Ett steg i taget vid sammansatta instruktioner (stressrelaterad arbetsskada)
- Diskutera UI-ändringar innan push
- Aldrig manuella kod-redigeringar
- Tekniskt: van vid BASIC/Pascal/asm/Comal från 80/90-talet, nybörjare på modernt ekosystem

## Aktuell statuslag (när detta skrivs)

Allt grundläggande är klart och fungerar. Återstår: dokumentation + finputs efter morgondagens test.
