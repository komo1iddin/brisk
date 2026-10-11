# Native audit: performance tuzatishlari

Branch: `codex/native-audit-fixes`. Birinchi bosqichdan keyin media va katta
chat xarajatlari fixture va sintetik Release benchmark bilan tekshirildi.

| Topilma | Holat va dalil |
|---|---|
| F09 | Frame decode: 150 frame, 24 MiB decoded pixels, max 2 decoder, source/size bo‘yicha coalescing va cancellation. Hover qaytishi tugayotgan cancelled decode’dan yangi job oladi; source size/existence fresh filesystem metadata bilan tekshiriladi. ZIP: serial extraction, 256 entry, 64 MiB compressed/aggregate, 8 MiB JSON; malformed empty deflate/stored size rad etiladi. Lottie: serial/coalesced parse, 32 pending, 24-entry/estimated-cost cache. Derived disk cache: 64 folder/256 MiB, active leases saqlanadi. Animation, ZIP, lease/pruning va Lottie regressionlari PASS. OOM yoki hostile Lottie model heap real peak’i o‘lchanmadi; NSCache cost va pinned disk istisnolari hard process-memory guarantee emas. |
| F12 | Eskirgan batch cache’dan oldin generation/cancellation guard bilan rad etiladi. Bir active parallel batch va har timeline uchun bitta latest pending snapshot; cancel frame/row orasida tekshiriladi. 3 cancellation regression + mavjud layout/lifetime testlari PASS. |
| F13 | Badge oldingi message tail’dan keyingi incoming insertion’larni sanaydi. History prepend/gap fill va initial page sanalmaydi; same-second live va own-message/deleted-tail holatlari 3 test bilan PASS. |
| F10 | Inactive model retention hal qilindi: per account max 8 chat/12k row, LRU eviction, memory-pressure trim, open pane/window va running history request himoyasi; qayta ochishda archive reload. 50 × 3k inactive + 15k open fixture, pressure/reload testlari va mavjud merge/account testlari: 17 PASS. Active-chat row/byte limit va ikki tomonlama paging qismi ochiq. |
| F11 | Live merge’da full ascending scan o‘rniga qo‘shni order tekshiruvi. 32-revision journal timeline’ga faqat edited indeks va append range beradi; coalesced, missing revision, regroup/reorder/history/delete holatlari tekshirilgan. Store-owned reference ID indeksi live insert/update scan’ini olib tashlaydi va UI snapshotlaridan alohida turadi. Time Profiler bitta row refresh’da butun `Item` array copy’ini tasdiqladi; main actor endi o‘zgargan row’ni o‘z array’ida yangilaydi. Coalesced receipt/reaction/append bilan reading anchor va selection regressioni PASS. Message array copy, boshqa lookup va resize scaling yo‘llari hali mavjud. |

[Budjet va fallback xatti-harakati](../../../docs/_reference/native-macos-media-budgets.md).
[Inactive history cache](../../../docs/_reference/native-macos-history-cache.md).
[Tekshiruv va performance dalillari](PERFORMANCE-VALIDATION.md).
F11 qolgan scaling yo‘llari va F10 active-history qismi ochiq.
Real user archive o‘qilmadi;
barcha fixture vaqtinchalik va sintetik.
