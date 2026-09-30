# ZapFast macOS: unumdorlik ishi — holat va davom ettirish yo'riqnomasi

Yozilgan sana: 2026-09-30. Bu hujjat keyingi sessiya shu yerdan davom etishi uchun yozilgan.
O'lchovlar va qoidalar tarixi [PERFORMANCE.md](PERFORMANCE.md) da. Bu yerda esa to'liq holat:
nima qilingan, nima ishlamayapti, nima gumon qilinadi va keyin nima qilish kerak.

---

## 1. Qayerda nima turibdi

| Narsa | Qiymat |
|---|---|
| Repo | `~/Developer/Self-projects/zapfast-mac-native` (crmne/zapfast fork'i). Native UI faqat `macos/` ichida. **`macos/` dan tashqaridagi fayllarga tegilmaydi** (upstream). |
| Ish branch'i | `timeline-performance` |
| Worktree | `~/Developer/Self-projects/zapfast-mac-native-timeline` (branch shu yerda ochiq) |
| Asos | `main` @ `92981d3`. Branch uning ustiga rebase qilingan, tarix chiziqli, merge commit yo'q |
| Zaxira | `backup/timeline-performance-pre-rebase`: rebase'dan oldingi 6 ta commit (`89ed0db`) |
| `main`ga qo'shilganmi | **Yo'q.** Foydalanuvchi sinab ko'rmaguncha qo'shilmaydi. AGENTS.md bo'yicha faqat fast-forward qilinadi, merge commit yaratilmaydi |
| Testlar | 216 + 13 (FeatureConversationTests). `make check` ogohlantirishlarni ham tekshiradi — hammasi o'tadi |

Build:
```bash
cd ~/Developer/Self-projects/zapfast-mac-native-timeline/macos
make run        # Debug, ilovani ochadi
make release    # Release (arm64); bridge'ning Release build'i ~7 daqiqa oladi
make check      # ogohlantirishlar + testlar
```
Har bir worktree'ning Rust `target/` papkasi alohida: yangi worktree'da bridge'ni birinchi yig'ish ~7 daqiqa oladi.

---

## 2. Branch'dagi commit'lar (eskidan yangiga)

| Commit | Nima qiladi |
|---|---|
| `22c61bf` | `--benchmark`: sintetik chatlar (faqat matn) bilan lenta benchmark'i |
| `29969fd` | Store'lar per-chat slot'larda: view faqat o'z chatini kuzatadi |
| `5dd05a7` | Sidebar ro'yxati toolbar'dan ajratilgan |
| `660a161` | Rasm keshlari baytda cheklangan (64 MB / 48 MB) |
| `7786773` | Chat ro'yxati: SwiftUI `List` o'rniga AppKit source-list `NSTableView` |
| `a174d33` | **Native lenta**: matnli xabarlar Core Animation'da, layout fonda. Rasm, hujjat, ovoz va boshqalar hali SwiftUI qatori (`HostingCell`) |
| `83529b4` | O'qilmagan/kanal sonlari saqlanadigan qiymat, menu bar label alohida view, sidebar indeks bo'yicha saralanadi |
| `108fdf4` | Typing, presence va qoralama per-chat slot'larda |
| `2bf7b8d` | Chat ro'yxati: ochiq chat doim ko'k, scroll joyi saqlanadi, tepaga ko'tarilgan chat sirg'aladi |
| `596f1c1` | `DisplayImage`: rasmlar fonda displey formatiga o'tkaziladi |
| `d363582` | `Launch: … after N ms` log'lari |
| `cae03f5` | `Scripts/check-warnings.sh`, `make check`, `make release` arm64 |
| `eaaf788` | Chatga o'tishda fade |
| `d91a528` | PERFORMANCE.md |
| `0dee224` | ⚠️ **Gumon qilinayotgan regressiya (5-bo'limga qarang).** Lenta qatorlari, kataklar, pufakcha subview'lari va kataklardagi `NSHostingView` Auto Layout'dan chiqarilgan (`translatesAutoresizingMaskIntoConstraints` getter'i doim `false` qaytaradi). Hover'ni jadval bitta tracking area bilan kuzatadi, representable'larga `sizeThatFits` qo'shilgan, layout keshlari chatlar orasida saqlanadi |
| `a171c1c` | Menu bar belgisi AppKit `NSStatusItem`da (`MenuBarIcon.swift`). `ZAPFAST_STRESS` rejimi (`LiveStress.swift`) |
| `9a6a5a1` | `PhoneHistory`: telefondan tarix so'rash tezligi cheklangan ("yo'q" javobi 3 kun eslab qolinadi, javob bo'lmasa 5 daqiqa kutiladi) |
| `1f1e860` | `Events` log'i: har 10 soniyada hodisa turlari soni va ularni qayta ishlash vaqti |
| `a9e3859` | PERFORMANCE.md'ga haqiqiy akkaunt natijalari yozilgan |

---

## 3. O'lchangan natijalar (qisqacha)

**Sintetik benchmark** (2000 xabar, faqat matn; `main` bilan navbatma-navbat, 3 martadan):
resize qadami 2,3–2,7 s → 23–25 ms · sakrash p95 ~100–126 → 5–10 ms · chatni qayta ochish ~290–446 → 59–87 ms ·
boshqa chatdagi xabar p50 22–30 → 4–7 ms · to'liq scroll hitch 79–702 → 3–14 ms/s · xotira 132–184 → 98–102 MB.

**Haqiqiy akkaunt** (`ZAPFAST_STRESS=40`; 12 ta o'qilgan chat, mediya ko'p, main-thread median):

| Build | Chat ochish | 2 s scroll (100+ qatorli chatlar) | Resize (6 qadam) |
|---|---|---|---|
| Birinchi yetkazilgan branch | 145 ms | 568 ms (960 ms) | 291 ms |
| `0dee224` + `a171c1c` + keshlar | 135 ms | 453 ms (858 ms) | 300 ms |

**Xulosa:** benchmark'dagi katta yutuq haqiqiy chatlarda ko'rinmaydi. Sababi — haqiqiy chatlar asosan SwiftUI qatorlaridan
(hujjat, rasm, ovoz) iborat, benchmark esa faqat matnni o'lchaydi. **Benchmark haqiqiy holatni aks ettirmaydi. Keyingi o'lchovlar
`ZAPFAST_STRESS` bilan yoki mediyali sintetik ma'lumot bilan qilinishi kerak.**

Haqiqiy akkauntdagi scroll paytida main thread taqsimoti (`0dee224`dan keyin):
~36% oynaning SwiftUI layout'i, ~19% Core Animation, ~13% kursor/tracking (AppKit har kadrda SwiftUI ierarxiyasi bo'ylab hit-test qiladi),
~2% SwiftUI qatorlarining o'zi, ~24% boshqa.

