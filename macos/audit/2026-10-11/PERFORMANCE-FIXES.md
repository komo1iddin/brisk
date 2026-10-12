# Native audit: performance tuzatishlari

Branch: `codex/native-audit-fixes`. Birinchi bosqichdan keyin media va katta
chat xarajatlari fixture va sintetik Release benchmark bilan tekshirildi.

| Topilma | Holat va dalil |
|---|---|
| F09 | Frame decode: 150 frame, 24 MiB decoded pixels, max 2 decoder, source/size bo‘yicha coalescing va cancellation. Hover qaytishi tugayotgan cancelled decode’dan yangi job oladi; source size/existence fresh filesystem metadata bilan tekshiriladi. ZIP: serial extraction, 256 entry, 64 MiB compressed/aggregate, 8 MiB JSON; malformed empty deflate/stored size rad etiladi. Lottie: serial/coalesced parse, 32 pending, 24-entry/estimated-cost cache. Derived disk cache: 64 folder/256 MiB, active leases saqlanadi. Animation, ZIP, lease/pruning va Lottie regressionlari PASS. OOM yoki hostile Lottie model heap real peak’i o‘lchanmadi; NSCache cost va pinned disk istisnolari hard process-memory guarantee emas. |
| F12 | Eskirgan batch cache’dan oldin generation/cancellation guard bilan rad etiladi. Bir active parallel batch va har timeline uchun bitta latest pending snapshot; cancel frame/row orasida tekshiriladi. 3 cancellation regression + mavjud layout/lifetime testlari PASS. |
| F13 | Badge oldingi message tail’dan keyingi incoming insertion’larni sanaydi. History prepend/gap fill va initial page sanalmaydi; same-second live va own-message/deleted-tail holatlari 3 test bilan PASS. |
| F10 | Inactive model retention hal qilindi: per account max 8 chat/12k row, LRU eviction, memory-pressure trim, open pane/window va running history request himoyasi; qayta ochishda archive reload. 50 × 3k inactive + 15k open fixture, pressure/reload testlari va mavjud merge/account testlari: 17 PASS. Active cache va har pane uchun 1 200 row / 16 MiB hisoblangan payload budjeti, 900-row headroom, ikkala yo‘nalishda 60-row paging, bounded jumps va independent reader qo‘shildi. Selection archive’dan off-main o‘qiladi; gallery/Info lifetime va partial-clear mosligi saqlanadi. Single oversized record va explicit action record/output istisnolari bor. 50k final synthetic Release’da peak footprint 673 → 216 MiB, total RSS hard cap emas. |
| F11 | Live merge’da qo‘shni order tekshiruvi, 32-revision journal va store-owned ID indeksi bor. Bir row refresh uchun butun `Item` array nusxalanmaydi. Keyingi bosqichda message snapshotlar 256-record bloklarga o‘tdi: bir live mutation kichik blokni nusxalaydi. Anchor/jump row ID indeksidan foydalanadi; width-only resize nested layout’ni majburlamaydi. 50k snapshot va width/reflow/height anchor regressionlari PASS. Bottom fading blur AppKit’ga o‘tdi, layout cache loaded window bilan prunelanadi. Hidden hosting layout guard va composer/search safe-area hisobini qisqartirish tekshirildi, resize profile’da wallpaper/placeholder work 0. Umumiy p95, Here CPU va scroll/flick metrikalari barqaror yaxshilanmadi; full rebuild, hosted row va AppKit window layout/display xarajati ochiq. F11 umumiy performance qismi to‘liq yopilmadi, 120 Hz kafolati yo‘q. |
| F14 | Call history account’ning serial queue’sida async o‘qiladi; coalescing, off-main FFI va eski snapshot ustidan yangi report ustunligi tekshirildi. Startup Keychain/SQLite ochilishi va backend/pump shutdown kutishlari hali ochiq. |
| F15 | Native video inbox: 8 unit/4 MiB, bitta drain, max unit 1 MiB. Overflow/readiness failure’dan keyin keyframe recovery va max 1 request/s. Camera start/failure/interruption store’ga yetadi; eski kamera callback’i yangi call’ni o‘chira olmaydi. Audio restart failure call’ni xato bilan tugatadi. Queue va mock capture regressionlari PASS; real device/network stress hali tekshirilmagan. |
| F16 | Shared process media owner, pending place/answer reservation, boshqa account uchun busy notice va removal/unlink teardown qo‘shildi. Kechikkan permission/call/camera callback’lari va ikki account mock oqimlari PASS. Real ikki account audio/video call sinovi ochiq. |

[Budjet va fallback xatti-harakati](../../../docs/_reference/native-macos-media-budgets.md).
[Bounded history cache](../../../docs/_reference/native-macos-history-cache.md).
[Tekshiruv va performance dalillari](PERFORMANCE-VALIDATION.md).
[Katta chat/resize/call bosqichi va dalillari](LARGE-CHAT-CALL-VALIDATION.md).
[Active-history/resize yakuniy dalillari](../2026-10-12/ACTIVE-HISTORY-RESIZE.md).
F11 umumiy CPU/frame-time, F14 startup/shutdown va real hardware/network
call tekshiruvi ochiq.
Real user archive o‘qilmadi;
barcha fixture vaqtinchalik va sintetik.
