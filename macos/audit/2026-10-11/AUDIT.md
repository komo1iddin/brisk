# ZapFast native macOS: performance va open source auditi

Sana: 2026-10-11. Tekshirilgan commit: `cec8c150cf50b6d6566e99ad1e50e04250add795`, `main`.

## Qaror

Native interfeysning scroll arxitekturasi yaxshi va sintetik sinovlar buni qo‘llab-quvvatlaydi. Oddiy chatda sezilarli tezlik uchun texnik asos bor: `NSTableView` virtualizatsiyasi, Core Animation bilan chiziladigan bubblelar, fon oqimida text layout, o‘lchamga mos image decode va o‘zgargan qatorlarni alohida yangilash.

Hozirgi holatni keng auditoriya uchun tayyor stable release deb baholamayman. Parallel layoutda **takrorlanadigan memory leak**, app lock va location preview bo‘yicha privacy bo‘shliqlari, native buildni tekshirmaydigan CI hamda boshqa interfeysni chiqaradigan release workflow bor. Source repo’ni rivojlantirilayotgan macOS fork sifatida ochish mumkin; stable binary va kuchli performance da’volaridan oldin quyidagi P1 masalalarni yopish kerak.

“Rasmiy WhatsApp macOS’dan bir necha marta tez” degan nisbat bu auditda o‘lchanmadi. O‘lchangan natijalar ZapFast’ning o‘z sintetik benchmarkiga tegishli. Root README’dagi WhatsApp Web/Linux taqqoslashini native macOS taqqoslashiga ko‘chirish to‘g‘ri bo‘lmaydi.

## Qamrov va dalil darajasi

- Native SwiftUI/AppKit shell, conversation/sidebar rendering, media, calls, multi-account, Swift/Rust bridge, engine chegaralari, build/test/release konfiguratsiyasi va loyiha hujjatlari ko‘rib chiqildi. Har bir faylning har bir qatori tekshirildi degan da’vo yo‘q.
- `archive.db`, haqiqiy chatlar, kontaktlar, xabarlar, session kalitlari yoki foydalanuvchining mavjud loglari o‘qilmadi. Testlar fixture, mock va sun’iy matn/media bilan bajarildi.
- **Takrorlangan:** bajarilgan test yoki benchmark bilan isbotlangan natija.
- **Kod bilan tasdiqlangan:** tegishli execution path manbada bor; real account yoki hardware bilan end-to-end tekshirilmagan.
- **Xavf:** tuzilma muammoga olib kelishi mumkin; real crash, OOM yoki qo‘ng‘iroq uzilishi bu auditda takrorlanmagan.
- Bu code/performance/release auditidir. U penetratsion test, kriptografik isbot, barcha dependency’lar uchun yangi vulnerability bazasi tekshiruvi yoki huquqiy xulosa emas.

## Asl arxitektura

macOS forkning UI’i egui emas. `macos/Packages/ZapFastKit` SwiftUI va AppKit interfeysini beradi; `macos/Bridge` UniFFI orqali root ZapFast crate’ni `default-features = false` bilan engine sifatida ishlatadi. Protokol `whatsapp-rust` orqali yuradi. Shu sabab root egui app benchmarki va native macOS benchmarki alohida mahsulot yo‘llariga tegishli.

Chat va sidebar’ning asosiy ro‘yxatlari `NSTableView`; odatiy bubblelar AppKit/Core Animation orqali chiziladi. SwiftUI composer, dialog, sozlamalar, call panel va ayrim murakkab qatorlarda ishlatiladi. Rust worker alohida runtime’da; Swift modelga eventlar main queue orqali tartib bilan yetkaziladi.

Accountlar alohida engine/archive/session papkalariga ega. Native qo‘ng‘iroq tarixi har account uchun alohida SQLCipher `calls.db` va Keychain kaliti bilan saqlanadi. Biroq ayrim native media cache’lari shu izolatsiyaga mos emas, F06 va F07.

Hozirgi build yo‘li **Apple Silicon arm64**, minimum **macOS 15**, build uchun **Xcode 26+**. Intel qo‘llab-quvvatlangan deb yozish uchun hozir dalil yo‘q. Root universal egui release bu native arm64 buildning o‘rnini bosmaydi.

Manbalar: [native README](../../README.md), [bridge manifest](../../Bridge/Cargo.toml), [native Makefile](../../Makefile), [project spec](../../project.yml).

## Bajarilgan tekshiruvlar

| Tekshiruv | Natija | Izoh |
|---|---|---|
| Root `cargo fmt --all --check` | PASS | Manba formatlash |
| Bridge `cargo fmt --all --check` | PASS | Alohida Rust workspace |
| Engine `cargo clippy --locked --offline --no-default-features --lib -- -D warnings` | PASS | UI’siz engine chegarasi |
| Engine `cargo test --locked --offline --no-default-features --lib` | FAIL, compile | Test UI-gated `crate::markup`ni ishlatadi, F22 |
| Bridge `cargo clippy --locked --offline --all-targets -- -D warnings` | PASS | Bridge targetlari |
| Bridge `cargo test --locked --offline --lib` | PASS, 47 test | Fixture va mock |
| Native Swift test suite | PASS, 471 test | 397 Core, 66 Conversation, 8 Chats; audit proberlari chiqarilgach ham qayta o‘tdi |
| Native Release Xcode build | PASS | arm64, mavjud generated project/bridge bilan |
| Native `Scripts/check-warnings.sh` | FAIL | Xcode 27 toolchain’da own-source’ning ikki warning’i, F19 |
| `codesign --verify --deep --strict` | PASS | Lokal app imzosi izchil; Developer ID distribution isboti emas |
| Release timeline benchmark | 2,000 va 10,000 xabar | Sun’iy model, haqiqiy native window |
| Audit regression probes | 4 muammo takrorlandi | Layout leak, thumbnail invalidation, Lottie izolatsiyasi, video rotation reset; serial layout control o‘tdi |

Engine unit-test natijasi [validation yozuvi](evidence/validation.txt)da keltiriladi. Build/test loglari `macos/Build/audit-*.log`da; sun’iy benchmark va regression dalillari ushbu papkaning `evidence/` qismida saqlangan.

Dastlab Swift testlari agent sandboxida CoreAudio node yaratishda abort bo‘ldi. Xuddi shu testlar CoreAudio mavjud muhitda va yakuniy qayta buildda o‘tdi. Bu sandbox cheklovi appdagi aniqlangan crash sifatida hisoblanmadi.

