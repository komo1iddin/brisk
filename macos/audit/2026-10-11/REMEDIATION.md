# Native audit: birinchi tuzatish bosqichi

Scope: foydalanuvchi tanlovi bo‘yicha P1 masalalar va test bilan tasdiqlangan buglar. Branch: `codex/native-audit-fixes`. Har mavzu alohida commit, fixture va tegishli tekshiruv bilan yopiladi.

| Topilma | Ish | Holat |
|---|---|---|
| F01 | Parallel layout ownership va lifetime regressioni | Yopildi: buffer deinitialize; 7 batch chegarasi va 20 takroriy parallel batch lifetime testi PASS |
| F02 | Location preview uchun automatic Maps network access’ni olib tashlash | Yopildi: MapKit snapshot yo‘li olib tashlandi; lokal preview uchun 3 test PASS; privacy hujjati yangilandi |
| F03 | Lock’da call video/camera himoyasi | Yopildi: video yashiriladi, camera o‘chadi, unlock capture’ni qaytarmaydi; lock/permission-race/UI policy va mavjud calls testlari PASS |
| F06 | Thumbnail content invalidation va account/chat identity | Yopildi: SHA-256 content key, account/chat scope, preview task reload/cancellation; 4 regression test PASS, eski key bilan negative control FAIL |
| F07 | Lottie cache identity/izolatsiyasi | Yopildi: source path/content hash, account ichida derived cache, replacement va source removal regressioni; 8 archive + 5 Lottie test PASS |
| F08 | Video stream reset va orientation regressioni | Yopildi: serialized reset/submission, stream generation guard, first-frame rotation; 0/1/3 rotation va stale callback test PASS |
| F04 | Native CI va native release artifact yo‘li | Implementatsiya tayyor: native reusable CI, arm64 app/Share/notice validator, native draft release; local full rehearsal va workflow/shell lint PASS. Hosted/signing/notarization rehearsal hali bajarilmagan |
| F05 | Native license/notice resources, dependency license inventory | Lokal qismi tayyor: 517 Rust package + 2 Swift pin inventari, mavjud license matnlari, bundle resources va Help menyusi; upstream MIT/AGPL clarification va missing text/distribution review ochiq |

CI’ni ishlatishga to‘sqinlik qilayotgan F19 native warning va F22 engine-only test compile masalalari ham ushbu bosqichning quality gate qismida hal qilinadi. Qolgan performance xavflari keyingi bosqich uchun auditda saqlanadi. Missing call feature’lar ushbu bug-fix bosqichiga kirmaydi.

GitHub push, release, notarization submission yoki upstream’ga xabar yuborish ushbu ishda bajarilmaydi. Release uchun mavjud bo‘lmagan credential yoki upstream license clarification talab qilinsa, uning holati aniq qayd etiladi.

F06 testining dastlabki rang fixture’i Xcode 27 beta muhitida bir xil PNG baytlarini yaratgan. Raw RGBA fixture va baytlar farqliligini tekshirish bilan almashtirildi. Tuzatilgan test eski key algoritmida ikkita assertion bilan yiqildi, yangi algoritmda o‘tdi. Audit reproducer’i ham tuzatildi.

Quality gate: F19 tuzatildi, dismissInfo popover identity bo‘yicha comparable action;
Debug selector runtime lookup bilan olinadi. Forced source warning check PASS.
F22 tuzatildi: faqat egui mention display assertion’i `ui` feature ostida;
protocol assertions engine-only testda ham qoladi. Root engine: 555 PASS,
8 ignored. Root fmt, default/all-feature clippy va tests, rustdoc: PASS.
Native full suite: 489 PASS (410 Core, 69 Conversation, 8 Chats, 2 Calls).

F05 to‘liq yopilmadi. `release-license-review.json` pending; aynan shu native
lock’lar uchun asoslangan review bo‘lmaguncha binary release to‘xtaydi.
[Upstream savol draft’i](UPSTREAM-LICENSE-QUESTION.md) tayyor, yuborilmagan.
Native `.app` Resources’dagi LICENSE, THIRD-PARTY-NOTICES.md va
DEPENDENCY-LICENSES.md real unsigned Release bundle’da tekshirildi.

Yakuniy tekshiruvlar: [VALIDATION.md](VALIDATION.md). 10k sintetik Release
scroll’da 39,707 qator tekshirildi, 0 missing / 0 misplaced. Full-scroll p95
2.74 ms, p99 3.58 ms, physical footprint 108.08 MiB. Bu bitta post-fix run;
repeat A/B, real account CPU/energy va rasmiy WhatsApp taqqoslashi bajarilmagan.
F09 to F18, F20 to F21 ushbu bosqichga kirmaydi, audit backlog’ida qoladi.

Keyingi performance bosqichida F09, F12 va F13 uchun tuzatishlar,
F10 inactive retention va F11 live-event xarajatlari uchun qisman tuzatishlar
amalga oshirildi. Joriy holat va dalillar:
[PERFORMANCE-FIXES.md](PERFORMANCE-FIXES.md).

Katta chat, resize va qo‘ng‘iroq lifecycle’ining keyingi tuzatishlari:
[LARGE-CHAT-CALL-VALIDATION.md](LARGE-CHAT-CALL-VALIDATION.md).
