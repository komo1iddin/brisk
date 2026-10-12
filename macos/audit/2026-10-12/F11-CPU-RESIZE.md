# F11: CPU va resize profiling

Branch: `codex/native-audit-fixes`. Baseline production source: `62f8b13`.
Faqat o‘z sintetik benchmark PID’lari va fixture’lari ishlatildi. Shaxsiy
archive, kontaktlar, message content yoki eski foydalanuvchi loglari o‘qilmadi.

## Tuzatishlar

- Valid mutation journal’da append yoki in-place edit eski ID’larni saqlaydi.
  Har live arrival uchun butun layout/height cache qayta filter qilinmaydi.
  Unknown/replaced/deleted window’da pruning saqlangan, interior deletion ham
  stale cache’ni bo‘shatadi.
- Qo‘shni bubble faqat tail/avatar holatini o‘zgartirsa, immutable measured
  body/link layout qayta ishlatiladi. Text, style yoki width o‘zgarsa,
  qayta o‘lchanadi. Coalesced edit, old last-row update va insertion bitta
  table update’da bajariladi; scroll anchor bir marta tiklanadi.
- Hidden empty/loading overlay va sidebar search/empty/sync island’lari
  resize layout olmaydi. Reveal joriy bounds’ga yetadi. Hidden loading task
  keyingi reveal’da yangidan boshlanadi. Newest button transition saqlangan.
- Programmatic yoki split-view width burst’lari oxirgi kenglik uchun 80 ms
  kutadi. Live resize avvalgidek drag tugaganda reflow qiladi. Live resize
  end pending task’ni darhol flush qiladi; eski kenglikka qaytish keraksiz
  reflow’ni bekor qiladi. Anchor saqlanadi.

Regressionlar rapid burst’da bitta measurement generation, eski width’ga
qaytishda nol reflow, live-resize end flush, layout body/link identity,
coalesced reaction/arrival, bottom/reading anchor, interior deletion cache
pruning va hidden/reveal geometry’ni tekshiradi.

## Nazoratli transient resize natijalari

Manba: [run summary](evidence/f11-visible-summary.json),
[binary SHA va run conditions](evidence/f11-visible-comparison.json),
[build provenance](evidence/f11-visible-builds.json).
Har hujayra ikki run statistikasi medianasi. A baseline, B candidate.
Host: Mac15,7, macOS 27.0.1 (26A434).

| Oyna / source fixture | Resize process CPU A → B, ms | Resize main CPU A → B, ms | Step p95 A → B, ms | Here CPU p95 A → B, ms |
|---|---:|---:|---:|---:|
| 840 pt / 50k | 2736.58 → 129.09 | 151.49 → 123.28 | 26.97 → 22.83 | 17.67 → 15.79 |
| 1100 pt / 50k | 140.37 → 142.91 | 132.79 → 137.00 | 27.42 → 26.76 | 18.77 → 16.44 |
| 1100 pt / 10k | 144.58 → 141.59 | 136.54 → 135.71 | 27.84 → 28.23 | 16.70 → 17.19 |

Tor oynada oraliq width’larni hisoblash bekor qilinib, burst process CPU
95.3% kamaydi. Bu scenario darhol oldingi measured width’ga qaytadi, shu
sabab candidate useful final reflow ham talab qilmaydi. Bu butun app CPU
foizi emas. Final tor width’da qoladigan alohida set quyida beriladi.
50k Here CPU p95 ikki window size’da pastroq; 10k p95 biroz yuqoriroq.
Keng oynadagi resize CPU/p95 uchun barqaror yutuq da’vosi yo‘q.

| Oyna / fixture | Full scroll callback p95 A → B, ms | Flick callback p95 A → B, ms | Peak footprint A → B, MiB |
|---|---:|---:|---:|
| 840 pt / 50k | 7.20 → 8.11 | 7.19 → 6.98 | 221.86 → 221.58 |
| 1100 pt / 50k | 8.36 → 8.24 | 7.17 → 7.18 | 218.90 → 221.15 |
| 1100 pt / 10k | 7.37 → 7.57 | 6.74 → 6.40 | 164.34 → 171.06 |

