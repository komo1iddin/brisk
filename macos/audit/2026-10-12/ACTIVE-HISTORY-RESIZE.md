# Active chat memory va resize tekshiruvi

Branch: `codex/native-audit-fixes`. Boshlang‘ich commit: `3d79c6c`.
Faqat sintetik fixture va benchmark ishlatildi. Shaxsiy archive, chatlar,
kontaktlar yoki eski foydalanuvchi loglari o‘qilmadi.

Har pane uchun mustaqil tarix oynasi, 1 200 record va 16 MiB hisoblangan
payload budjeti qo‘shildi. Row cap’da 900 recordgacha tushib, yangi xabarlarga
bo‘sh joy qoldiriladi. O‘qish anchor’i saqlanadi. Archive paging 60 tadan
ikkala yo‘nalishda ishlaydi; jump targetning har ikki tomonidan 60 tagacha
xabar keladi. Xabarlar encrypted archive’dan o‘chirilmaydi.

Selected xabarlar uchun payload nusxasi saqlanmaydi. Evicted tanlovning
Copy/Share/Forward amallari archive’dan off-main o‘qiydi. Cancel yoki lock
kechikkan natijani UI’ga chiqarishni to‘xtatadi. ID tartibi archive orqali
tekshiriladi, same-second phone order va row order saqlanadi.
Shift-click range anchor’i evicted bo‘lsa, archive 60-record pagelar orqali
o‘qiladi. Faqat ID va capability metadata yig‘iladi; latest request yutadi.

Timeline eski layout va hosted-height cache’larini loaded window bilan
birga bo‘shatadi. Oddiy mutation’da payload hisoblash faqat o‘zgargan
recordlarga tegadi. Resize’da pastki fading blur AppKit material va gradient
mask orqali chiziladi; title-band ranglari width o‘zgarishida qayta ajratilmaydi.

Eski pane’dagi message info, poll, interactive list va quote preview active
reader’dan o‘qiydi. Media gallery o‘z bounded reader’iga ega, old/new paging
chat pane’ni ko‘chirmaydi. Hozir ochiq bitta media record gallery eviction’dan
keyin ham qoladi; edit/download/revoke/delete hodisalari unga qo‘llanadi.
Viewer yopilganda reader va record bo‘shaydi. Cache’dan tashqaridagi
media ochilsa, uning atrofidan bounded archive window so‘raladi. Message Info
viewer yopilgandan keyin bitta inspected record’ni saqlaydi, receipts/media
yangilanishlari keladi, close/delete/clear/unlink’da bo‘shaydi. Partial clear
faqat oldingi xabarlarni o‘chirsa, yangiroq reply/edit/Info saqlanadi.
Galeriyadan evicted ochiq
media delete/revoke bo‘lsa, viewer yaqin loaded media’ni ko‘rsatadi yoki
bo‘sh gallery’da yopiladi; blank oynada qolmaydi.

Hidden wallpaper va “No chat selected” placeholder resize’da frame/layout
olmaydi. Qayta ko‘ringanda joriy bounds’ga yetib oladi. Composer va search
island’lari AppKit insets’dan foydalanadi, SwiftUI window safe-area geometriyasi
takrorlanmaydi. Window safe-area callback’i hidden view’ga kelsa ham,
`super.layout()` bajarilmaydi; qayta ko‘rinishi deferred layout’ni uyg‘otadi.
Role-only layout signpost’larda user identifier yo‘q.

16 MiB total RSS cheklovi emas. Bitta oversized record o‘qish uchun qoladi;
FFI batch, vaqtinchalik snapshot, decoded media, layer, boshqa ochiq pane va
explicit Copy/Share output’lari va viewer’dagi bitta active media record
hamda Message Info’dagi bitta inspected record alohida xotira ishlatadi.

## Tekshiruv

| Check | Natija |
|---|---|
| Native Swift tests, serial, committed pins | PASS, 566: Core 471, Conversation 85, Chats 8, Calls 2 |
| Forced ZapFastKit own-source warning gate | PASS |
| Rust fmt, default/all-feature clippy, tests va warning-denied rustdoc | PASS |
| Rust default/all-feature library | Har birida 1 142 PASS, 8 ignored; integration 5+2 va 7+2 PASS |
| Engine-only clippy va library tests | PASS, 560 PASS, 8 ignored |
| Bridge fmt, clippy va library tests | PASS, 48 tests |
| Native script tests va license inventory | PASS, 5 tests; pins o‘zgarmadi |