---

## 4. Foydalanuvchi aytgan ochiq muammolar (hali hal qilinmagan)

Foydalanuvchi so'nggi build'ni (`a9e3859`gacha) sinab ko'rgach, quyidagilarni aytdi:

1. **Resize paytida matn va preview'lar qayta-qayta o'chib-yonadi.**
2. **Tepaga scroll qilib, keyin tez pastga qaytganda lenta bo'sh qoladi.**
3. **Resize biroz vaqtdan keyin qota boshlaydi.**
4. **Umuman olganda scroll, resize va chat almashtirish sekin.** Telefast'da xuddi shunday arxitektura bor, lekin u tez — mediya va attachment'lar bilan ham.
5. Foydalanuvchi **sign out qilib, qaytadan kirdi** (qayta ulandi). Bu 6-bo'limdagi ishga tushish muammosiga ta'sir qilishi kerak — tekshirilmagan.
6. Foydalanuvchi so'radi: **lenta atrofini ham AppKit'ga o'tkazish** (7-bo'lim).

---

## 5. Gumon: `0dee224` regressiyasi (1-, 2- va ehtimol 3-muammo)

`0dee224`da lenta view'larining `translatesAutoresizingMaskIntoConstraints` xossasi override qilinib, doim `false` qaytaradi:
`TimelineRowView`, `TextBubbleCell`, `ChipCell`, `HostingCell`, `CellHostingView` (`TimelineCells.swift`), `BubbleView`, `ReactionPillsView` (`TextBubbleCell.swift`).