Full-scroll hitch medianalari shu tartibda A/B: 17/23, 25.5/19.5, 2.5/2;
flick: 6.5/4.5, 6.5/4, 2/1. Callback/RAM natijalari aralash.
A va B har run’da 915 resident record saqladi; retained payload 50k’da
1 690 992 byte, 10k’da 1 667 036 byte. F10 memory yutug‘i bilan bu yangi
CPU fixlarning natijasi aralashtirilmaydi.

12 run bo‘yicha 43 694 window-state check: inactive 0, occluded 0,
thermal state raw 0 (nominal). 69 952 geometry check / 445 532 visible row:
missing 0, misplaced 0. Geometry audit archive correctness o‘rnini bosmaydi;
paging/order/eviction alohida fixture tests’da tekshirildi.

## Final tor kenglikda qolish natijalari

Manba: [held-width summary](evidence/f11-held-summary.json),
[run conditions va binary SHA](evidence/f11-held-comparison.json),
[matching harness build](evidence/f11-held-builds.json).
840-point window, 50k source fixture, oxirgi tor width restore’dan oldin
300 ms saqlanadi. Ikki A va ikki B run, AB, BA tartibi.

| Metrika | A baseline | B candidate |
|---|---:|---:|
| Resize burst process CPU, ms | 2999.44 | 732.33 |
| Resize burst main-thread CPU, ms | 163.16 | 132.29 |
| Resize step p50, ms | 9.22 | 9.78 |
| Resize step p95, ms | 25.96 | 18.81 |
| Here main-thread CPU p95, ms | 18.05 | 15.46 |
| Full scroll callback p95, ms | 8.99 | 8.78 |
| Flick callback p95, ms | 7.18 | 6.71 |
| Sampled peak footprint, MiB | 219.03 | 220.79 |

Yakuniy useful reflow kerak bo‘lgan holatda process CPU medianasi **75.6%**,
main-thread CPU **18.9%**, resize step p95 **27.5%** kamaydi. Candidate step
p95 ikki run’da 12.81 va 24.80 ms; baseline 25.09 va 26.82 ms. Natija
shu workload va ikki takror bilan cheklangan, universal resize foizi emas.
P50 biroz yuqoriroq, full-scroll hitch medianasi 25 → 28.5, flick 5 → 3.5.
Scrolling va RAM uchun umumiy yaxshilanish da’vosi yo‘q.

Har run’da 915 resident record. A retained payload medianasi 1 690 881
byte (ikki run: 1 690 992 va 1 690 770), B ikkala run’da 1 690 992 byte.
Median farq 111 byte; record count/budjet bir xil, bu process RAM emas.
14 530 window check: inactive 0, occluded 0, thermal raw 0.
23 238 geometry check / 143 229 visible row: missing 0, misplaced 0.
Ikkala accepted set jami 16 run: **93 190 geometry check / 588 761 visible
row**, missing 0, misplaced 0; **58 224 window-state check**, inactive 0,
occluded 0. Bu native geometry fixture evidence, real network/hardware
stress emas.

## O‘lchash usuli

Arm64 optimised Release, bir xil Mac va bir xil benchmark harness.
Baseline alohida source copy’da qurildi: production Swift `62f8b13`,
benchmark harness candidate bilan bir xil. Bridge XCFramework va committed
package pins bir xil. Main checkout baseline uchun almashtirilmagan.

1100-point window’da timeline bubble width 560-point cap’da qoladi, shuning
uchun u width reflow worker xarajatini to‘liq ko‘rsatmaydi. 840-point window
shu limitdan pastga tushib, haqiqiy matn reflow’ini ishga tushiradi. Resize:
10 ta 8-point step, oralig‘ida 16 ms pause, eski frame’ga qaytish va 100 ms
settle. Qo‘shimcha held-width set’da tor final width restore’dan oldin
300 ms saqlanadi, shu hold ham burst CPU intervaliga kiradi. Resize
oldidan oxirgi arrival spring uchun 500 ms pause bor.

`resizeStepMs`: har step’ning layout/display/commit wall time’i.
`resizeBatchMainThreadMs` va `resizeBatchProcessCPUms`: butun burst, pause,
restore va settle orasidagi thread/process CPU. Bu step p95’dan boshqa
metrika; worker CPU parallel bo‘lgani uchun process CPU wall’dan katta
bo‘lishi mumkin. 100 ms settle tugagandan keyingi ish bu intervalga kirmaydi.
`Here`: har event uchun 80 ms settle oynasidagi main-thread CPU’dan median
idle CPU ayrilgan baho, message delivery latency emas. Scroll/flick p95:
frame callback work, GPU/presentation deadline kafolati emas.

