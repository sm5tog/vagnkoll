# Vagnkoll — instruktioner för Claude

Ärver globala regler från `C:\claude\CLAUDE.md`. Denna fil innehåller endast projektspecifikt.

Flutter-app, always-on display för husvagn som visar Victron BLE-batteristatus (SmartShunt + SmartSolar).

**Eget git-repo, privat:** https://github.com/sm5tog/vagnkoll

## Projektspecifika regler

1. **Läs `BESLUT.md` och `PROMPT.md` FÖRST** vid uppstart i ny tråd — de har fullständig design/kontext/spec. Duplicera inte innehåll hit.
2. **TODO finns bara på ETT ställe:** `BESLUT.md` under "TODO inför release". Skapa inte en parallell TODO-lista.
3. **Ambitionsnivå:** bisyssla, inte B2B. Vid avvägning mellan "perfekt polish" och "klart nog att skeppa" — välj det senare. Föreslå inte tunga professionella vägval (komplex CI, juridik, partneravtal).
4. **Bakåtkompatibilitet:** Honor 9 kör Android 9 — vissa Android 12+ API:er är inte tillgängliga.
5. **Bygge:** GitHub Actions, signering via Secrets, arm64-only APK.

## Körkataloger
- Källkod: `C:\claude\git\vagnkoll\lib\`
