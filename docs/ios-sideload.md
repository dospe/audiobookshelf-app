# iOS build pro vlastní telefon (free Apple ID + SideStore)

Aplikace se pro iOS staví v GitHub Actions (`.github/workflows/build-ios.yml`)
jako **nepodepsaný IPA**. Podpis a jeho týdenní obnova probíhá až na telefonu
přes SideStore, takže není potřeba placený Apple Developer Program ani Mac
pro každou instalaci. Placený účet by umožnil TestFlight; s free Apple ID je
sideload jediná cesta.

## Co build umí

- Čtečka e-knih včetně **nativního předčítání** (`AbsTTSPlayer.swift`,
  `Shared/player/TTSPlayer.swift`): systémové hlasy (AVSpeechSynthesizer),
  čtení pokračuje se zhasnutou obrazovkou, ovládání ze zamykací obrazovky,
  Control Center, sluchátek a z obrazovky „Právě hraje“ v CarPlay.
- Synchronizace pozice čtení (lokální databáze + server) stejně jako na
  Androidu.
- Výběr hlasu v nastavení předčítání (hlasy se stahují v Nastavení →
  Zpřístupnění → Předčítaný obsah → Hlasy). Výběr enginu na iOS není —
  systém má jen jeden.

Co build **neumí** a nebude: browse a spouštění knih z CarPlay (Android Auto
strom se nepřenáší). CarPlay audio aplikace potřebuje entitlement od Apple,
který se uděluje jen placenému účtu po žádosti, a sideloadovaný build ho
nést nemůže. „Právě hraje“ v CarPlay ale funguje pro cokoli, co telefon právě
přehrává — tedy i pro rozjeté předčítání (play/pause, skok o stránky).

## Kde vzít IPA

- Každý push do `master` vytvoří pre-release **`latest-ios`** s IPA souborem
  (stejně jako `latest` pro Android APK). Stránku releases lze otevřít
  v Safari na telefonu a IPA stáhnout přímo.
- Každý push/PR na jakékoli větvi navíc nahraje IPA jako artefakt workflow
  (`audiobookshelf-ipa`), pro ověření větve před mergem.

Runner `macos-15` je na veřejném repozitáři zdarma; build trvá ~15–25 minut
(hlavně kompilace Realm podu).

## Jednorázová příprava telefonu

1. **SideStore** nainstalovat podle návodu na <https://sidestore.io>:
   jednorázově je potřeba počítač (AltServer na Macu nebo Windows) pro
   instalaci samotného SideStore a vytvoření párovacího souboru. Součástí
   je i instalace StosVPN (lokální VPN, přes kterou SideStore mluví sám
   se sebou při obnově podpisu).
2. Do SideStore přihlásit **free Apple ID** (doporučuje se založit pro tento
   účel samostatné).
3. Zapnout „Background Refresh“ pro SideStore v Nastavení iOS, aby se podpisy
   obnovovaly automaticky.

Alternativa: **AltStore** s AltServerem běžícím na Macu ve stejné Wi‑Fi — obnova
podpisu je také automatická, ale jen když je Mac zapnutý a v dosahu.

## Instalace a aktualizace

1. Na telefonu otevřít release `latest-ios`, stáhnout `audiobookshelf-ios-*.ipa`.
2. V Souborech (Stažené) klepnout na IPA → Sdílet → **SideStore** (nebo
   v SideStore „My Apps“ → „+“ a vybrat soubor).
3. Aktualizace = stejný postup s novým IPA; SideStore přeinstaluje aplikaci
   přes stávající (data zůstávají).

Po instalaci iOS hlásí „nedůvěryhodný vývojář“ jen u instalace přes Xcode;
u SideStore/AltStore není potřeba nic potvrzovat.

## Limity free Apple ID

- Podpis platí **7 dní**; SideStore ho obnovuje na pozadí (nebo ručně
  „Refresh All“). Po vypršení aplikace nejde spustit, dokud se neobnoví —
  data se neztratí.
- Maximálně **3 sideloadované aplikace** současně a 10 App ID za 7 dní
  (SideStore sám počítá jako jedna).
- Sideloadovaná aplikace nemůže mít restricted entitlements (CarPlay,
  push notifikace přes APNs apod.). Background audio je normální
  `UIBackgroundModes`, ten funguje.

## Vlastní build na Macu (bez CI)

```bash
npm ci && npm run generate && npx cap sync ios
open ios/App/App.xcworkspace
```

V Xcode zvolit vlastní tým (free Apple ID) v Signing & Capabilities cíle
`Audiobookshelf`, připojit telefon a spustit. Takový podpis platí také 7 dní
a obnovuje se jen dalším spuštěním z Xcode — pro běžné používání je SideStore
pohodlnější.