Har variant/hajm uchun AB, BA tartibida ikki run. Jadval median-of-run
statistikani ishlatadi, pooled percentile emas. Physical footprint peak
faqat o‘z PID’imizdan `proc_pid_rusage` V2 bilan 50 ms oralig‘ida olindi;
sintetik 10k/50k source fixture ham process’da qoladi. Resident pane budjeti
fixture hajmiga teng emas. Host background activity izolyatsiya qilinmagan.

Benchmark oyna normal window level’da `moveToActiveSpace` va
`fullScreenAuxiliary` bilan ko‘rsatiladi. Count-only activity/occlusion va
thermal checks bor; faqat record qilingan barcha checks’da active/visible run qabul
qilinadi. Temporary caffeinate ishlatiladi va runner oxirida to‘xtatiladi.
Floating mode, doimiy power settings va real account ishlatilmaydi.
Build yoki profiler timing run’lari bilan bir paytda bajarilmaydi.

## Profiling dalillari

Time Profiler 1 ms sampling, faqat o‘z 50k sintetik PID’iga ulandi.
Faqat time-profile va signpost interval schema’lari export qilindi.
Repository’da symbol/weight/count aggregate bor; raw trace, XML, target log
va environment metadata saqlanmaydi. Inclusive stacklar ustma-ust keladi,
ularni qo‘shib umumiy CPU deb hisoblab bo‘lmaydi. Profiled va unprofiled
run timing’lari to‘g‘ridan-to‘g‘ri aralashtirilmaydi.

Dastlabki instrumented run’larda 15 Here event sampled main CPU 226 va
98 ms, Timeline update inclusive 97 va 34 ms edi. Window state record
qilinmagan, shu sabab bu farq final tezlik isboti sifatida ishlatilmaydi.
Bu diagnostics raw aggregate’lari saqlangan; nazoratli event CPU dalili
yuqoridagi A/B native clock o‘lchovlaridir.
Candidate resize’da hidden empty/sidebar island interval’lari nol;
newest button alohida qoladi. Oldingi combined overlay count’i bilan
newest-only count bir xil metrika emas. Sidebar hidden ishning baseline
xarajati kichik, unga katta tezlik yutug‘i nisbat berilmaydi.

Tor oynadagi valid baseline profile’da ResizeBurst 425.38 ms wall,
173 ms sampled main va 2750 ms sampled all-thread CPU ishlatgan.
Bu wide-window step-only profiling o‘tkazib yuborgan worker xarajatini
ko‘rsatdi. `Timeline` kategoriyasidagi Layout signpost default profiler
interval export’ida yo‘q; uni nol measurement deb talqin qilish mumkin emas.
Coalescing generation soni focused fixture bilan bevosita tekshirildi.

Yakuniy [held-width candidate profile](evidence/f11-held-profile-summary.json)
active/visible checks’dan o‘tdi. ResizeBurst: 732.29 ms wall, 171 ms sampled
main, 734 ms sampled all-thread CPU. Native clock bilan shu profiled run’da
172.61 ms main va 741.30 ms process CPU olindi. Bu profiler bilan run,
unprofiled A/B jadvaliga qo‘shilmaydi.

10 ResizeStep jami 129.74 ms wall / 130 sampled main CPU ms. Inclusive
window layout tree 98 ms, `TimelineController.place` 9 ms. Composer 10
interval’da 20.17 ms wall / 19 sampled CPU ms; Header 1 ms, Search 0 ms,
newest overlay 4 ms sampled CPU. Empty overlay va hidden sidebar island’lari
0 interval. Hosted view render/constraint traversal stack’da ko‘rinadi;
composer butun resize xarajati emas. O‘zaro inclusive stacklarni qo‘shish
mumkin emas. Yakuniy Here 15 interval’da 233 sampled main CPU ms, shundan
Timeline update/append inclusive 82 ms. Bu profile dastlabki 98 ms diagnostic
bilan to‘g‘ridan-to‘g‘ri solishtirilmaydi.