Muammo: bu view'larda constraint yo'q, oyna esa Auto Layout bilan ishlaydi. `translatesAutoresizingMaskIntoConstraints == false`
va constraint'siz view'ning frame'ini Auto Layout layout pass paytida noaniq (0 yoki eski) qiymatga qo'yib yuborishi mumkin.
Qo'lda o'rnatilgan frame'lar keyingi pass'da "yo'qoladi". Bu quyidagi alomatlarga to'liq mos keladi:
- lenta bo'sh qolishi (qatorlar ekrandan chiqib ketadi yoki nolga tushadi);
- resize'da o'chib-yonish (frame'lar navbatma-navbat jadval va engine tomonidan o'rnatiladi).

**Tekshirilmagan.** Keyingi sessiyada birinchi qilinadigan ish:
1. Sintetik benchmark'da tez scroll paytida oynani ~0,2 s oralig'ida suratga olib, bo'sh kadrlarni sanash.
   `0dee224`dan oldingi build (`eaaf788`/`d91a528`) va keyingi build'ni solishtirish kerak.
2. Tasdiqlansa — override'larni olib tashlash. Ildiz layout'ini boshqa yo'l bilan to'xtatish (7-bo'lim, AppKit shell) to'g'riroq yechim.
   Tezkor yechim: override'larsiz ham `0dee224`dagi boshqa narsalar qoladi (hover, `sizeThatFits`, keshlar).
3. Resize'dagi o'chib-yonishning boshqa ehtimoliy sababi: SwiftUI qatorlari (`HostingCell`) kenglik o'zgarganda qayta render bo'ladi,
   thumbnail'larni esa `.task(id:)` qayta yuklaydi. Bu 5.1 tuzatilgandan keyin alohida tekshiriladi.

---

## 6. Ishga tushish va tarix (upstream bilan bog'liq)

**3 soniyalik kutish.** Rust worker (`src/backend/worker.rs`, `privacy_ready`) telefondagi qulflangan chatlar tasdiqlanmaguncha
chatlar, xabarlar va qoralamalarni UI'ga yubormaydi. Bu akkauntda tasdiqlash har safar yiqilgan edi:
`chat settings recovery failed (Snapshot): snapshot MAC mismatch`. Shuning uchun `chat_privacy_ready_v1` belgisi saqlanmas va har ishga
tushishda urinish muvaffaqiyatsiz tugashi kutilardi. Log'da: `Launch: chat list from the archive after ~3000–4000 ms`.
Yangi ulanish Snapshot emas, Incremental rejim bilan boshlanadi, shuning uchun **qayta ulanish bu muammoni hal qilgan bo'lishi mumkin.**
Tekshirish:
```bash
grep -E "recovery failed|MAC mismatch" ~/Library/Application\ Support/com.komoliddin.ZapFastMac/State/zapfast.log
/usr/bin/log show --last 10m --style compact --predicate 'subsystem == "ZapFast" AND category == "Launch"' | grep Launch:
ls -la ~/Library/Application\ Support/com.komoliddin.ZapFastMac/State/archive.db
```
Kutilgan natija: xato yo'q, `chat list from the archive` ~1 s atrofida yoki undan kam. Oldin arxiv atigi ~2 MB edi, ya'ni tarix juda kam
saqlangan. Yangi ulanishdagi history sync'dan keyin u kattalashishi kerak.

**Tarix yuklanishi to'xtab qolishi.** Arxiv tugagach ilova telefondan so'raydi (`fetchOlder`, `PHONE_PATIENCE` 30 s).
Telefon 0 ta xabar bilan javob bergan yoki javob bermagan. Oldin so'rov har scroll'da va har ishga tushishda takrorlanardi.
`9a6a5a1` (`PhoneHistory`) buni cheklaydi. Telefonda yo'q tarixni ilova olib kela olmaydi.

---

## 7. Nega Telefast tez, ZapFast esa sekin — va reja

| | Telefast | ZapFast (hozir) |
|---|---|---|
| Lenta kataklari | **barcha** turlar (rasm, video, fayl, ovoz, stiker, albom) native layer'larda | faqat matn native. Qolgani `NSHostingView` ichidagi to'liq SwiftUI `MessageRow` |
| Qator balandligi | fonda, barcha turlar uchun | matn fonda. SwiftUI qatorlari main thread'da `NSHostingController.sizeThatFits` bilan |
| Oyna atrofi | nisbatan yupqa SwiftUI | Liquid Glass toolbar header, overlay'lar, inspector, ko'p sheet'lar, composer — hammasi bitta SwiftUI ildizida |

Trace'dagi asosiy zanjir shunday:
1. Lenta ichidagi SwiftUI qatori (`CellHostingView`) yangilanadi yoki jadval qator qo'shadi.
2. `setNeedsUpdateConstraints` → `_informContainerThatSubviewsNeedUpdateConstraints` yuqoriga tarqaladi.
3. U `AppKitPlatformViewHost._layoutMetricsInvalidated`ga yetib boradi.
4. **Butun oyna SwiftUI layout'idan qayta o'tadi.**

Kursorni yangilash ham har kadrda butun SwiftUI ierarxiyasi bo'ylab hit-test qiladi. Lenta SwiftUI ildizining ichida ekan,
bundan qutulib bo'lmaydi.

### Reja (foydalanuvchi so'ragan yo'nalish)

**Bosqich A — AppKit shell** (asosiy oyna). Maqsad: lenta hech qanday SwiftUI ildizining ichida bo'lmasligi.
- Asosiy oyna SwiftUI `Window` scene'i emas, AppKit'da yaratiladi: `NSWindowController` + `NSSplitViewController`.
  - Sidebar: `NSHostingController(ChatListView)`.
  - Detail: `ConversationViewController` (AppKit). Lentaning `NSScrollView`i to'g'ridan-to'g'ri subview.
  - Composer, sarlavha va overlay'lar (bo'sh holat, yuklanish, "eng yangi xabar" tugmasi) — alohida kichik `NSHostingView` orollari.
