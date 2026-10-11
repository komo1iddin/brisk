# Native audit: performance tuzatishlari

Branch: `codex/native-audit-fixes`. Birinchi bosqichdan keyin media va katta
chat xarajatlarini fixture bilan tekshirish davom etmoqda.

| Topilma | Holat va dalil |
|---|---|
| F09 | Frame decode: 150 frame, 24 MiB decoded pixels, max 2 decoder, source/size bo‘yicha coalescing va cancellation. ZIP: serial extraction, 256 entry, 64 MiB compressed/aggregate, 8 MiB JSON; malformed empty deflate/stored size rad etiladi. Lottie: serial/coalesced parse, 32 pending, 24-entry/estimated-cost cache. Derived disk cache: 64 folder/256 MiB, active leases saqlanadi. 19 Core/Design + 5 Lottie focused test PASS. OOM yoki hostile Lottie model heap real peak’i o‘lchanmadi; NSCache cost va pinned disk istisnolari hard process-memory guarantee emas. |
| F12 | Eskirgan batch cache’dan oldin generation/cancellation guard bilan rad etiladi. Bir active parallel batch va har timeline uchun bitta latest pending snapshot; cancel frame/row orasida tekshiriladi. 3 cancellation regression + mavjud layout/lifetime testlari PASS. |
| F13 | Badge oldingi message tail’dan keyingi incoming insertion’larni sanaydi. History prepend/gap fill va initial page sanalmaydi; same-second live va own-message/deleted-tail holatlari 3 test bilan PASS. |
| F10 | Inactive model retention hal qilindi: per account max 8 chat/12k row, LRU eviction, memory-pressure trim, open pane/window va running history request himoyasi; qayta ochishda archive reload. 50 × 3k inactive + 15k open fixture, pressure/reload testlari va mavjud merge/account testlari: 17 PASS. Active-chat row/byte limit va ikki tomonlama paging qismi ochiq. |

[Budjet va fallback xatti-harakati](../../../docs/_reference/native-macos-media-budgets.md).
F11 event latency va F10 active-history qismi keyingi tekshiruv mavzulari.
Real user archive o‘qilmadi;
barcha fixture vaqtinchalik va sintetik.
