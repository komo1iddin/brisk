# Native audit: performance tuzatishlari

Branch: `codex/native-audit-fixes`. Birinchi bosqichdan keyin media va katta
chat xarajatlarini fixture bilan tekshirish davom etmoqda.

| Topilma | Holat va dalil |
|---|---|
| F09 | Frame decode: 150 frame, 24 MiB decoded pixels, max 2 decoder, source/size bo‘yicha coalescing va cancellation. ZIP: serial extraction, 256 entry, 64 MiB compressed/aggregate, 8 MiB JSON; malformed empty deflate/stored size rad etiladi. Lottie: serial/coalesced parse, 32 pending, 24-entry/estimated-cost cache. Derived disk cache: 64 folder/256 MiB, active leases saqlanadi. 19 Core/Design + 5 Lottie focused test PASS. OOM yoki hostile Lottie model heap real peak’i o‘lchanmadi; NSCache cost va pinned disk istisnolari hard process-memory guarantee emas. |

[Budjet va fallback xatti-harakati](../../../docs/_reference/native-macos-media-budgets.md).
F10/F11 loaded history va event latency, F12 stale background layout va
F13 history badge keyingi tekshiruv mavzulari. Real user archive o‘qilmadi;
barcha fixture vaqtinchalik va sintetik.