Boshlang‘ich sandbox Rust run’da 6 localhost fixture bind qilishga ruxsat
ololmadi. Yakuniy default va all-feature run’lar localhost ishlaydigan
muhitda to‘liq o‘tdi. Shaxsiy account ishlatilmadi.

Yangi regressionlar 50k record cap, nested thumbnail/string byte cost,
oversized/jump target, ikkala paging edge’i, viewport anchor, ikki pane,
stale/clear/closed/failure, archive selection/copy/share/forward/range va
timeline layout cache pruning, eski message action’lari, media paging/eviction
va hidden chrome/safe-area resize’ni qamraydi. Oldingi katta snapshot/index
testlari alohida katta test budjeti bilan saqlangan; production cap’ni
chetlab o‘tmaydi. Native call regressionlari ham to‘liq suite’da o‘tdi.

## Release o‘lchov usuli

Baseline: `3d79c6c`. O‘lchangan performance implementation: `aa910d9`; yakuniy media UI fix:
`ecfa2e7` va explicit context/partial-clear `1b77d3a`. Shu jumladan
`c3566c9` history budjeti va `5a42646` eski pane action mosligi.
Bir xil Mac’da arm64 optimised Release binary’lar, 50k AB, BA va 10k AB, BA.
Har bir variant/hajm uchun 2 run. Final table median-of-run statistikadan
foydalanadi, pooled percentile emas. Binary SHA-256 va barcha run natijalari
`evidence/bounded-window-comparison.json` hamda alohida JSON’larda bor.

Benchmark source fixture butun 10k/50k xabarni saqlaydi; resident pane budjeti
shu source fixture hajmiga teng emas. Here event oldidan newest pane qayta
warm/open qilinadi, tayyorlash timed interval tashqarisida. Demak bu bounded
production workload taqqoslanishi, bir xil resident row sonidagi microbenchmark
emas. `Here` 80 ms settle oynasidagi CPU’dan median idle CPU ayrilgan baho,
xabar yetib kelish latency’si emas. Resize: 10 ta 8-point width step, umumiy
AppKit layout + display wall time. Scroll p95 frame callback’ning ish vaqti,
GPU/presentation deadline kafolati emas.

Physical footprint `proc_pid_rusage` V2 orqali faqat o‘z synthetic PID’imdan
50 ms oralig‘ida olindi. Peak fixture, layer va cache’larni ham qamraydi;
50 ms orasidagi qisqa peak’ni o‘tkazib yuborishi mumkin. Total RSS hard cap yo‘q.
Host background activity izolyatsiya qilinmagan. Bu original WhatsApp bilan
benchmark emas va 120 Hz kafolati bermaydi.

Display uyquga ketganda CADisplayLink callback’i to‘xtashi tasdiqlandi.
Avvalgi tugamagan urinishlar timingga qo‘shilmadi. Authoritative run’larda
vaqtinchalik `caffeinate -u -d -t 600` ishlatildi va oxirida to‘xtatildi;
floating window mode yoki doimiy power settings o‘zgartirilmagan. Profiling va
build’lar A/B timing bilan bir paytda bajarilmagan. Raw trace/environment
metadata commit qilinmaydi, faqat symbol/counter aggregate dalillar qoladi.

## Dalil qatlamlari

`window-*` dastlabki exploratory run’lar display clock holati nazorat
qilinmaganligi uchun yakuniy jadvalga kiritilmadi. `awake-window-*`
budjet/foreground diagnostics bosqichi (`781e15a`), `final-window-*`
frame/safe-area fix bosqichi (`cd0f0ae`). Yakuniy performance jadvalining
manbasi `bounded-window-*` (`aa910d9`, hidden hosting layout guard bilan).
Har bosqichning raw JSON natijalari saqlangan, tugamagan urinishlar sanalmagan.

Benchmark media viewer’ni ochmaydi. Oxirgi media delete/revoke fallback, archive context va Message Info
lifetime tuzatishlari o‘lchangan performance yo‘liga tegmaydi, alohida native suite
va Release build bilan tekshiriladi.

## Yakuniy A/B natijalari

Har hujayra bir variantning ikki run’i medianasi. Memory physical-footprint
peak, vaqtlar ms. Manba: [summary](evidence/bounded-window-summary.json) va
[run metadata/SHA](evidence/bounded-window-comparison.json).
Host: `Mac15,7`, macOS `27.0.1 (26A434)`.

