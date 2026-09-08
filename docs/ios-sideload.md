# iOS build pro vlastní iPhone (free Apple ID, SideStore, iloader)

Aplikace se pro iOS staví v GitHub Actions (`.github/workflows/build-ios.yml`)
jako **nepodepsaný IPA**. Podpis dělá až na telefonu **SideStore** vaším
(bezplatným) Apple ID a každý týden ho sám obnovuje. Není potřeba placený Apple
Developer Program ani Mac pro každou instalaci — MacBook je potřeba jen jednou,
k instalaci SideStore.

Postup odpovídá oficiální dokumentaci SideStore (docs.sidestore.io, stav 2026):
instalace přes **iloader**, VPN **LocalDevVPN**. Starší návody s AltServerem,
jitterbugpair, WireGuard nebo StosVPN jsou pro SideStore zastaralé.

Obsah:

1. [Jak to celé funguje](#1-jak-to-celé-funguje)
2. [Co potřebuješ](#2-co-potřebuješ)
3. [Co nainstalovat na MacBook](#3-co-nainstalovat-na-macbook)
4. [Příprava iPhonu](#4-příprava-iphonu)
5. [Instalace SideStore přes iloader](#5-instalace-sidestore-přes-iloader)
6. [Instalace a aktualizace Audiobookshelf](#6-instalace-a-aktualizace-audiobookshelf)
7. [Obnova podpisu (7 dní)](#7-obnova-podpisu-7-dní)
8. [Limity free Apple ID](#8-limity-free-apple-id)
9. [Řešení potíží](#9-řešení-potíží)
10. [Alternativa: AltStore + AltServer na Macu](#10-alternativa-altstore--altserver-na-macu)
11. [Alternativa: build a instalace z Xcode](#11-alternativa-build-a-instalace-z-xcode)
12. [Co dělá CI a „IPA server“ (source feed)](#12-co-dělá-ci-a-ipa-server-source-feed)

## 1. Jak to celé funguje

- **CI** (macOS runner na GitHubu, na veřejném repu zdarma) sestaví z každého
  pushe nepodepsaný `audiobookshelf-ios.ipa`. Push do `master` ho navíc připne
  k pre-release **`latest-ios`** spolu se souborem `sidestore-source.json`
  („source feed“ — seznam aplikací a verzí, kterému SideStore rozumí).
- **SideStore** na iPhonu IPA podepíše vývojářským certifikátem vašeho Apple ID
  a nainstaluje. Certifikát free účtu platí **7 dní**; SideStore ho na pozadí
  obnovuje (potřebuje k tomu zapnutou LocalDevVPN a Wi‑Fi).
- Po přidání source feedu do SideStore vidíte každý nový build z `master`
  jako **Update** a nainstalujete ho jedním klepnutím.
- **iloader** na MacBooku se použije jen jednou: nainstaluje SideStore a uloží
  do telefonu tzv. pairing file (párovací soubor, díky kterému SideStore
  „mluví“ se systémem jako by byl připojený počítač).

Co v iOS buildu je a není:

- Je: čtečka e-knih s **nativním předčítáním** (běží i se zhasnutou obrazovkou,
  ovládání ze zamykací obrazovky, Control Center, sluchátek a obrazovky
  „Právě hraje“ v CarPlay), synchronizace pozice čtení s lokální DB i serverem,
  výběr hlasu (hlasy se stahují v Nastavení → Zpřístupnění → Předčítaný obsah
  → Hlasy). Výběr enginu na iOS není, systém má jen jeden.
- Není a nebude: browse a spouštění knih z CarPlay (Android Auto strom se
  nepřenáší). CarPlay audio aplikace potřebuje entitlement od Apple pro placený
  účet a sideloadovaný build ho nést nemůže.

## 2. Co potřebuješ

| Co | Poznámka |
| --- | --- |
| iPhone s iOS/iPadOS **15.0+** a zapnutým kódem zámku | podle SideStore prerequisites; Developer Mode na iOS 16+ |
| MacBook (macOS High Sierra+) | jen na první instalaci SideStore; ostatní jde bez počítače |
| USB kabel Mac ↔ iPhone | pro iloader při instalaci a při obnově pairing file |
| Apple ID | free účet stačí; SideStore doporučuje **samostatné Apple ID** jen pro sideload (účet se používá jako vývojářský, s hlavním účtem není důvod riskovat) |
| Wi‑Fi | instalace i obnova podpisu vyžadují Wi‑Fi, mobilní data nestačí |
| ~30 minut | první instalace včetně případného řešení potíží |

## 3. Co nainstalovat na MacBook

### 3.1 iloader (nutné)

**iloader** je oficiální instalátor SideStore (projekt idevice / nab138).
Stahujte **jen** z oficiálních míst: <https://iloader.app> nebo
<https://github.com/nab138/iloader/releases> (soubor pro macOS). Jiné weby
nabízející „iloader“ nepoužívat.

1. Stáhnout macOS balíček z releases, otevřít a přetáhnout `iloader` do
   Applications.
2. Při prvním spuštění může macOS hlásit neověřeného vývojáře — povolit
   v Nastavení systému → Soukromí a zabezpečení („Přesto otevřít“).
3. Nic dalšího není potřeba: na macOS není nutný iTunes (zařízení vidí Finder),
   ani žádný nástroj na pairing file — ten obstará iloader.

### 3.2 Volitelně: AltServer

Jen pokud byste místo SideStore chtěli klasický **AltStore** (kapitola 10).
Pro SideStore AltServer **není** potřeba. Ke stažení na <https://altstore.io>;
vyžaduje macOS 11+ (pro macOS 10.14/10.15 verze 1.6.2). Od verze 1.7 už
nepotřebuje Mail plug‑in.

### 3.3 Volitelně: nástroje pro lokální build

Jen pokud chcete IPA stavět sami místo CI (kapitola 11): Xcode z App Store,
Node.js 20 a CocoaPods — postup je v `readme.md` v sekci „Mac Environment
Setup for iOS“ (`brew install node cocoapods`).

## 4. Příprava iPhonu

1. **LocalDevVPN** nainstalovat z App Store (vydavatel Coxson Engineering LLC;
   <https://apps.apple.com/app/id6755608044>). Je to bezplatná aplikace
   s oprávněním na lokální VPN tunel, přes který SideStore instaluje
   a obnovuje aplikace bez počítače.
2. Otevřít LocalDevVPN, klepnout na připojení, povolit přidání VPN konfigurace
   (iOS se zeptá na kód zámku) a **nechat VPN zapnutou** po celou dobu
   instalace, aktualizací a obnovy podpisů.
3. **Režim vývojáře** (iOS 16+): Nastavení → Soukromí a zabezpečení → Režim
   vývojáře → zapnout → telefon se restartuje → potvrdit. Položka se objeví až
   po prvním připojení k iloaderu / instalaci první vývojářské aplikace; pokud
   ji nevidíte, vraťte se k ní po kroku 5.
4. Nastavení → Obecné → Obnovení aplikací na pozadí: povolit (globálně
   a později pro SideStore), jinak se podpisy neobnoví samy.

## 5. Instalace SideStore přes iloader

Na MacBooku:

1. Připojit iPhone kabelem, odemknout ho a na telefonu potvrdit **Důvěřovat
   tomuto počítači** (zadat kód).
2. Spustit **iloader**. Přihlásit se Apple ID (heslo se posílá jen Apple;
   přihlašovací údaje jsou **case‑sensitive**). Při dvoufázovém ověření
   opsat kód z telefonu.
3. Vybrat zařízení a zvolit **Install SideStore (Stable)**. iloader nahraje
   SideStore, zaregistruje App ID a umístí pairing file.
   (Podporu k iloaderu poskytuje Discord projektu idevice, ne SideStore.)

Na iPhonu:

4. Nastavení → Obecné → **VPN a správa zařízení** → pod „Developer App“
   klepnout na své Apple ID → **Důvěřovat**. Na iOS 18+ nabídne „Povolit
   a restartovat“ — potvrdit kódem, telefon se restartuje.
5. Pokud se objevil **Režim vývojáře** (krok 4.3), zapnout ho.
6. Zapnout **LocalDevVPN**.
7. Otevřít **SideStore**, přihlásit se stejným Apple ID jako v iloaderu.
8. Karta **My Apps** → klepnout na počítadlo **„7 DAYS“** u SideStore →
   proběhne první refresh. Když se zeptá na správu certifikátů, potvrdit
   „Yes“ / „Refresh Now“.

Tím je SideStore hotový a Mac už není potřeba (kromě obnovy pairing file po
aktualizaci iOS nebo resetu — kapitola 9).

## 6. Instalace a aktualizace Audiobookshelf

Vždy: zapnutá **LocalDevVPN** a **Wi‑Fi**.

### 6.1 Přes source feed (doporučeno — aktualizace jedním klepnutím)

Feed je soubor `sidestore-source.json` v releasu `latest-ios`:

```
https://github.com/dospe/audiobookshelf-app/releases/download/latest-ios/sidestore-source.json
```

Přidání do SideStore:

- **Jedním odkazem:** v Safari na iPhonu do adresního řádku vložit
  `sidestore://source?url=https://github.com/dospe/audiobookshelf-app/releases/download/latest-ios/sidestore-source.json`
  a potvrdit otevření v SideStore. (Odkaz je i v popisu releasu; GitHub ho
  zobrazuje jako text, proto kopírovat.)
- **Ručně:** SideStore → karta **Browse** → **Sources** (vlevo nahoře) → **+**
  → vložit URL feedu → Add.

Pak: Browse → source „Audiobookshelf (dospe)“ → **Audiobookshelf** →
**Install** (přihlásit Apple ID, chvíli počkat). Aplikace se objeví na ploše.

**Aktualizace:** po každém pushi do `master` CI přepíše release novým buildem
s vyšším číslem verze (`0.13.<číslo běhu>`). SideStore při dalším otevření
(nebo kontrole na pozadí) ukáže **Update** u aplikace (My Apps / Browse) —
klepnout na Update. Data aplikace (přihlášení, stažené knihy, průběh) zůstávají.

### 6.2 Přímý odkaz na IPA

V Safari vložit
`sidestore://install?url=https://github.com/dospe/audiobookshelf-app/releases/download/latest-ios/audiobookshelf-ios.ipa`
— SideStore IPA stáhne a nainstaluje. Aktualizace stejně, s tím rozdílem, že
SideStore o nové verzi sám neví.

### 6.3 Ručně ze souboru

1. V Safari otevřít releases → `latest-ios` → stáhnout `audiobookshelf-ios.ipa`
   (skončí v Soubory → Stažené). Pro build konkrétní větve stáhnout artefakt
   `audiobookshelf-ipa` z běhu workflow (je to zip, uvnitř IPA + feed).
2. SideStore → **My Apps** → **+** (vlevo nahoře) → vybrat IPA v Souborech.
   Nebo v Souborech IPA podržet → Sdílet → **SideStore**.

Instalace přes stávající aplikaci = aktualizace, data zůstávají.

## 7. Obnova podpisu (7 dní)

- Podpis (a tím spustitelnost) vyprší **7 dní** od podepsání. SideStore ho
  obnovuje **na pozadí** — podmínky: LocalDevVPN zapnutá, Wi‑Fi, povolené
  Obnovení aplikací na pozadí, a SideStore občas otevřený (iOS pozadí
  neplánuje spolehlivě, pokud aplikaci dlouho nepustíte).
- **Ručně:** SideStore → My Apps → **Refresh All** (nebo klepnout na počet dní
  u konkrétní aplikace). Doporučuji jednou týdně při otevření SideStore.
- Když podpis **vyprší**: aplikace nejde spustit („Nelze ověřit aplikaci“ /
  ikona ztmavne). Data se **neztrácí** — stačí Refresh v SideStore. Když
  vypršel i SideStore samotný, refresh přes něj nejde: znovu ho nainstalovat
  iloaderem (Install SideStore, bez odinstalace), pak Refresh All.

### 6.4 iPad

Stejný IPA se instaluje i na iPad (projekt cílí na iPhone i iPad, všechny
orientace, Split View / Stage Manager). Rozhraní je telefonní layout roztažený
na šířku; čtečka EPUB zobrazí na širokém displeji dvě stránky vedle sebe
(nastavení čtečky „spread“, výchozí auto). Postup se SideStore je totožný,
iPadOS 15+.

**Dvě zařízení s jedním free Apple ID:** free účet má jediný vývojářský
certifikát. Instalace nebo obnova SideStore na druhém zařízení ho obnoví
a zneplatní podpisy na prvním — aplikace tam nejdou spustit, dokud se znovu
neobnoví, a obě zařízení si mohou certifikát střídavě brát (SideStore issue
#978, AltStore #1597). Nejjednodušší je **samostatné free Apple ID pro každé
zařízení**; každé má pak i vlastní limity z kapitoly 8.

## 8. Limity free Apple ID

| Limit | Dopad |
| --- | --- |
| **3 sideloadované aplikace** současně, **včetně SideStore** | Audiobookshelf + ještě jedna další; LocalDevVPN je z App Store a nepočítá se |
| **10 App ID za 7 dní** | každá (pře)instalovaná aplikace zabere App ID na týden; při „Maximum number of App IDs“ počkat, přehled v My Apps → View App IDs |
| **7 dní** platnost podpisu | kapitola 7 |
| Žádné restricted entitlements | CarPlay, push notifikace přes APNs apod. nejdou; background audio (`UIBackgroundModes`) je běžný režim a funguje |
| Pairing file | nutno obnovit po **aktualizaci iOS nebo resetu**, výjimečně vyprší i sám (kapitola 9) |

## 9. Řešení potíží

- **iloader nevidí iPhone:** odemknout telefon, potvrdit „Důvěřovat“, zkusit
  jiný kabel/port; ve Finderu musí být zařízení vidět.
- **Přihlášení Apple ID selhává v SideStore:** zkontrolovat velikost písmen;
  změnit **Anisette URL** v SideStore → Settings (starší veřejné anisette
  servery způsobovaly zablokování Apple ID, ponechat oficiální). Dvoufázový kód
  se zadává při přihlášení.
- **Refresh / instalace selhává, „minimuxer“ nebo chyby spojení:** zapnout
  LocalDevVPN (ne WireGuard/StosVPN ze starých návodů), být na Wi‑Fi, vypnout
  DNS blokátory, restartovat SideStore a telefon. Pokud trvá: obnovit pairing
  file (níže).
- **Obnova pairing file** (po update iOS, resetu, nebo když SideStore hlásí
  neplatný pairing): připojit iPhone k Macu, spustit iloader → **Delete Stored
  Pairing** → vybrat zařízení → na telefonu Důvěřovat → **Manage Pairing
  File** → u SideStore (a případně dalších aplikací) **Place** → hláška
  „Pairing file placed successfully!“.
- **Instalace „visí“:** aktualizovat SideStore, Settings → clear cache, změnit
  Anisette server, reset `adi.pb`, restart, nový pairing file, případně
  přeinstalace SideStore přes iloader.
- **Aplikace nejde spustit („Nedůvěryhodný vývojář“):** Nastavení → Obecné →
  VPN a správa zařízení → důvěřovat; na iOS 16+ zapnout Režim vývojáře.
- **Update ve feedu nevidím:** SideStore kontroluje sources při otevření karty
  Browse (potáhnout pro obnovení); ověřit, že release `latest-ios` má nový
  build (číslo verze v názvu releasu).
- **Chybové kódy:** docs.sidestore.io → Troubleshooting → Error codes.
  Podpora: Discord SideStore (SideStore) a idevice (iloader).

## 10. Alternativa: AltStore + AltServer na Macu

Klasický AltStore obnovuje podpisy přes **AltServer běžící na Macu ve stejné
Wi‑Fi** — Mac tedy musí být zapnutý a v dosahu, jinak se po 7 dnech aplikace
zablokují. Pro MacBook, který se zavírá a nosí pryč, je SideStore vhodnější.

Pokud přesto AltStore:

1. Stáhnout AltServer z <https://altstore.io>, přetáhnout `AltServer.app` do
   Applications a spustit — objeví se v liště nahoře. Vyžaduje macOS 11+.
2. Ve Finderu vybrat iPhone → zapnout **„Zobrazit tento iPhone v síti Wi‑Fi“**
   (Wi‑Fi synchronizace), aby AltServer fungoval bez kabelu.
3. Připojit iPhone kabelem, odemknout, důvěřovat počítači. Ikona AltServer →
   **Install AltStore** → vybrat zařízení → zadat Apple ID. (AltServer 1.7+
   Mail plug‑in nepotřebuje; pokud starší verze o Mail plug‑in žádá,
   postupovat podle jejího dialogu.)
4. Na iPhonu důvěřovat vývojářské aplikaci (Nastavení → Obecné → VPN a správa
   zařízení) a zapnout Režim vývojáře (iOS 16+).
5. IPA nainstalovat buď v AltStore (My Apps → +), nebo z Macu: podržet
   **⌥ Option** a kliknout na ikonu AltServer → **Sideload .ipa…** → vybrat
   `audiobookshelf-ios.ipa`.
6. Source feed z kapitoly 6.1 funguje i v AltStore (Sources → +); odkaz
   `altstore://source?url=…` je obdoba `sidestore://`.
7. Nechat AltServer spouštět po přihlášení, aby obnova na pozadí běžela.

## 11. Alternativa: build a instalace z Xcode

Bez CI, přímo z MacBooku (nutné Xcode, Node 20, CocoaPods):

```bash
npm ci && npm run generate && npx cap sync ios
open ios/App/App.xcworkspace
```

V Xcode: cíl `Audiobookshelf` → Signing & Capabilities → Team = váš osobní tým
(free Apple ID přidané v Xcode → Settings → Accounts); Bundle Identifier
případně změnit, pokud Apple hlásí kolizi. Připojit iPhone (Režim vývojáře),
zvolit ho jako cíl a **Run**. Podpis platí 7 dní a obnoví se jen dalším
spuštěním z Xcode — pro běžné používání je SideStore pohodlnější.

## 12. Co dělá CI a „IPA server“ (source feed)

Workflow `.github/workflows/build-ios.yml` (`macos-15`, ~5 minut):

1. `npm ci && npm run generate && npx cap sync ios` (včetně `pod install`).
2. `xcodebuild archive` bez podpisu (`CODE_SIGNING_ALLOWED=NO`), konfigurace
   Release, bundle id `com.audiobookshelf.app`. Číslo verze je
   `<major>.<minor>.<číslo běhu>` z `MARKETING_VERSION` v Xcode projektu
   a build number = číslo běhu, takže každý build má jinou verzi (SideStore
   podle ní pozná aktualizaci; vidět je v Nastavení aplikace → O aplikaci).
3. Zabalí `Payload/Audiobookshelf.app` do `audiobookshelf-ios.ipa` a skriptem
   `scripts/make-sidestore-source.py` vygeneruje `sidestore-source.json`
   (formát AltSource: `name`, `bundleIdentifier`, `versions[]` s `version`,
   `buildVersion`, `date`, `downloadURL`, `size`, `sha256`; bez
   `marketplaceID`, které by SideStore odmítl).
4. Oba soubory nahraje jako artefakt `audiobookshelf-ipa`; na `master` navíc
   smaže a znovu vytvoří pre-release **`latest-ios`** s oběma soubory
   a odkazy `sidestore://` v popisu. Tím má IPA i feed **stálou URL**, kterou
   SideStore sleduje.

„IPA server“ tedy není nic, co by běželo u vás — je to GitHub Releases. Kdyby
bylo někdy potřeba hostovat feed jinde (vlastní web, GitHub Pages), stačí
zkopírovat `sidestore-source.json` a upravit `downloadURL`; formát zůstává.
Feed lze mít i s více verzemi (přidávat položky do `versions`), CI teď drží
jen poslední build.

Užitečné odkazy: SideStore docs <https://docs.sidestore.io>, iloader
<https://iloader.app>, LocalDevVPN <https://apps.apple.com/app/id6755608044>,
AltStore FAQ <https://faq.altstore.io>, formát source
<https://faq.altstore.io/developers/make-a-source>.
