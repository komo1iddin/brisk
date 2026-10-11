# Native audit: birinchi tuzatish bosqichi

Scope: foydalanuvchi tanlovi bo‘yicha P1 masalalar va test bilan tasdiqlangan buglar. Branch: `codex/native-audit-fixes`. Har mavzu alohida commit, fixture va tegishli tekshiruv bilan yopiladi.

| Topilma | Ish | Holat |
|---|---|---|
| F01 | Parallel layout ownership va lifetime regressioni | Yopildi: buffer deinitialize; 7 batch chegarasi va 20 takroriy parallel batch lifetime testi PASS |
| F02 | Location preview uchun automatic Maps network access’ni olib tashlash | Rejalashtirilgan |
| F03 | Lock’da call video/camera himoyasi | Rejalashtirilgan |
| F06 | Thumbnail content invalidation va account/chat identity | Rejalashtirilgan |
| F07 | Lottie cache identity/izolatsiyasi | Rejalashtirilgan |
| F08 | Video stream reset va orientation regressioni | Rejalashtirilgan |
| F04 | Native CI va native release artifact yo‘li | Rejalashtirilgan |
| F05 | Native license/notice resources, dependency license inventory | Rejalashtirilgan; upstream license nomuvofiqligi aniqlashtirilishi kerak |

CI’ni ishlatishga to‘sqinlik qilayotgan F19 native warning va F22 engine-only test compile masalalari ham ushbu bosqichning quality gate qismida hal qilinadi. Qolgan performance xavflari keyingi bosqich uchun auditda saqlanadi. Missing call feature’lar ushbu bug-fix bosqichiga kirmaydi.

GitHub push, release, notarization submission yoki upstream’ga xabar yuborish ushbu ishda bajarilmaydi. Release uchun mavjud bo‘lmagan credential yoki upstream license clarification talab qilinsa, uning holati aniq qayd etiladi.