## Scroll, latency va memory o‘lchovlari

Muhit: Apple M3 Pro, 18 GiB RAM, 12 CPU, `Mac15,7`, macOS `27.0.1 (26A434)`, Xcode 27 beta/Swift 6.4, Rust 1.98. Release window `1100 × 740`, timeline `794 pt`, display `120 Hz`. Bir frame budjeti `8.33 ms`.

| O‘lchov | 2,000 xabar | 10,000 xabar |
|---|---:|---:|
| Dastlabki 61 qator, wall time | 274.70 ms | 252.72 ms |
| Dastlabki 61 qator, main thread | 160.32 ms | 157.09 ms |
| To‘liq tarix ochilishi, wall time | 158.32 ms | 508.18 ms |
| To‘liq tarix ochilishi, main thread | 73.07 ms | 115.27 ms |
| To‘liq tarix scroll, frame work p50 / p95 / p99 | 0.62 / 2.61 / 3.13 ms | 1.05 / 4.66 / 7.58 ms |
| To‘liq tarix scroll, 8 sekunddagi hitch | 0 | 11 |
| To‘liq tarix scroll, hitch time | 0 ms/s | 11.97 ms/s |
| Paging bilan scroll, hitch | 2 | 4 |
| To‘liq tarixga yangi xabar, p50 / p95 | 5.01 / 5.82 ms | 19.83 / 22.83 ms |
| 8 pt resize qadami, p50 / p95 | 8.67 / 10.06 ms | 11.12 / 20.70 ms |
| Warm chat ochilishi, 61 qator wall time | 50.86 ms | 58.26 ms |
| Process physical footprint | 124.94 MiB | 204.64 MiB |
| Tekshirilgan integrity qatorlari | 38,275 | 39,602 |
| Yo‘qolgan / noto‘g‘ri joylashgan qator | 0 / 0 | 0 / 0 |

Raw dalillar: [2k text](evidence/timeline-2000.txt), [2k JSON](evidence/timeline-2000.json), [10k text](evidence/timeline-10000.txt), [10k JSON](evidence/timeline-10000.json). Benchmark “MB” deb chop etadi, hisob esa 1,048,576 ga bo‘linadi; jadvaldagi birlik MiB.

Natija: 2k chatning asosiy scroll yo‘li 120 Hz budjetiga katta zaxira bilan sig‘di. 10k chatda ham p95 frame work budjet ichida, lekin ayrim interval va event/resize ishlari undan oshdi. Yangi xabar kelishidagi taxminan 20 ms median main-thread ish scroll paytida sezilishi mumkin. Integrity testi o‘z sintetik ssenariysida blank yoki joyidan siljigan qator topmadi; bu barcha media va interaction kombinatsiyalariga kafolat emas.

Bu **har hajm uchun bittadan smoke run**. LaunchServices orqali avtomatlashtirilgan start yangi runni ishonchli boshlamagani uchun executable bevosita ishga tushirildi. 2k running bir qismi Rust build bilan, 10k running bir qismi qisqa probe compilation bilan bir vaqtda bo‘ldi. Focus, pointer va boshqa yuklar qat’iy laboratoriya darajasida nazorat qilinmadi. Shu sabab hajmlar orasidagi farqni sof A/B koeffitsiyenti sifatida talqin qilish mumkin emas.

Benchmark `PreviewBackend`, alohida benchmark preferences va sun’iy chat/media ishlatadi. Live decrypt, SQLite paging, real download, image/video playback, call, reconnect, boshqa account background eventlari va HangMonitor shu o‘lchovga kirmaydi. Sintetik audio/video fayllarning ayrimlari rendering stub’lari. Physical footprint yakuniy nuqtadagi o‘lchov; peak, 24 soatlik soak yoki leak yo‘qligi isboti emas.

Live idle CPU, battery/energy va rasmiy WhatsApp’ning xuddi shu workload’dagi CPU/RAM ko‘rsatkichlari bu auditda o‘lchanmadi. Benchmark frame-work millisekundlarini umumiy CPU foiziga aylantirish mumkin emas.

## Topilmalar

Prioritet: **P1** stable release oldidan, **P2** katta chat/media/call sifatini yaxshilash uchun, **P3** maintainer tajribasi va keyingi optimizatsiya. Jami 22 topilma. Xavf topilmalari tasdiqlangan crash deb ko‘rsatilmagan.

### F01. P1: parallel text layout ARC reference’larini bo‘shatmaydi

