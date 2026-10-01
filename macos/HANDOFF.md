# ZapFast macOS: unumdorlik ishi, holat va davom ettirish yo'riqnomasi

Yangilangan: 2026-10-01. Oldingi versiya 2026-09-30 da yozilgan edi (`a69b455`).
O'lchovlar va qoidalar tarixi [PERFORMANCE.md](PERFORMANCE.md) da. Bu yerda to'liq holat:
nima qilingan, nima tekshirilishi kerak, nima qolgan va qanday o'lchanadi.

---

## 1. Qayerda nima turibdi

| Narsa | Qiymat |
|---|---|
| Repo | `~/Developer/Self-projects/zapfast-mac-native` (crmne/zapfast fork'i). Native UI faqat `macos/` ichida. **`macos/` dan tashqaridagi fayllarga tegilmaydi** (upstream). |
| Ish branch'i | `timeline-performance` |
| Worktree | `~/Developer/Self-projects/zapfast-mac-native-timeline` (branch shu yerda ochiq) |
| Asos | `main` @ `92981d3`. Tarix chiziqli, merge commit yo'q |
| Zaxira | `backup/timeline-performance-pre-rebase` (`89ed0db`) |
| `main`ga qo'shilganmi | **Ha**, 2026-10-01 foydalanuvchi roziligi bilan fast-forward (`b69d4d2`). Push qilinmagan |
| Testlar | 216 (ZapFastCoreTests) + 31 (FeatureConversationTests). `make check`: ogohlantirishlar ham tekshiriladi, hammasi o'tadi |

```bash
cd ~/Developer/Self-projects/zapfast-mac-native-timeline/macos
make run        # Debug, ilovani ochadi (avval o'zingizning ZapFast'ingizni yoping)
make release    # Release (arm64)
make check      # ogohlantirishlar + testlar
```

---

## 2. 2026-09-30/10-01 dagi ish (`a69b455` dan keyin)

| Commit | Nima qiladi |
|---|---|
| `18ccded` | Benchmark haqiqiy chatlarga o'xshadi: xabarlarning yarmi media (rasm, hujjat, ovoz, video, stiker, link preview), yuklab olishlar 250 ms da tugaydi. Har kadrda ekrandagi qatorlar tekshiriladi (`Integrity`). Flick (tepaga-pastga), kursor rejimlari, `Frame` signpost, `ZAPFAST_BENCHMARK_DELAY` |
| `2c5abf1` | **Bo'sh lenta va o'chib-yonish tuzatildi.** `0dee224`dagi `translatesAutoresizingMaskIntoConstraints` override'lari olib tashlandi. Override bilan 5 ishga tushirishdan 2 tasida hosting view nol o'lchamga tushgan, override'siz 0 |
| `cda13df` | Nom: `TextBubble*` endi `Bubble*` (`BubbleCell`, `BubbleSource`, `BubbleLayout`) |
| `9e61d82` | O'chirilgan va ko'rsatib bo'lmaydigan xabarlar native. **Gallery vositasi** (`ZAPFAST_SNAPSHOT_TIMELINE`). Eski native matnda 3 xato tuzatildi: havolalar ko'k chizilgan edi, dark mode'da xira ranglar yorug' qolgan edi, ba'zi SF Symbol'lar to'ldirilgan edi |
| `deb93f8` | Rasm, video, GIF, stiker, dumaloq video native (`PictureView`). Quote foni to'q chizilgani ham tuzatildi |
| `853bd83` | Hujjat va link preview native (`DocumentView`, `LinkPreviewView`) |
| `411fcfc` | Ovozli xabar va audio fayl native (`VoiceView`) |
| `85157cf` | O'zgargan xabar (yuklab olish, status, reaksiya) faqat o'z qatorini qayta quradi, butun lentani emas |
| `4fe5ff6` | **Chat kontenti AppKit'da** (`ConversationViewController`): lenta oddiy subview, composer va overlay'lar kichik SwiftUI orollari. Toolbar, sheet'lar, qidiruv, wallpaper SwiftUI'da qoldi |
| `c685ab5` | Xabarlarni tanlash (checkbox'lar) native kataklarda. Avval tanlash boshlanganda har bir qator SwiftUI'ga aylanardi |
| `858415c` | Benchmark chat ro'yxatini (sidebar) ham scroll qiladi: hitch yo'q |
| `4006a67` | Kod review'dagi 13 topilma tuzatildi (quyida) |

Hali SwiftUI qatori bo'lib qolganlar (kam uchraydi): so'rovnoma, joylashuv, kontakt, biznes (interactive) kartalar,
stiker to'plami.

**Review (`4006a67`).** Mustaqil review agenti native kataklar va pane'ni tekshirdi. Crash yoki noto'g'ri qator topilmadi,
13 ta kichikroq xato tuzatildi: o'chirilgan video xabar ijroda qolishi, reaksiya picker'i boshqa xabar uchun yopilgan deb
xabar berishi, fayl kelganda rasm yoki PDF sahifasi bir lahza kulrang bo'lishi, hujjat sahifasining burchaklari kesilmagani,
tanlash rejimida kursor va VoiceOver qiymati, checkbox'ning dark mode'i, kulrang fonlar pufak matni rangidan olinishi,
hujjatni sudrab chiqarishdagi cho'zilgan ikonka, link preview bosilganda emas qo'yib yuborilganda ochilishi,
overlay faqat lenta ustida, "eng yangi xabar" oroli faqat tugmada bosiladi.

---

## 3. O'lchangan natijalar

**Benchmark** (M3 Pro, 120 Hz; 2000 xabar, yarmi media; kursor oynaga ta'sir qilmaydi):

| | `a69b455` (boshlanish) | Hozir (`4fe5ff6`) |
|---|---|---|
| Scroll hitch (paging / to'liq) | 55–106 ms/s | 1–4 ms/s |
| Flick (tepaga-pastga) | 28–55 ms/s | 0–3 ms/s |
| Kursor lenta ustida (`POINTER=over`) | 200–350 ms/s | 22–24 ms/s (pane'dan oldin o'lchangan) |
| 2000 xabarli chatni ochish | 940 ms | 150–165 ms |
| Chatni qayta ochish (61 qator) | 127 ms | 40–55 ms |
| Sakrash p50 | 13 ms | 3.5 ms |
| Resize qadami (8 pt) | 24 ms | 24 ms (o'zgarmadi) |
| Xotira | 240 MB | 115–135 MB |
| Integrity (bo'sh qatorlar) | 2/5 ishga tushirishda xato | 0 |
| Chat ro'yxatini scroll qilish | o'lchanmagan | hitch yo'q |

**Haqiqiy akkaunt (2026-10-01).** Foydalanuvchi `main`dagi eski build'da "tarix spinneri chiqqandan keyin ilova qotadi" dedi.
Uning oynasida, o'sha chatda (121 qator) lldb orqali 80 qadamli resize o'lchandi: `main` har qadamda 215–490 ms
(80/80 qadam 100 ms dan oshgan, jami 27,4 s), bu branch 20–30 ms (jami 2,4 s). Sabab: `main`da har resize qadamida
`TimelineController.resized` → `noteHeightOfRows` har bir SwiftUI qatorni main thread'da qayta o'lchagan (`RowMeasurer`).
Tarix qancha ko'p yuklansa, qadam shuncha sekin. Batafsil: PERFORMANCE.md, "On the linked account".
Qotishlar endi log'ga yoziladi (`HangMonitor`, category `Hangs`).

---

## 4. Foydalanuvchi aytgan muammolar holati

1. **Resize'da matn va preview'lar o'chib-yonishi.** Sabab `0dee224` override'lari edi (`2c5abf1`). Preview'lar endi native. Foydalanuvchi tekshirishi kerak.
2. **Tepaga scroll qilib tez pastga qaytganda lenta bo'sh qolishi.** O'sha sabab. Benchmark'dagi flick va integrity tekshiruvi endi 0 xato beradi. Tekshirish kerak.
3. **Resize biroz vaqtdan keyin qotishi.** Benchmark'da takrorlanmagan. Ehtimoliy sabablari (SwiftUI qatorlari har kenglikda qayta render bo'lishi, har o'zgarishda butun lentani qayta qurish) endi yo'q. Tekshirish kerak.
4. **Scroll, resize, chat almashtirish sekin.** Scroll endi "yaxshi" diapazonda. Resize va chat ochishning qolgan qismi oynaning SwiftUI ildizi (5-bo'lim).
5. **Qayta ulanish (sign out/in).** Log'da yangi ulanishdan keyin ham `chat settings recovery failed (Incremental): snapshot MAC mismatch` chiqdi. Demak ishga tushishdagi ~3 s kutish (upstream'dagi `privacy_ready`) qolgan. Bu upstream Rust kodi, `macos/`dan tuzatilmaydi.
6. **Lenta atrofini AppKit'ga o'tkazish.** Birinchi qismi bajarildi (`4fe5ff6`): lenta, composer, overlay'lar. Oyna, split view, sidebar va toolbar hali SwiftUI (5-bo'lim).

---

## 5. Keyingi qadamlar

**Birinchi navbatda: foydalanuvchi sinovi.** Ko'p narsa native qayta yozildi, vizual va interaktiv tekshiruv kerak:
rasm/video bosish (media viewer), dumaloq video joyida ijro, GIF va animatsion stiker kursor turganda,
hujjat (Quick Look, yuklab olish, sudrab chiqarish), ovozli xabar (ijro, pauza, seek, tezlik, avatar),
link preview bosish, reaksiya picker, kontekst menyu, matn tanlash, composer (glass), "eng yangi xabar" tugmasi,
chatlar orasida o'tishda fade, Liquid Glass ko'rinishi.

**Stage A2: to'liq AppKit oyna** (ixtiyoriy, o'lchovga ko'ra). Hozirgi xarajat (benchmark trace):
- resize qadami 24–27 ms, shundan ~40% SwiftUI (NavigationSplitView, toolbar item'lari);
- chatni qayta ochish ~40 ms, shundan ~65% SwiftUI graph yangilanishlari (toolbar header, sidebar tanlovi, composer oroli);
- scroll paytida kursor uchun `setCursorForMouseLocation` ildiz `NSHostingView.hitTest`ga tushadi.

Reja: `NSWindowController` + `NSSplitViewController` (sidebar: `NSHostingController(ChatListView)`, detail: `ConversationViewController`,
inspector: qidiruv paneli) + `NSToolbar` (header, qidiruv, chat menyusi, filtr va yangi chat `NSHostingMenu` bilan).
`.searchable` sidebar'da ishlamaydi, qidiruv maydoni sidebar tepasiga o'tadi. Buyruqlar `Settings` scene'iga ko'chadi.
Avval bayroq ortida (`ZAPFAST_APPKIT_WINDOW=1`) qilinsa, ikkalasini solishtirish mumkin.

**Boshqa ochiq ishlar:**
- Sidebar qatorlari hali SwiftUI (`NSHostingView<AnyView>` har qatorda). Boshqa chatda xabar kelganda p95 ~28 ms.
  Telefast'dagidek native chat kataklari yordam beradi.
- Qolgan SwiftUI qatorlari (so'rovnoma va boshqalar) hover'ni `.onHover` bilan oladi. Kam uchraydi.
- Yangi xabar kelganda (xabarlar soni o'zgarganda) lenta hali to'liq qayta quriladi. Oxiriga qo'shilgan xabarlar uchun ham
  in-place yo'l qilish mumkin (`TimelineController.editedInPlace` ga o'xshash).

---

## 6. Arxitektura (hozirgi)

- `ConversationView` (SwiftUI): toolbar, sheet'lar, info dialoglar, qidiruv inspector'i, wallpaper, fayl tashlash.
  Ichida `ConversationPane` (representable) → `ConversationViewController` (AppKit).
- `ConversationViewController`: `TimelineController`ning scroll view'i (oddiy subview), `ConversationOverlay` oroli
  (bosishlarni o'tkazadi), `NewestMessageIsland` (faqat tugma bosiladi), `ConversationBottomBar` (composer, tanlash yoki read-only).
  Lenta kirishlarini (xabarlar, tema, matn o'lchami, unread, tanlash, jump, scroll) `withObservationTracking` bilan kuzatadi.
- `TimelineController`: jadval. Qatorlar `Plan` → `Item`. `BubbleSource.make` xabarni native pufakchaga aylantiradi
  (yoki `nil` → SwiftUI `HostingCell`). Layout `TimelineLayoutEngine`da fonda, parallel.
- `BubbleCell`: `BubbleView` (fon layer, chrome layer: ism, forwarded, quote, placeholder, footer; body `TextLayer`)
  va attachment view'lari: `PictureView`, `DocumentView`, `VoiceView`, `LinkPreviewView`.
  Har katak faqat o'z xabarining holatini `CellWatch` bilan kuzatadi (yuklab olish, video, ovoz).

---

## 7. O'lchash va tekshirish vositalari

**Benchmark** (sintetik, akkauntsiz):
```bash
open -n -a Build/DerivedData/Build/Products/Release/ZapFast.app --args --benchmark
# JSON: ~/Library/Caches/com.komoliddin.ZapFastMac/benchmarks/timeline-*.json
```
Env: `ZAPFAST_BENCHMARK_COUNT` (default 2000), `ZAPFAST_BENCHMARK_MEDIA=0` (faqat matn),
`ZAPFAST_BENCHMARK_POINTER=1|over`, `ZAPFAST_BENCHMARK_DELAY=<s>` (Instruments ulash uchun),
`ZAPFAST_SWIFTUI_ROWS=1` (barcha qatorlar eski SwiftUI qatori, solishtirish uchun).
Natijalar mashina yuklamasiga bog'liq: A/B navbatma-navbat, kamida 2–3 martadan.

**Gallery** (Debug, akkauntsiz): native pufakchalar va SwiftUI qatorlari yonma-yon, yorug' va qorong'i:
```bash
ZAPFAST_SNAPSHOT_TIMELINE=$PWD/Build/Gallery/timeline.png Build/DerivedData/Build/Products/Debug/ZapFast.app/Contents/MacOS/ZapFast
# timeline.png, timeline-dark.png, timeline-end.png, timeline-dark-end.png (chapda native, o'ngda SwiftUI)
```
Butun oynani ilova ichidan rasmga olish ishlamaydi (qatlamli view'lar chizilmaydi). Pane geometriyasini raqamda tekshirish mumkin.

**Trace tahlili:** `xcrun xctrace record --template 'Time Profiler' --attach <pid>` (benchmark `ZAPFAST_BENCHMARK_DELAY=4` bilan).
Tahlil skriptlari (sessiya scratchpad'ida yozilgan edi, kerak bo'lsa qayta yoziladi): `Frame` intervallari ichidagi va orasidagi
main thread namunalari, `NSHostingView.layout()` chuqurligi bo'yicha (katak yoki oyna ildizi), chaqiruvchilar va chaqiriluvchilar.
`Open` signpost'i chat ochilishini belgilaydi.

**Haqiqiy akkauntda stress** (faqat o'qilgan chatlar, hech narsa yubormaydi):
```bash
open -n -a Build/DerivedData/Build/Products/Release/ZapFast.app --env ZAPFAST_STRESS=40
/usr/bin/log show --last 5m --style compact --predicate 'subsystem == "ZapFast" AND category == "Stress"' | grep Stress:
```

---

## 8. Xavfsizlik va maxfiylik qoidalari

- **Faqat bitta nusxa ishlaydi** (`LSMultipleInstancesProhibited`). Ishga tushirishdan oldin: `pgrep -fl 'Contents/MacOS/ZapFast'`.
  Jarayonlarni nomi bilan o'ldirmang.
- **Haqiqiy chatlar suratga olinmaydi, agent ularni ochmaydi** (ochilgan chat "o'qilgan" bo'ladi). Faqat sintetik benchmark va gallery.
- `archive.db` ichidagi xabarlar, kontaktlar va raqamlar o'qilmaydi.
- Fonda ishlaydigan kod `nonisolated`, fon thread'da testlanadi. `make check` ogohlantirishlarni xato deb hisoblaydi.