- Toolbar: `NSToolbar`. Uning element'lari `NSHostingView`/`NSToolbarItem` bo'ladi. Alternativa — `NSHostingController.sceneBridgingOptions` (macOS 14+), lekin ikki controller bitta toolbar'ga ko'prik qila olishi tekshirilmagan.
- Sheet'lar (forward, poll results, message info, sticker pack, interactive list, info dialogs): detail ichidagi 0 o'lchamli `NSHostingView` ularning `.sheet` modifier'larini ushlab turadi.
- Inspector (chat ichida qidiruv): uchinchi `NSSplitViewItem` (inspector uslubida).
- `.commands` asosiy `Window` scene'idan `Settings` scene'iga ko'chiriladi (buyruqlar ilova darajasida ishlaydi).
- Linking, qulf ekrani va xabarnomalar (RootView'dagi holatlar): detail/window content'ni almashtiradigan hosting controller'lar.
- Tayyor qo'llanma: `native-mac-ui` skill'i ("AppKit shell, SwiftUI leaves").

**Bosqich B — mediya kataklarini native qilish** (Telefast'dagidek), foydalanish chastotasi bo'yicha:
rasm/video thumbnail (layer `contents`, `DisplayImage`), hujjat (ikonka + ism + hajm), ovozli xabar, stiker, keyin qolganlari.
SwiftUI qatori faqat kam uchraydigan turlar uchun qoladi.

**Bosqich C — o'lchov.** Benchmark'ga mediya qo'shiladi (`SyntheticChats`), shunda u haqiqiy chatlarga yaqinlashadi.
`ZAPFAST_STRESS`ga resize'ni ko'p marta takrorlash qo'shiladi ("biroz vaqtdan keyin qotish"ni ushlash uchun).

---

## 8. O'lchash vositalari

**Sintetik benchmark** (faqat matn, akkauntsiz):
```bash
open -n -a Build/DerivedData/Build/Products/Release/ZapFast.app --env ZAPFAST_BENCHMARK_COUNT=2000 --args --benchmark
# JSON: ~/Library/Caches/com.komoliddin.ZapFastMac/benchmarks/timeline-*.json
```

**Haqiqiy akkauntda stress** (faqat o'qilgan chatlarni ochadi, hech narsa yubormaydi, oxirida o'zi yopiladi):
```bash
open -n -a Build/DerivedData/Build/Products/Release/ZapFast.app --env ZAPFAST_STRESS=40
/usr/bin/log show --last 5m --style compact --predicate 'subsystem == "ZapFast" AND category == "Stress"' | grep Stress:
```
Har raund uchun chiqadigan ko'rsatkichlar: `open … ms main`, `rows a→b`, `scroll … ms main`, `longest frame gap`, `resize … ms main`, `memory`.

**Jonli hodisalar:** `category == "Events"` (har 10 s). **Ishga tushish:** `category == "Launch"`.

**Trace va tahlil:**
```bash
xcrun xctrace record --template 'Time Profiler' --output run.trace --time-limit 60s --attach <pid>
```
Tahlil qilish uchun Telefast'dagi `~/Developer/Self-projects/telefast-mac-native/scripts/analyze-hitches.py` ishlatiladi
(`main_samples(trace)` main thread namunalarini qaytaradi). Toifalar bo'yicha bo'lish uchun kalit so'zlar:
`NSHostingView.layout()` (oyna SwiftUI layout'i), `_NSTrackingArea` (kursor), `CA::` (Core Animation), `RowMeasurer`,
`TimelineController`, `MenuBarExtra|NSStatusItem`. Layout'ni kim uyg'otayotganini topish uchun quyidagi chaqiruvlar zanjirlari qidiriladi:
`setNeedsUpdateConstraints`, `_layoutMetricsInvalidated`, `enqueueLayoutInvalidation`, `graphInvalidation`.

**SwiftUI instrumenti:** `--template 'SwiftUI'` yoziladi, lekin haqiqiy akkauntda 60 s trace'ning eksporti 1,8 GB'dan oshdi.
Undan faqat qisqa (≤10 s) oynalar uchun foydalaning. Benchmark rejimida ma'lumot umuman yozilmadi.

---

## 9. Xavfsizlik va maxfiylik qoidalari

- **Faqat bitta nusxa ishlaydi** (`LSMultipleInstancesProhibited`). Ishga tushirishdan oldin foydalanuvchi o'z ZapFast'ini yopgan bo'lishi kerak:
  `pgrep -fl 'Contents/MacOS/ZapFast'`. Jarayonlarni nomi bilan o'ldirmang. O'zingiz ochgan nusxani `osascript -e 'tell application id "com.komoliddin.ZapFastMac" to quit'` bilan yoping.
- **Haqiqiy chatlar suratga olinmaydi.** Faqat benchmark oynasi (sintetik) suratga olinadi.
- `archive.db` ichidagi xabarlar, kontaktlar va raqamlar o'qilmaydi — faqat sxema, hajm va qatorlar soni.
- Haqiqiy akkauntda chat ochish uni "o'qilgan" deb belgilaydi. Stress rejimi shuning uchun faqat o'qilgan chatlarni ochadi.
- Fon queue'da ishlaydigan kod `nonisolated` bo'lishi va fon thread'da test qilinishi kerak. `make check` ogohlantirishlarni xato deb hisoblaydi.
  Telefast'da aynan shunday ogohlantirish crash bergan. Bu branch'da ham `NSAnimationContext` completion handler'ida xuddi shu xato bir marta chiqqan.