| Source fixture | Peak MiB A → B | Resize p50 A → B | Resize p95 A → B | Here CPU p95 A → B | Full scroll callback p95 A → B | Flick callback p95 A → B |
|---|---:|---:|---:|---:|---:|---:|
| 10 000 | 245.78 → 175.85 | 12.94 → 11.27 | 23.97 → 25.58 | 15.85 → 18.75 | 6.20 → 6.95 | 4.14 → 6.49 |
| 50 000 | 673.46 → 216.02 | 10.44 → 8.67 | 21.44 → 20.44 | 10.59 → 12.87 | 6.49 → 6.99 | 5.36 → 6.14 |

50k fixture’da peak physical footprint taxminan **68%**, 10k’da **28%**
kamaydi. B ikkala hajm/run’da 915 resident record, 10k’da 1 667 036,
50k’da 1 690 992 hisoblangan payload byte saqladi. 15 ta Here arrival row-cap
headroom’iga qo‘shilgan. Source fixture butun tarixni saqlab turishi benchmark
peak’ini real archive paging’dan kattaroq qiladi; bu farq uchun extrapolation
qilinmadi.

8 run bo‘yicha **46 718 integrity check / 301 596 visible row**:
missing **0**, misplaced **0**. Bu visible geometry tekshiruvi;
archive/paging/tie-order correctness alohida fixture regressionlarida tekshirildi.

Resize p50 ikkala hajmda pastroq. P95 50k’da biroz pastroq, 10k’da yuqoriroq,
shu sabab umumiy resize tezligi uchun barqaror foiz yoki “hammasi tezlashdi”
da’vosi yo‘q. Oraliq `final-window-*` set’ida 10k resize p95 28.05 → 20.74 ms
bo‘lgan, lekin oxirgi set buni takrorlamadi. Here CPU va callback p95’lari
oxirgi set’da B’da yuqoriroq. RAM budjeti CPU tezlashuvi sifatida baholanmaydi.
Full-scroll hitch sonlari A/B medianasi 10k’da 4/0.5, 50k’da 19.5/21;
flick’da 1/1 va 2/6.5. Shuning uchun 120 Hz yoki zero-hitch kafolati yo‘q.

Known resize code muammolari, nested width layout, fading SwiftUI material,
hidden hosting va takroriy composer/search safe-area hisobi, tuzatildi.
Umumiy AppKit window layout/display va hosted-row xarajatlari qoladi;
**F11 umumiy performance qismi hali to‘liq yopilmagan**. Qo‘shimcha CPU/
frame-time ishini shu hot path’lar bo‘yicha alohida o‘lchash kerak.

## Profiling

Manba: [final role/symbol aggregate](evidence/window-bounded-island-profile-summary.json).
Faqat o‘z 50k synthetic PID’iga Time Profiler ulandi, 1 ms sampling.
Raw trace, sample XML va environment metadata o‘chirildi.

ResizeStep ichida WallpaperLayout va PlaceholderLayout **0 interval / 0
sampled CPU ms**. AppKit callback yuborishi mumkin, lekin guard
`NSHostingView.layout()` ishini bajarmaydi. Ko‘rinadigan wallpaper va
placeholder reveal/catch-up holatlari native window fixture’da tekshirildi.
Composer 10 interval’da 22.52 ms wall / 22 sampled CPU ms; Header 0.84 ms /
1 sampled CPU ms, Search 0.18 ms / 0 sampled CPU ms. ResizeStep jami 10
interval’da 152.17 ms wall / 152 sampled CPU ms.

Boshlang‘ich instrumented profile’da hidden wallpaper 10 interval / 12.37 ms
wall / 11 sampled CPU ms, placeholder 10 / 3.51 ms / 7 sampled CPU ms edi.
Composer 51.78 ms wall / 52 sampled CPU ms edi. Bu profile’lar alohida run,
inclusive stacklar ustma-ust va profiler/host sharoiti farqlanadi; ulardan
butun app uchun tezlik foizi chiqarilmadi. Hidden hosting work’ning
yo‘qolgani count bilan tasdiqlandi. Qolgan resize stack’ining asosiy qismi
AppKit window constraint/layout va display yo‘lida, faqat composer’da emas.

F10 retained-history budjeti va uning zarur action compatibility qismi yopildi.
F11 known code tuzatishlari bajarildi, ammo umumiy CPU/p95/frame-time
performance riski yuqoridagi natijalar sabab ochiq qoladi.
