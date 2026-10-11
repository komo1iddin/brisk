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
| F04 | Native CI va native release artifact yo‘li | Rejalashtirilgan |
| F05 | Native license/notice resources, dependency license inventory | Rejalashtirilgan; upstream license nomuvofiqligi aniqlashtirilishi kerak |

CI’ni ishlatishga to‘sqinlik qilayotgan F19 native warning va F22 engine-only test compile masalalari ham ushbu bosqichning quality gate qismida hal qilinadi. Qolgan performance xavflari keyingi bosqich uchun auditda saqlanadi. Missing call feature’lar ushbu bug-fix bosqichiga kirmaydi.

GitHub push, release, notarization submission yoki upstream’ga xabar yuborish ushbu ishda bajarilmaydi. Release uchun mavjud bo‘lmagan credential yoki upstream license clarification talab qilinsa, uning holati aniq qayd etiladi.

F06 testining dastlabki rang fixture’i Xcode 27 beta muhitida bir xil PNG baytlarini yaratgan. Raw RGBA fixture va baytlar farqliligini tekshirish bilan almashtirildi. Tuzatilgan test eski key algoritmida ikkita assertion bilan yiqildi, yangi algoritmda o‘tdi. Audit reproducer’i ham tuzatildi.