**Takrorlangan memory leak.** [TimelineLayoutEngine.swift:17](../../Packages/ZapFastKit/Sources/FeatureConversation/Timeline/TimelineLayoutEngine.swift#L17) `UnsafeMutableBufferPointer<BubbleLayout?>`ni initialize qiladi, obyektlarni joylaydi, qaytishda array’ga nusxalaydi va faqat `deallocate()` qiladi. Initialized elementlar `deinitialize()` qilinmaydi. Bufferning o‘z xotirasi ketadi, uning obyektlarga ARC retain’lari qoladi. Bu yo‘l `sources.count > 32`da ishlaydi.

Probe’da 8 layoutdan iborat serial batch tugagach weak reference `nil`; 64 layoutli parallel batchda `nil` emas. Cache’ni tozalash bu retain’larni qaytara olmaydi. Chat ochish, kenglik yoki theme o‘zgartirish ko‘p layoutni takroran yetim qoldirishi mumkin. Leakning sessiondagi aniq MiB/soat tezligi o‘lchanmadi.

Tuzatish: initialized buffer elementlarini deinitialize qilish yoki reference ownership’ini to‘g‘ri ko‘chiradigan safe tuzilma ishlatish. Qabul mezoni: ikkala lifetime testi o‘tsin; yuzlab chat/resize takroridan so‘ng live layout soni va memory plateau tekshirilsin. [Reproducer](reproducers/AuditLayoutLifetimeTests.swift), [natija](evidence/audit-layout-lifetime.log). Apple [deinitialize hujjati](https://developer.apple.com/documentation/swift/unsafemutablebufferpointer/deinitialize()) bu operatsiyani deallocation’dan alohida ko‘rsatadi.

### F02. P1: location xabari ko‘rinishi avtomatik Maps so‘rovini boshlaydi

**Kod bilan tasdiqlangan privacy boundary buzilishi.** [LocationContent.swift:65](../../Packages/ZapFastKit/Sources/FeatureConversation/Bubbles/LocationContent.swift#L65) view task’idan `load()` chaqiradi, :79 da snapshot so‘raydi. [MapSnapshots.swift:35](../../Packages/ZapFastKit/Sources/FeatureConversation/Bubbles/MapSnapshots.swift#L35) xabardagi koordinatalar atrofida region tuzib, `MKMapSnapshotter.start()` ishlatadi. “Open in Maps” bosilishi shart emas.

AGENTS.md message content’ni uchinchi tomonga yubormaslikni talab qiladi; location ham xabar tarkibi. Apple [Maps privacy hujjati](https://www.apple.com/legal/privacy/data/en/apple-maps/) map area chegaralari yuborilishini bayon qiladi. Xulosa API va kod yo‘liga asoslangan; aynan shu app trafikining paketlari ushlanmadi va matnli chatlar Apple’ga yuboriladi degan da’vo yo‘q.

Tuzatish: default preview uchun xabardagi thumbnail yoki lokal placeholder; tashqi Maps ochilishi faqat foydalanuvchining aniq harakati bilan. Qabul mezoni: location qatorini ko‘rsatish/scroll qilish network snapshot yaratmasin. MapKit so‘rovlari backend proxy konfiguratsiyasi bilan boshqarilayotgani ham ko‘rinmaydi.

### F03. P1: app lock video-call tasvirlarini yopmaydi

**Kod bilan tasdiqlangan, hardware’da takrorlanmagan.** [CallFace.swift:12](../../Packages/ZapFastKit/Sources/FeatureCalls/CallFace.swift#L12) lock holatida ism/avatarni yashiradi. Ammo [CallView.swift:19](../../Packages/ZapFastKit/Sources/FeatureCalls/CallView.swift#L19) `showsVideo` bo‘lsa lock’dan qat’i nazar video view’ni ochadi; [VideoCallContent.swift:20](../../Packages/ZapFastKit/Sources/FeatureCalls/VideoCallContent.swift#L20) remote video layer va :43 da camera preview’ni chizadi. [AppModel.swift:450](../../Packages/ZapFastKit/Sources/ZapFastCore/AppModel.swift#L450) lock’da playback/voice recording’ni to‘xtatadi, calls/camera yo‘liga tegmaydi.

Natijada lock screen paytida alohida call paneldan tasvir chiqishi va camera davom etishi mumkin. Audio qo‘ng‘iroqni lock’da qabul qilish ataylab qo‘llab-quvvatlangan bo‘lishi mumkin; video ko‘rinishi va capture uchun alohida aniq qoida kerak.

Tuzatish: lock paytida remote/local video va capture holatini siyosatga mos boshqarish. Qabul mezoni: active video, incoming video, voice-to-video upgrade va waiting call vaqtida lock/unlock sinovi; lock ortidan caller rasmi yoki frame ochilmasin.

### F04. P1: CI va release native mahsulotni qamramaydi

**Konfiguratsiya bilan tasdiqlangan.** [.github/workflows/ci.yml](../../../.github/workflows/ci.yml) root Rust egui build/test’larini qiladi; native Swift test, `macos/Bridge` workspace clippy/test va native Xcode Release gate yo‘q. Root `cargo audit` bridge’ning alohida lockfile’dagi qo‘shimcha dependency’larini alohida tekshirmaydi.

[release.yml:157](../../../.github/workflows/release.yml#L157) root `zapfast` binary’ni ikkala arxitekturaga build qilib, universal binary va upstream bundle script orqali DMG chiqaradi. Bu SwiftUI/AppKit native app emas. Tag chiqarilganda forkning nomi ostida boshqa interfeys tarqatilishi mumkin.

Tuzatish: native macOS CI va aynan native app/Share extension uchun release pipeline; engine va bridge lockfile’lari, Swift warning/test gate, arm64 Release build, paket identifikatori va native executable tekshiruvi. Upstream engine tekshiruvlarini saqlash mumkin, lekin ularning yashil chiqishi native app yashilligini anglatmasin.

### F05. P1: dependency license metadatasi bir xil emas, native notice’lar paketlanmagan

**Manba va paket bilan tasdiqlangan ochiq masala.** Root LICENSE MIT, Carmine Paolino attribution’ini saqlaydi. Pinned `whatsapp-rust` revision `f7468ae2920a2b0aedbd0848cf121de56a07f93c` ichidagi `wacore/libsignal/Cargo.toml` `MIT` deydi, lekin uning 31 source faylida `SPDX-License-Identifier: AGPL-3.0-only` bor. Masalan [session_cipher.rs](https://github.com/oxidezap/whatsapp-rust/blob/f7468ae2920a2b0aedbd0848cf121de56a07f93c/wacore/libsignal/src/protocol/session_cipher.rs#L1) va [manifest](https://github.com/oxidezap/whatsapp-rust/blob/f7468ae2920a2b0aedbd0848cf121de56a07f93c/wacore/libsignal/Cargo.toml).

Native [project.yml:35](../../project.yml#L35) Pidgin sound’larini qo‘shadi; root [THIRD-PARTY-NOTICES.md](../../../THIRD-PARTY-NOTICES.md) ular uchun GPL-2 matnini beradi. Tekshirilgan native `.app` Resources’da LICENSE/NOTICE fayllari yo‘q. Swift dependency privacy manifestlari borligi license notice o‘rnini bosmaydi.

Tuzatish: upstream’dan license nomuvofiqligini aniqlashtirish, tarqatiladigan dependency/asset inventory va mos notice’larni paketga qo‘shish, fork hissasini upstream credit’ni saqlagan holda ko‘rsatish. Manifestga qarab barcha binary dependency’larni “MIT only” deb yozmaslik. Ushbu audit butun appni qaysi litsenziyaga o‘tkazish kerakligi bo‘yicha huquqiy hukm chiqarmaydi.

### F06. P2: byte thumbnail cache eski ma’lumotni qaytaradi

**Takrorlangan.** [Thumbnails.swift:31](../../Packages/ZapFastKit/Sources/ZapFastDesign/Components/Thumbnails.swift#L31) cache key’da caller string va o‘lchamni ishlatadi, `Data` yoki content version’ni ishlatmaydi. Bir key bilan qizil, so‘ng ko‘k PNG berilganda aynan oldingi `NSImage` qaytdi. Picture/document callsite’lari ko‘pincha faqat message ID ishlatadi; account/chat key’da yo‘q. Accountlar orasida ID mos kelsa izolatsiya xavfi ham bor; real accountlarda collision takrorlanmadi.

Tuzatish: account, chat, message identity va thumbnail revision/content fingerprint. File URL yo‘lining account papkasi hamda mtime key’i bor, bu byte overload muammosidan farq qiladi. [Reproducer](reproducers/AuditCacheIsolationTests.swift), [natija](evidence/audit-cache-isolation.log).

### F07. P2: Lottie unpack cache accountlar orasida filename bilan to‘qnashadi

**Sun’iy ikki account fixture’ida takrorlangan.** [WasArchive.swift:48](../../Packages/ZapFastKit/Sources/ZapFastCore/Media/WasArchive.swift#L48) cache papkasini `file.lastPathComponent` orqali tanlaydi va oldingi animation bo‘lsa yangi faylni o‘qimaydi. [LottieStickerView.swift:37](../../Packages/ZapFastKit/Sources/FeatureConversation/Timeline/LottieStickerView.swift#L37) account’dan tashqaridagi umumiy Lottie papkasini beradi. Turli account papkalaridagi `same-message.was` uchun ikkinchi unpack birinchi animation JSON’ini qaytardi.

Tuzatish: account scope va to‘liq manba/content identity; eski umumiy cache’ga migratsiya/invalidation. Qabul mezoni: bir xil filename, turli content/account, account remove va sticker replacement testlari. [Reproducer](reproducers/AuditCacheIsolationTests.swift).

### F08. P2: video orientation keyingi call uchun reset qilinmaydi

**Takrorlangan.** [VideoRenderer.swift:44](../../Packages/ZapFastKit/Sources/ZapFastCore/Calls/Video/VideoRenderer.swift#L44) orientation o‘zgargandagina callback beradi; :53 dagi `reset()` atomic orientation’ni tiklamaydi. [CallStore.swift:244](../../Packages/ZapFastKit/Sources/ZapFastCore/Calls/CallStore.swift#L244) UI orientation’ni 0 qiladi. Ketma-ket ikki call bir xil 1 yoki 3 quarter-turn bilan boshlansa, ikkinchi call UI’ga rotation yetib bormaydi.

Probe `enqueue(1), reset(), enqueue(1)` uchun `[1, 1]` kutadi, `[1]` oladi. Tuzatish: renderer/UI stream state’ini birga reset qilish, eski call callback’ini yangi call’dan session identity bilan ajratish. [Reproducer](reproducers/AuditVideoOrientationTests.swift), [natija](evidence/audit-video-orientation.log).

### F09. P2: animated media decode va Lottie extraction uchun umumiy budjet yo‘q

**Resource exhaustion xavfi, OOM takrorlanmagan.** [AnimatedImage.swift:93](../../Packages/ZapFastKit/Sources/ZapFastDesign/Components/Motion/AnimatedImage.swift#L93) barcha frame’larni bir vaqtda decode qiladi. 48 MiB cache limit faqat decode tugagach qo‘llanadi; frame count, aggregate decoded byte va parallel task limiti yo‘q. Misol uchun 1,000 ta 640×640 RGBA frame taxminan 1.53 GiB pixel xotirasi talab qiladi, bu real o‘lchov emas. Swift yo‘li root `frames.rs`dagi 150 frame/two decoder himoyasini ishlatmaydi.

`WasArchive.Zip` har entry’ni 64 MiB bilan chegaralaydi, lekin barcha entry’larning umumiy hajmi, soni, extraction va disk budjeti yo‘q. Lottie decoded `NSCache`da count/cost limit belgilanmagan; unpack papkalari doimiy qoladi.

Tuzatish: frame/decoded-byte/in-flight budjet, bir fayl uchun parallel ishlarni birlashtirish, cancel/lazy decode, ZIP aggregate limit va disk cache eviction. Downloadning 64 MiB compressed limiti decoded memory limiti emas. Archive’dan tashqaridagi cache tozalash chat ma’lumotini yo‘qotmasin.

### F10. P2: barcha ko‘rilgan chatlar loaded history’sini ushlab qoladi

**Retention/scaling xavfi, F01’dan alohida.** [ConversationStore.swift:116](../../Packages/ZapFastKit/Sources/ZapFastCore/Stores/ConversationStore.swift#L116) har chat uchun slot saqlaydi, oddiy chat almashtirish uni evict qilmaydi. Ko‘p chatning ko‘p page’i session davomida yig‘iladi; hidden account model’lari ham o‘z store’lariga ega. Timeline layout/hosted height limitlari faqat chat almashganda tekshiriladi ([Updates.swift:50](../../Packages/ZapFastKit/Sources/FeatureConversation/Timeline/TimelineController+Updates.swift#L50)). Bitta juda katta chatda qat’iy budjet yo‘q.

Tuzatish: inactive loaded pages uchun byte/row budjet va archive’dan qayta paging, memory pressure’da trim; tanlov/jump/anchor holatini saqlash. Qabul mezoni: 50 chat × ko‘p page, account switch va katta chat resize’dan so‘ng bounded footprint. Local archive saqlanadi, o‘chirilmaydi.

### F11. P2: katta chatdagi event qo‘llash UI budjetidan oshadi

**Latency o‘lchangan, sabab kod bilan asoslangan.** [TimelineController+Updates.swift:133](../../Packages/ZapFastKit/Sources/FeatureConversation/Timeline/TimelineController+Updates.swift#L133) o‘zgargan xabarni topish uchun eski/yangi array’larni yuradi. Store update/merge va ayrim row diff yo‘llari ham history kattaligiga bog‘liq. Rendering virtualizatsiyasi bu model ishini avtomatik kamaytirmaydi.

10k benchmarkda current chat yangi message p50 19.83 ms, p95 22.83 ms; 120 Hz budjeti 8.33 ms. Resize p95 20.70 ms. Kuzatilgan scaling uchun maqsadli profil kerak; barcha xarajat faqat bir loop’dan keladi deb bo‘lmaydi.

Tuzatish: event o‘zgartirgan ID/index ma’lumotini saqlab, to‘liq array diff/copy ishini kamaytirish; row identity va order correctness’ni saqlash. Qabul mezoni: 10k/50k chatda receipt/reaction/new message va resize signpost’lari; o‘zgarishdan oldin/keyin takroriy Release A/B.

### F12. P2: eskirgan background layout natijasi cache’ga yoziladi

**Kod bilan tasdiqlangan ortiqcha ish xavfi.** [TimelineController+Updates.swift:339](../../Packages/ZapFastKit/Sources/FeatureConversation/Timeline/TimelineController+Updates.swift#L339) task o‘lchashdan qaytgach `store(layouts)` qiladi, keyin generation tekshiradi. Chat, width yoki theme allaqachon o‘zgargan bo‘lsa ham eski layout yangi cache’ni bosishi mumkin. Keyingi draw source/width’ni tekshirgani uchun bu o‘z-o‘zidan noto‘g‘ri bubble isboti emas, lekin qayta layout va ortiqcha CPU keltiradi. Eski tasklar cancel qilinmaydi.

Tuzatish: generation/cancellation check’ni store’dan oldinga qo‘yish, pending measurement’larni chegaralash. Qabul mezoni: tez resize/theme/chat switch burst’ida faqat amaldagi generation cache’ga o‘tsin, eskirgan batchlar ishni tugatishga majbur bo‘lmasin.

### F13. P2: eski history page “newest message” badge’iga qo‘shilishi mumkin

**Kod bilan tasdiqlangan hisoblash muammosi, UI repro bajarilmagan.** [TimelineController+Updates.swift:429](../../Packages/ZapFastKit/Sources/FeatureConversation/Timeline/TimelineController+Updates.swift#L429) bottom’ni follow qilmayotganda oldingi listda bo‘lmagan barcha incoming row’larni `newBelow`ga qo‘shadi. Tepadan yuklangan eski page uchun timestamp/old tail yoki insertion position bilan ajratish yo‘q.

Tuzatish: faqat oldingi tail’dan keyingi yangi delivery’larni hisoblash; history prepend/backfill’ni alohida ajratish. Qabul mezoni: o‘quvchi yuqorida turib eski page yuklasa badge oshmasin, yangi jonli message kelsa oshsin, anchor saqlansin.

### F14. P2: SQLite/Keychain va shutdown kutishlari main-thread yo‘lida

**Kod bilan tasdiqlangan bloklanish xavfi.** [CallHistory.swift:26](../../Packages/ZapFastKit/Sources/ZapFastCore/Calls/CallHistory.swift#L26) chat birinchi ochilganda synchronous FFI read qiladi. Rust [history.rs:185](../../Bridge/src/calls/history.rs#L185) SQLite mutex ostida chat call history’sini to‘liq oladi. [client.rs:88](../../Bridge/src/client.rs#L88) start’da call log/Keychain ochadi. Shutdown’da [pump.rs:64](../../Bridge/src/pump.rs#L64) thread join qiladi; safety receive timeout 1 sekund, backend shutdown ham kutishi mumkin. [AccountHub.swift:125](../../Packages/ZapFastKit/Sources/ZapFastCore/Accounts/AccountHub.swift#L125) accountlarni ketma-ket yopadi.

Bu audit live DB latency o‘lchamadi. Cold disk, Keychain prompt yoki band mutex chat ochish, account removal va quit’ni ushlab turishi mumkin. Tuzatish: thread ownership’ini saqlagan holda async read/start/stop va aniq completion, stop signal bilan pump’ni darhol uyg‘otish, natijani account/generation bilan bog‘lash.

### F15. P2: live call video backpressure va camera xatosi to‘liq boshqarilmagan

**Kod bilan tasdiqlangan, qo‘ng‘iroqda stress qilinmagan.** [VideoRenderer.swift:49](../../Packages/ZapFastKit/Sources/ZapFastCore/Calls/Video/VideoRenderer.swift#L49) har `Data` uchun serial queue closure qo‘shadi; :92 sample’ni renderer’ga readiness tekshirmay beradi. Rust chegarasidagi bounded queue Swift queue va renderer backlog’ini chegaralamaydi. Apple [queued renderer readiness hujjati](https://developer.apple.com/documentation/avfoundation/avqueuedsamplebufferrendering/isreadyformoremediadata) buffer qabul qilish qobiliyatini nazorat qilish uchun mo‘ljallangan.

[CallCamera.swift:39](../../Packages/ZapFastKit/Sources/ZapFastCore/Calls/Video/CallCamera.swift#L39) camera’ni async ochadi, ammo `start()` :62 da oldindan `true` qaytaradi. Input yaratish/configuration xatosi caller’ga qaytmaydi; UI camera on deb qolishi mumkin. Device interruption/unplug/sleep recovery jonli tekshirilmagan.

Tuzatish: per-stream bounded pending frame queue, renderer readiness va delay metrikasi; H.264 reference zanjirini buzadigan frame drop’dan keyin keyframe recovery. Camera start/failure/interruption event’larini CallStore’ga yetkazish. Decode va camera xatolari foydalanuvchiga aniq ko‘rinsin.

### F16. P2: multi-account qo‘ng‘iroqlar uchun process media arbitraji ko‘rinmaydi

**Integratsiya xavfi, real ikki account call takrorlanmagan.** Har account o‘z CallStore/CallAudio/CallCamera’sini oladi. Busy/waiting holati shu account call center’i doirasida; AccountHub’da umumiy microphone/camera ownership yo‘li ko‘rinmaydi. Ikki account bir vaqtning o‘zida call qabul qilsa audio engine va hardware bir-biriga halaqit berishi mumkin.

Tuzatish: yangi feature qo‘shmasdan process darajasidagi media ownership va ikkinchi account uchun aniq busy/answer oqimi. Qabul mezoni: A account active audio/video, B account incoming va outgoing, account switch, A unlink va app lock. Qo‘ng‘iroq natijalari doimo kelib chiqqan account’ga qaytsin.

### F17. P2: uzun audio/recording to‘liq PCM bufferlarda saqlanadi

**Scaling xavfi.** [VoicePlayer.swift:191](../../Packages/ZapFastKit/Sources/ZapFastCore/Media/VoicePlayer.swift#L191) Opus’ni butun Float array’ga, so‘ng AVAudioPCMBuffer’ga decode qiladi; boshqa audio uchun butun `file.length` bufferi ajratiladi. Seek qolgan segmentni nusxalaydi. [VoiceRecorder.swift:295](../../Packages/ZapFastKit/Sources/ZapFastCore/Media/VoiceRecorder.swift#L295) yozilgan sample’larni session davomida saqlaydi; preview/save yo‘llari qo‘shimcha buffer oladi. 48 kHz mono Float32 taxminan 11 MiB/minut, bu formuladan chiqqan baho, o‘lchangan peak emas.

Tuzatish: uzoq audio uchun streaming/scheduled chunk yoki aniq PCM/duration budjet; recording’ni vaqtinchalik lokal faylga yozish va bounded waveform. Qabul mezoni: uzun clip va 30 minut recording/cancel/preview stress’i, barqaror peak va tez cleanup. Oddiy qisqa voice message ishlashi suite’da tekshirilgan, ushbu xavf ular buzilganini anglatmaydi.

### F18. P3: idle yo‘li mutlaqo timer’siz emas

**Kod bilan tasdiqlangan, energy qiymati o‘lchanmagan.** [HangMonitor.swift:32](../../Packages/ZapFastKit/Sources/ZapFastCore/Services/HangMonitor.swift#L32) Release live app’da taxminan 10 Hz main-queue ping qiladi, `Thread.sleep(0.1)` bilan doimiy yuradi. Bridge har account uchun 1 sekund safety poll qiladi. Benchmark live startup’dan oldin alohida yo‘lga o‘tadi va bu observer’larni qamramaydi.

“Zero idle CPU/wakeups” kabi da’voga dalil yo‘q. Tuzatish: hang diagnostikasi chastotasi va enable policy’sini o‘lchov bilan tanlash, idle/background wakeup va Energy Log’ni o‘lchash. Monitor xabar content’ini log qilmay, code-address diagnostikasini ishlatishi ijobiy.

### F19. P2: quality/sync/build skriptlarida drift bor

**Takrorlangan va konfiguratsiya bilan tasdiqlangan.** Native warning gate Xcode 27’da quyidagilar bilan FAIL: [ChatInfoPanel.swift:140](../../Packages/ZapFastKit/Sources/FeatureConversation/Info/ChatInfoPanel.swift#L140) `@Entry` closure dependent’larni har update’da invalidate qilishi mumkin; [DebugCommands.swift:613](../../Packages/ZapFastKit/Sources/ZapFastShell/Debug/DebugCommands.swift#L613) explicit Selector warning. Bu toolchainga bog‘liq; Xcode 26’da aynan shu warning chiqishi tekshirilmadi.

[sync-upstream.sh:26](../../Scripts/sync-upstream.sh#L26) `git merge --no-edit upstream/main` qiladi, bu divergent tarixda AGENTS.md’ning linear main/no merge commit talabiga zid. [build-bridge.sh:32](../../Scripts/build-bridge.sh#L32) cargo build/generator uchun `--locked` bermaydi.

Tuzatish: supported stable toolchain’da warnings gate, qo‘shimcha beta compatibility job; fixture’dagi aniq warninglarni bartaraf etish; upstream integratsiyasini linear policy’ga mos qilish; release/CI generator va Rust build’larni locked yuritish. Audit davomida merge yoki dependency yangilash bajarilmadi.

### F20. P3: public hujjatlar va distribution holati native forkka mos emas

**Repository/paket bilan tasdiqlangan.** Root README va install/release ko‘rsatmalari upstream multiplatform egui mahsulotini tushuntiradi. Native yo‘l `macos/README.md`da qolgan; root’da calls capability ham upstream holatiga qarab yozilgan. Native bridge update eventlarini UI’ga o‘tkazmaydi; native updater tayyor deb ko‘rsatish uchun dalil yo‘q. Hozir faqat `upstream` remote bor, forkning `origin`i konfiguratsiya qilinmagan.

Lokal native app taxminan 55 MiB, hardened runtime bilan **Apple Development** imzosida. Bu boshqa Mac’da Gatekeeper/notarization orqali tarqatishga tayyorligini ko‘rsatmaydi. `DEVELOPMENT_TEAM` project’da hardcoded. Public source contributor uchun dokumentlangan unsigned/ad-hoc build yo‘li, stable binary uchun Developer ID/notarization/stapling va fresh-Mac install tekshiruvi kerak. Apple [distribution hujjati](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) shu jarayonni tasvirlaydi.

[TimelineController.swift:170](../../Packages/ZapFastKit/Sources/FeatureConversation/Timeline/TimelineController.swift#L170) private `allowedPocketEdges` selector’larini ishlatadi. `responds(to:)` guard mavjud, ammo OS o‘zgarishlariga compatibility xavfi qoladi. Supported OS matrix’da tekshirish va public API fallback kerak; App Store’ga chiqarish ushbu vazifada so‘ralmagan.

Tuzatish: root README’da native macOS fork, original credit, platform/hardware/build talablari, experimental calls, known issues, privacy va update usulini aniq yozish; screenshotlarni sun’iy chatlardan olish; release va contribution ko‘rsatmalarini native yo‘lga bog‘lash.

### F21. P2: engine/bridge event backlog’i chegaralanmagan

Root backend command/event kanallari va bridge wake kanali unbounded. [src/backend.rs:1068](../../../src/backend.rs#L1068), [pump.rs:31](../../Bridge/src/pump.rs#L31) va [Backend.swift:133](../../Packages/ZapFastKit/Sources/ZapFastCore/Backend/Backend.swift#L133) birgalikda burst’ni main queue’ga batchlar bilan uzatadi, qat’iy pending-byte/main-frame budjet yo‘q. Wake coalescing mavjudligi ijobiy, lekin event backlog’ini o‘z-o‘zidan chegaralamaydi.

Bu auditda burst OOM yoki event yo‘qolishi takrorlanmadi. Live first-sync/multi-account yukida queue depth, pending bytes va UI apply duration’ni o‘lchash kerak. Presence/typing kabi xavfsiz latest-state eventlarini birlashtirish mumkin; message/deletion/poll/history order eventlarini ko‘r-ko‘rona tashlash mumkin emas. Tuzatish upstream worker’ni kengaytirishdan oldin bridge delivery budjeti doirasida ko‘rib chiqilsin.

### F22. P2: UI’siz engine unit-test targeti compile bo‘lmaydi

**Takrorlangan.** `cargo test --locked --offline --no-default-features --lib` exit 101 bilan tugadi: [worker.rs:9720](../../../src/backend/worker.rs#L9720) va :9722 dagi test `crate::markup::plain`/`Mention` ishlatadi, `markup` esa `ui` feature ortida. `cargo clippy --no-default-features --lib` PASS bo‘lgani test targetining compile bo‘lishini tekshirmaydi.

Production engine va native Release build o‘tdi; bu runtime crash emas, aynan engine-only regression suite’da integration chegarasi buzilgan. Tuzatish: shared matn semantikasini engine’da saqlash yoki faqat UI assertion’ini tegishli feature bilan ajratish, protokol assertion’larini engine testida qoldirish. Qabul mezoni: UI’siz engine unit-test command ham CI’da o‘tsin. [Compile dalili](evidence/audit-engine-tests.log).

## Tayyor va tugallanmagan imkoniyatlar

“Kodda bor” real WhatsApp account bilan bu auditda jonli tekshirildi degani emas. Faqat protobuf’da maydon borligi capability hisoblanmadi. Missing feature’lar doimiy product exclusion deb belgilanmadi.

| Imkoniyat | Native forkdagi holat | Amaliy chegara / audit bahosi |
|---|---|---|
| QR/link, multi-account | UI va bridge mavjud | Live relink/recovery auditda bajarilmadi; personal archive saqlash chegarasi muhim |
| Matn, quote/reply, edit, forward, reactions | Implementatsiya mavjud | Core va UI fixture’lari o‘tdi; barcha server reject kombinatsiyalari jonli tekshirilmadi |
| Delete for me / everyone, clear/delete chat | Bridge engine commandlariga ulanadi | Upstream sync integration bor; root 0.19 tarixiy limitation’ini native’ning doimiy exclusion’i deb yozmaslik |
| Pin, favorites, archive, mute, read state, labels | Implementatsiya mavjud | Sync tartibi engine zimmasida; reconnect/multi-device E2E hali alohida gate talab qiladi |
| Search, older history, gap reload, export | Implementatsiya mavjud | Telefon eski tarixni qaytarishi kafolatlanmaydi; eksport lokal arxivning bor qismini beradi |
| Photo/video/GIF/document/audio | Receive/send/preview yo‘llari bor | 64 MiB attachment download limiti; Swift decode budjet muammolari F09/F17 |
| Voice messages, waveform, playback/recording | Native AVFoundation + engine codec | Uzun PCM scaling va device-route stress hali tekshirilmagan |
| WebP va Lottie sticker, favorites/packs | Native yo‘llar mavjud | Eski limitations hujjatining “Lottie yo‘q” degan bandi hozirgi native implementatsiyani ifodalamaydi; F07/F09 |
| Poll create/vote/results | Engine/bridge/UI mavjud | Recovery telefon history’siga bog‘liq; receipt/order testlari jonli account o‘rnini bosmaydi |
| Interactive quick reply, single-select, copy code | Known capability’lar bilan mavjud | Arbitrary Flow/payment action’lari to‘liq emas; visible label’ni plain-text reply sifatida yubormasligi to‘g‘ri |
| Carousel/unsupported/phone-only messages | Mos preview yoki placeholder | Har protocol family’ga to‘liq action mavjud degan da’vo yo‘q |
| Contact, profile, privacy settings | Bridge command va UI mavjud | Multi-device/private ID holatlarini qo‘shimcha jonli test qilish kerak |
| Group info/name/photo va invite join | Implementatsiya mavjud | Admin rights bilan gated; create group/community yoki to‘liq participant admin mahsuloti sifatida ko‘rsatmaslik |
| Location/live-location ko‘rsatish | Receive/display yo‘li mavjud | Send/live tracking lifecycle uchun to‘liq native workflow tasdiqlanmadi; avtomatik map privacy F02 |
| App lock / locked chats | Implementatsiya mavjud | App lock ekran himoyasi, encryption’ning o‘zi emas; video-call lock bo‘shlig‘i F03 |
| 1:1 outgoing/incoming voice call | **Haqiqiy implementatsiya bor** | Rust VoIP, MLOW/libopus, 16 kHz mono/60 ms, Swift AVAudioEngine voice processing; bu auditda Android/iPhone bilan live call qilinmadi |
| 1:1 video va voice-to-video upgrade | **Haqiqiy implementatsiya bor** | H.264, AVCaptureSession, VideoToolbox, 720p/20 fps/~1.5 Mbit/s; native rotation bug F08, resource/failure yo‘llari F15 |
| Group voice call | Kod va panel mavjud | Real ko‘p peer/multi-device stress yo‘q; incoming group video voice bilan qabul qilinadi |
| Group video | **Tugallanmagan** | Native README ham “not yet” deydi; guruh video button/display workflow yo‘q |
| Waiting call | Bir active + bir waiting | End & Accept/Decline; uchinchi call phone’da qoladi, native queue yo‘q |
| Hold/transfer | Native workflow topilmadi | Upstream protobuf mavjudligi bilan capability e’lon qilinmaydi |
| Screen sharing, call-link/join UI | Native workflow topilmadi | Upstreamdagi signal/helper’larni capture/render/product support bilan tenglashtirmaslik |
| Call history | Lokal encrypted per-account store + phone sync | Telefonning to‘liq oldingi call log’i pairingda keladi; oldin linked device uchun tarix to‘liq bo‘lmasligi mumkin |
| Status/story publishing, communities, channel management | To‘liq native mahsulot workflow’i tasdiqlanmadi | Rasmiy app bilan feature parity deb reklama qilishga asos yo‘q; protokol/engine imkoniyatini alohida tekshirish kerak |
| Native automatic updater | Native UI integration topilmadi | Upstream egui updater’i avtomatik ravishda native forkni yangilamaydi |
| Intel/macOS 14 | Amaldagi native build yo‘li bilan qo‘llanmaydi | Minimum 15 va arm64’ni public README’da ochiq yozish kerak |

Asosiy dalillar: [Bridge commands](../../Bridge/src/commands.rs), [calls integration](../../Bridge/src/calls/mod.rs), [CallStore](../../Packages/ZapFastKit/Sources/ZapFastCore/Calls/CallStore.swift), [native calls tavsifi](../../README.md#voice-calls), [interactive compatibility](../../../docs/interactive-message-actions.md).

### Qo‘ng‘iroq stack’i haqidagi qo‘shimcha izoh

Calls shunchaki qo‘yilgan button emas: bridge pinned `whatsapp-rust` uchun `voip` feature yoqadi, Swift audio va hardware codec’ni ulaydi. Native `CallAudio` system voice processing’ni yoqadi; kutubxonaning o‘zida DSP cheklovi borligi “appda echo cancellation yo‘q” degan xulosaga asos bo‘lmaydi.

Pinned upstream [VoIP conformance hujjati](https://github.com/oxidezap/whatsapp-rust/blob/f7468ae2920a2b0aedbd0848cf121de56a07f93c/agent_docs/voip_conformance.md) protocol/crypto fixture coverage’ni beradi va ayrim media differential trace’lari hali yetishmasligini ochiq aytadi. Bu har Android/iPhone, network va device-route kombinatsiyasining live mosligini isbotlamaydi.

Repository’dagi 2026-10-02 [limitations hujjati](../../docs/whatsapp-rust-limitations.md) foydali, ammo barcha bandlarini hozirgi fakt sifatida ko‘chirish mumkin emas. Masalan native Lottie allaqachon bor; RTCP report’dagi optional BWE maydonlarning nol ekanligi butun transportda barcha congestion/NACK mexanizmi yo‘qligini yakka o‘zi isbotlamaydi. “Experimental” release yorlig‘i tavsiyasi bu auditning live coverage va ochiq native call muammolariga asoslangan bahosidir.

## Stable release oldidan ish tartibi

1. **F01 memory leak**, **F02 automatic location request**, **F03 lock/video** uchun focused fix va regression test. Shaxsiy data bilan test qilish majburiy emas.
2. **F04 native CI/release**: native executable, Share extension, test suite va ikkala Rust workspace’ni gated qilish. **F05 license/notice** masalasini aniqlashtirish. Lokal Development imzosini release approval deb qabul qilmaslik.
3. **F06/F07/F08** takrorlangan functional muammolarni yopish. Proberlarni normal test suite’ga tegishli mavzudagi regression test sifatida ko‘chirish.
4. **F09/F10/F11/F12** bo‘yicha decoded media/cache/session budjeti va long-chat main-thread profil. F13 badge uchun paging regressioni. Crash/latency proof bo‘lmagan xavflarni o‘lchab prioritetni yangilash.
5. Calls uchun explicit experimental status va Android/iPhone, route/sleep/network/multi-account matrix. Group video/screen sharing/call-link kabi hali to‘liq bo‘lmagan imkoniyatlarni bor deb e’lon qilmaslik.
6. Root README, build instructions, fork credit, license notices, known issues, privacy policy va native manual-update/release yo‘lini tayyorlash. Keyin alohida GitHub fork remote va release jarayoni.

Audit faqat tekshiruv va artefakt yaratdi. App implementatsiyasi, dependency yoki workflow o‘zgartirilmadi; commit, push, tag, merge, release yoki foydalanuvchining WhatsApp holatiga amaliy action bajarilmadi.

## Yetishmayotgan live validation va taqqoslash protokoli

| Yo‘nalish | Keyingi sinov | Hozirgi dalil chegarasi |
|---|---|---|
| Scroll | 2k/10k/50k mixed chat, juda uzun matn, RTL/emoji, interactive/carousel, sweep selection, top paging | Hozir ikki synthetic smoke run, integrity’da 0 missing/misplaced |
| Memory | 1/3 account, 50 chatni qayta ochish, yuzlab resize/theme, 2 soat va overnight soak, memory pressure | Hozir snapshot + F01 lifetime proof; plateau/peak yo‘q |
| CPU/energy | 15 min idle visible/hidden, background incoming burst, first sync/decrypt, playback/call; Instruments Time Profiler/Allocations/Energy | Hozir live process CPU/energy benchmark yo‘q |
| Voice calls | Android va iPhone, inbound/outbound, mute, busy/waiting, Bluetooth/wired/default route, no mic permission, unplug, sleep/wake | Kod/fixture mavjud; live audit yo‘q |
| Video calls | Portrait/landscape, ketma-ket calls, upgrade/reject, camera permission/failure, slow renderer, loss/bandwidth, lock | Rotation reset probe FAIL, qolganlari static |
| Group calls | 3+ peer, peer join/leave/reject, caller yo‘qolishi, group-video voice-only answer | Native code bor, live coverage yo‘q |
| Account/privacy | Background account notification/read-state, delete callback, simultaneous calls, lock/unlock | Fixture coverage bor, to‘liq E2E yo‘q |
| Archive/recovery | Fixture’da locked/missing Keychain, migration failure, reconnect/deletion barrier, poll/edit order | Shaxsiy archive ochilmagan; barcha recovery yo‘llari jonli audit qilinmagan |
| Distribution | Fresh Apple Silicon Mac, stable macOS 15/26+, notarized ZIP/DMG, extension, Keychain continuity across update | Hozir OS27 beta hostdagi lokal arm64 build/imzo |
| Dependency/security | Ikkala Cargo.lock uchun yangi RustSec scan, Swift dependency inventory, full secret/history scan | Format/clippy/test bunday scan o‘rnini bosmaydi |

Rasmiy WhatsApp bilan performance nisbatini e’lon qilish uchun bir Mac, bir OS/display, har ikki appning aniq versiyasi, taqqoslanuvchi chat/media hajmi, cold/warm ta’rifi va kamida uch marta navbatma-navbat run kerak. Screen/scroll capture, launch-to-interactive, hitch ms/s, p95 event latency, physical-footprint peak/steady, idle/scroll/call CPU va energy alohida berilsin. Official client’ning user data’sini agent o‘qimasdan, foydalanuvchi o‘zi mos sintetik test account yoki natijalarni tayyorlashi kerak.

Hozir dalil bilan yozish mumkin bo‘lgan ta’rif: “Apple Silicon uchun SwiftUI/AppKit native WhatsApp companion client, Rust engine asosida; Release sintetik benchmarkida 2,000 xabarli timeline 120 Hz scroll sinovidan yaxshi o‘tdi. Qo‘ng‘iroq qo‘llab-quvvatlashi rivojlanish bosqichida.” “Bir necha marta tez”, “zero CPU”, “leak-free” va “to‘liq feature parity” hozir o‘lchov bilan himoyalanmaydi.