## Qolgan performance risklari

Ortiqcha per-arrival cache filter/copy, tail text remeasurement, duplicate
scroll restore, hidden optional hosting layout va intermediate width reflow
muammolari tuzatildi. Held-width CPU/p95 yutug‘i shu workload’da takrorlandi.
Keng window resize p95, scroll callback/hitch va peak RAM natijalari aralash;
F11 umumiy frame-time/p95 riski to‘liq yopildi deb belgilanmaydi.

Yakuniy profilingdagi asosiy qoldiq: AppKit window constraint/layout va
display traversal, ko‘rinadigan SwiftUI island render hamda table cell
insertion/refresh. Bu stacklar mavjudligi o‘zi bug isboti emas; keyingi
optimisation ularning aniq takroriy own-code trigger’ini alohida benchmark
bilan tasdiqlashi kerak. Upstream framework yoki protocol patch qilinmadi.
Real user workload va original WhatsApp bilan taqqoslash, 120 Hz barqarorligi
hamda real network/camera/microphone call stress shu dalillarda o‘lchanmagan.

## Dalil qatlamlari va cheklovlar

`f11-window-*` va `f11-repeat-*` dastlabki diagnostics: window state
record qilinmagan, resize oldidan arrival spring settle qilinmagan.
Ular final tezlik xulosasiga kiritilmaydi. `f11-verified-*` count-only
nazorat qo‘shilgan urinishlar: inactive/occluded run’lar bor, batch
haqiqiy natijani tekshirgandan keyin to‘xtatildi. `f11-narrow-after-profile`
inactive/occluded bo‘lgan, uning timing’i taqqoslashdan chiqarilgan.
`f11-visible-*` normal-level active-Space harness bilan transient resize
set’i. `f11-held-*` final tor width’ni 300 ms saqlaydigan alohida set.
Invalid/diagnostic natijalar o‘chirilmagan, ularning holati ochiq ko‘rsatilgan.

Bu original WhatsApp bilan benchmark emas. Real hardware/network call
stress, F14 startup/shutdown va umumiy 120 Hz kafolati bu run’larda
tekshirilmagan.

## Tekshiruv va qayta ishga tushirish

| Check | Natija |
|---|---|
| Native own-source forced warning gate | PASS |
| Native serial tests, committed pins | PASS, 575: Core 471, Conversation 92, Chats 10, Calls 2 |
| Candidate va matching-harness baseline Release/bundle | PASS, arm64 app va Share extension |
| Rust fmt, default/all-feature clippy va tests, warning-denied rustdoc | PASS |
| Native script tests va license inventory | PASS, 5 tests; pins o‘zgarmadi |

Manba: [check status va binary hash](evidence/f11-checks.json).
Native suite oldingi 566 testdan 575 testga o‘tdi.
Call fixtures mock holatlarni tekshiradi, kamera/mikrofon/network sinovi emas.

Candidate’da tor held-width scenario’ni qayta ishga tushirish:

```sh
ZAPFAST_BENCHMARK_COUNT=50000 \
ZAPFAST_BENCHMARK_WINDOW_WIDTH=840 \
ZAPFAST_BENCHMARK_RESIZE_HOLD_MS=300 \
macos/Build/DerivedData/Build/Products/Release/ZapFast.app/Contents/MacOS/ZapFast --benchmark
```

Transient test uchun hold 0; keng window uchun width 1100. Har run oxirida
JSON path chiqadi. Active/visible checks’ni tekshirish zarur, zero sample
run ham valid hisoblanmaydi. A/B uchun bir xil harness’ni production
baseline source ustiga qo‘llash, Release build’larni navbat bilan AB, BA
ishlatish va boshqa build/profiler’ni parallel ishlatmaslik kerak.
Benchmark CPU va geometry metrikalarini o‘zi chiqaradi; jadvaldagi peak
memory tashqi own-PID 50 ms sampler’dan olingan.

`fullScreenAuxiliary` window behavior uchun
[Apple AppKit hujjati](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
bor. Benchmark Space/activation holati faqat API chaqirilganiga qarab
qabul qilinmaydi, real activity/occlusion counter bilan tekshiriladi.
