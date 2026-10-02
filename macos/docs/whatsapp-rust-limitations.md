# whatsapp-rust: nimani qila olmaydi

Sana: 2026-10-02. Kutubxona: `whatsapp-rust` 0.7.0, rev `f7468ae` (2026-09-24), ZapFast
`Cargo.toml` va `macos/Bridge/Cargo.toml` da shu revision mahkamlangan.
Maqsad: rasmiy WhatsApp bilan solishtirganda qaysi imkoniyatlar kutubxonada umuman yo'q,
qaysilari yarim tayyor va qaysi chegaralar protokolning o'zidan kelishini bilish.

Kutubxona kodi diskda: `~/.cargo/git/checkouts/whatsapp-rust-6e26428647c827f3/f7468ae`.
Quyida `R/` shu papkani bildiradi, `file:N` esa qator raqami.

## 0. Usul va ishonchlilik

- To'rt agent kutubxona manbasini faqat o'qigan (xabarlar, guruh/kanal/status/profil,
  qo'ng'iroqlar, protokol va hamrohlik darajasi). Hech narsa jonli serverga qarshi ishga
  tushirilmagan. Foydalanuvchi ma'lumoti (archive.db) o'qilmagan.
- Men o'zim qayta tekshirganlar: 31 ta faylda AGPL sarlavhasi, `preserve_unknown_fields(false)`,
  Bridge'da `voip` yoqilgani.
- "Topilmadi" degani qidirib topilmadi degani, yo'qligining isboti emas. Taxmin
  (INFERENCE) deb belgilanganlar kod bilan tasdiqlanmagan.
- `gh` tizimga kirmagani uchun upstream'ning ochiq issue'lari o'qilmagan. Hujjatlar sayti
  (whatsapp-rust.jlucaso.com) ham ko'rilmagan, faqat repo ichidagi `agent_docs/`.
- Kutubxona tarixi (git log) va kod ichidagi issue raqamlari yopilgan muammolarni ko'rsatadi,
  hozirgi ochiq xatolarni emas.

## 1. Qisqa xulosa

1. Kutubxona faqat hamrohlik (companion) qurilma: WhatsApp Web kabi. Asosiy telefon bo'lib
   ishlay olmaydi, shuning uchun ro'yxatdan o'tish, akkauntni o'chirish, raqamni almashtirish,
   rasmiy backup umuman yo'q.
2. Kutubxonada kontakt, chat yoki xabar ombori yo'q. Hammasi hodisa sifatida keladi, saqlash
   ilovaning ishi (ZapFast'da `archive.db`).
3. "Yo'q" ko'p hollarda "yozilgan helper yo'q" degani. Xom protobuf yoki to'rtta chiqish yo'li
   orqali qo'lda qurish mumkin (2-bo'lim).
4. Eng og'ir tuzilmaviy chegara: tarixni, app-state kalitlarini va tiklashni telefon beradi.
5. Eng ahamiyatli tuzatiladigan bo'shliq: 66 ta ma'lum app-state verb'ning 45 tasi dekodlanib
   tashlab yuboriladi (LID kontakt nomlari ham shular orasida). Tuzatish faqat upstream'da.
6. Qo'ng'iroqlar bor, lekin relay-only, DSP yo'q, jonli tekshiruv kam.
7. Litsenziya: `wacore/libsignal` ichida 31 fayl AGPL-3.0-only, manifest esa MIT.

## 2. Arxitektura faktlari

- Yagona yuborish primitivi: `Client::send_message(to, wa::Message)` (`R/src/send/mod.rs:1035`).
  Protobuf'da ifodalanadigan hamma narsa yuboriladi. Stanza `type`, `mediatype`, `edit`,
  `<meta>`, `<biz>`/`<bot>` va reporting token protobuf'dan avtomatik chiqariladi
  (`R/wacore/src/send/classify.rs:77,177`).
- Protobuf juda yangi (`pollCreationMessageV6`, `musicMessage`, `pollAddOptionMessage`).
- Kontakt ombori yo'q: `R/wacore/src/types/events.rs:1062`.
- To'rtta chiqish yo'li, "yo'q" ni "tayyor helper yo'q" ga aylantiradi:
  - `Client::execute(IqSpec)` (`R/src/request.rs:459`);
  - `Client::mex().query/mutate` va generatsiya qilingan GraphQL amallar
    (`R/src/features/mex.rs:243`, `R/wacore/src/iq/mex_operations.rs`);
  - `Client::send_app_state_action` / `remove_app_state_action`
    (`R/src/features/chat_actions.rs:1011/:1038`, `whatsapp_rust::schemas`);
  - `Client::query_usync` (`R/src/usync.rs:68`) va `send_node`.
- Bizning Bridge shu `Client` ga `zapfast::backend::set_client_hook` orqali chiqadi
  (`macos/Bridge/src/calls/mod.rs`), ya'ni bu to'rt yo'ldan upstream fayllariga tegmasdan
  foydalanish mumkin.

## 3. Xabarlar

Belgilar: **SUPPORTED** (helper bor), **PARTIAL** (yarim yoki qo'lda protobuf),
**RECEIVE-ONLY**, **PROTO-ONLY** (protobuf maydoni bor, kod yo'q), **ABSENT**.

| Imkoniyat | Holat | Dalil va izoh |
|---|---|---|
| Oddiy matn | SUPPORTED | `send_text` `R/src/send/mod.rs:1054` |
| Matn formati | PARTIAL | WA belgilari (`*b*`, `_i_`) shunchaki matn, parser yo'q |
| Mention | PARTIAL | `ContextInfo.mentioned_jid` qo'lda; builder va ism-JID hal qilish yo'q |
| @everyone | PROTO-ONLY | `ContextInfo.nonJidMentions` (`whatsapp.proto:1726`), simlari tasdiqlanmagan |
| Reply/quote | SUPPORTED | `build_quote_context` `R/wacore/src/proto_helpers.rs:699` |
| Tahrirlash | SUPPORTED | `edit_message` `R/src/client/messaging.rs:170`; 20 daqiqa faqat qabulda tekshiriladi |
| Hamma uchun o'chirish | SUPPORTED | `revoke_message` `R/src/send/actions.rs:18`; admin revoke faqat guruhda |
| O'zimdan o'chirish | SUPPORTED | `delete_message_for_me` (app-state) |
| Reaksiya | SUPPORTED | `send_reaction` `R/src/features/reaction.rs:35` |
| Forward | SUPPORTED | `forward_message` `R/src/send/mod.rs:1078`; `forwarding_score` hisoblanadi |
| View-once yuborish | PARTIAL | `Options` da `view_once` yo'q, `image_message.view_once = Some(true)` qo'lda |
| Yo'qolib ketadigan xabarlar | PARTIAL | taymer: `set_chat_disappearing_timer` `R/src/client/iq_ops.rs:160`, guruhda `set_ephemeral`; har yuborishda `with_ephemeral_expiration` ni ilova o'zi qo'yadi, o'chirishni ham ilova qiladi |
| Yulduzcha | SUPPORTED | `star_message` (app-state) |
| Chatda xabarni qadash | SUPPORTED | `pin_message` `R/src/send/actions.rs:99`; kanalda yo'q |
| Rasm/video/hujjat/audio | SUPPORTED | `Client::upload` `R/src/upload.rs:409`; thumbnail, davomiylik, mimetype ni ilova beradi |
| Ovozli xabar (PTT) | SUPPORTED | `AudioOptions{ptt, waveform}`; Opus kodlash va to'lqinni ilova qiladi |
| GIF | SUPPORTED | `VideoOptions.gif_playback` |
| Stiker | PARTIAL | builder yo'q, `StickerMessage` qo'lda; WebP konvertatsiyasi yo'q |
| Stiker paketlari | PARTIAL | `create_sticker_pack_zip` (60 tagacha), "proto-level helpers" |
| Lottie stiker | PROTO-ONLY | `is_lottie: Some(false)` qattiq yozilgan |
| Albom | PARTIAL | `wrap_as_album_child` bor, ota `AlbumMessage` builder yo'q |
| HD media | PROTO-ONLY | `midQualityFileSha256`, `MediaQualitySetting` kodda ishlatilmaydi |
| Dumaloq video (PTV) | PARTIAL | builder yo'q |
| Yuklash | PARTIAL | 5 MiB dan davom ettiriladi; `upload(Vec<u8>)` butun faylni xotirada ushlaydi; o'lcham tekshiruvi yo'q |
| Muddati o'tgan media | SUPPORTED | `media_reupload().request` `R/src/features/media_reupload.rs:85`; `download` buni o'zi chaqirmaydi; kanalda yo'q |
| Link preview yaratish | ABSENT | OG scraping yo'q, `ExtendedTextMessage` ni ilova to'ldiradi |
| Kontakt kartasi | PARTIAL | `ContactMessage`, vCard generator/parser yo'q |
| Statik joylashuv | PARTIAL | `LocationMessage`, builder yo'q |
| Jonli joylashuv | PROTO-ONLY | boshlang'ich yuborish tasniflanadi, yangilash/to'xtatish mexanizmi topilmadi |
| So'rovnoma | SUPPORTED, bo'shliqlar bilan | `Polls::create/vote/decrypt_vote` `R/src/features/polls.rs`; kelgan ovozlar o'zi shifrdan chiqmaydi; tahrirlash/variant qo'shish/yopish yo'q; `message_secret` ni ilova saqlaydi |
| Tadbirlar (Events) | PARTIAL | `Events::create/respond`; RSVP ni ochish qabulga ulanmagan; bekor qilish yo'q |
| Interaktiv/tugmali | PARTIAL | faqat `interactive_message` uchun `<biz>` avtomatik; `buttons_message` va `template_message` ga mediatype yo'q |
| To'lov/buyurtma/katalog | RECEIVE-ONLY + o'qish | `Business::get_catalog/get_collections/get_order` faqat o'qiydi; to'lov yuborish yo'q |
| Meta AI / botlar | PARTIAL | `@bot` JID ga yuborish va `msmsg` ni ochish bor; guruhda chaqirish builder yo'q |
| Tarjima | ABSENT | topilmadi |
| Ovozli xabar transkripti | ABSENT | faqat `BotPttPromptMetadata.transcript` (protobuf) |
| Rejalashtirilgan xabar | PROTO-ONLY | `ScheduledMessageMetadata`; `MESSAGE_SCHEDULE` ochishdan chiqarib tashlangan |
| Qoralama | ABSENT | kutubxonada yo'q (ZapFast'da lokal bor, `Command::SaveDraft`) |
| Serverda xabar qidirish | ABSENT | topilmadi |
| Receipts | SUPPORTED | `mark_as_read` `R/src/receipt.rs:1054`, `mark_as_played` `:1115`; o'qish receipti avtomatik yuborilmaydi |
| Retry va PDO | SUPPORTED | `R/src/retry.rs:328`, `R/src/pdo.rs:61`; link-preview va stiker re-upload PDO natijalari qayta ishlanmaydi |
| O'ziga xabar | SUPPORTED | helper yo'q, o'z JID'iga yuboriladi |
| Spam xabari | SUPPORTED | `send_spam_report` `R/src/spam_report.rs:34` |
| Chat limit-sharing | PARTIAL | guruhda `set_limit_sharing`; DM darajasidagi protokol xabari ishlanmaydi |
| msg_secret | SUPPORTED | `R/src/message/msg_secret.rs`; saqlangan sirni olish uchun ochiq getter topilmadi |

Qabul qilishda:

- `Event::Messages(MessageBatch)` har bir ochilgan xabarni xom `wa::Message` bilan beradi
  (`R/src/message/receive.rs:1961`). Reaksiya, tahrir, o'chirish uchun alohida hodisa yo'q.
- Noma'lum protobuf maydonlari tashlanadi: `preserve_unknown_fields(false)`
  (`R/waproto/build.rs:210`). Yangi xabar turi bo'sh yoki qisman kelishi mumkin. Xom baytni faqat
  `Event::DecryptedPayload` (`client.acquire_decrypted_payload_forwarding()`) orqali olish mumkin.
- Noma'lum `<enc type>` logga yoziladi va tashlanadi (`R/src/message/receive.rs:370-381`).

## 4. Guruh, jamoa, kanal, status, profil

### Guruhlar (`R/src/features/groups.rs`)

To'liq qo'llab-quvvatlanadi: yaratish, metadata, a'zo qo'shish/chiqarish/admin qilish,
mavzu va tavsifni o'zgartirish, rasm (`set_profile_picture`, JPEG ~640x640), faqat-adminlar
yozishi, info qulfi, a'zo qo'shish rejimi, qo'shilish tasdig'i va so'rovlarni ko'rish,
taklif havolasi (yaratish, bekor qilish, qo'shilish, ko'rib chiqish), ephemeral taymer, chiqib
ketish, `set_no_frequently_forwarded`, `report_messages_to_admins`.

Bo'shliqlar:

- Yangi a'zolarga guruh tarixini yuborish: faqat sozlama tugmalari
  (`set_group_history`), `message_history_bundle` yuboruvchisi yo'q.
- Mention helper yo'q.
- Guruh qo'ng'irog'i: cargo feature orqasida, 5-bo'limga qarang.

### Jamoalar (`R/src/features/community.rs`)

Yaratish, kichik guruh yaratish/ulash/uzish, `join_subgroup` bor. Egasini almashtirish
(`transfer_community_ownership`, MEX) generatsiya qilingan, lekin hech joyda chaqirilmaydi.
Kichik guruh takliflari parsing qilinadi, API yo'q. E'lonlar guruhi serverda yaratiladi,
alohida API yo'q.

### Kanallar (`R/src/features/newsletter.rs`)

Bor: ro'yxat, qo'shilish/chiqish, metadata, tarix (`get_messages`), reaksiya, yaratish,
`update`, rasm, matnli post yuborish va tahrirlash/o'chirish (`send_message` bilan
`@newsletter` JID ga).

Yo'q yoki qisman:

- Admin sifatida media post: kanal uchun yuklash yo'li topilmadi.
- Admin taklif oqimi (`create_/accept_/revoke_newsletter_admin_invite`): generatsiya qilingan,
  chaqiruvchisi yo'q.
- Katalog, qidiruv, tavsiya qilinganlar (`fetch_newsletter_directory_*`): chaqiruvchisi yo'q.
- Kanal sozlamalari (`settings: None` qattiq yozilgan), pin yo'q, `forwardedNewsletterMessageInfo`
  qurilmaydi. Ko'rishlar soni faqat tarixdan o'qiladi. Jonli yangilanish obunasi ~90 soniyada
  tugaydi va yangilanishi kerak.

### Status (`R/src/features/status.rs`)

Bor: matn/rasm/video yuborish, o'chirish (`revoke`), ko'rilgan deb belgilash
(`mark_as_read(status_broadcast)`), reaksiya, status mute.

Yo'q: auditoriya ro'yxatlari (`status_privacy` app-state tanilgan, lekin hech kim ishlamaydi),
status lentasi (xabarlar `status@broadcast` dan oddiy yo'l bilan keladi), javob helperi.
Qabul qiluvchilar ro'yxatini har postga ilovaning o'zi hisoblaydi.

### Profil

Bor: push name (`R/src/features/profile.rs:77`), About (`set_status_text`), o'z va boshqalarning
rasmi (`Contacts::get_profile_picture`), biznes profili o'qish.
Qisman: `@username` (o'qish bor, o'rnatish va band emasligini tekshirish ataylab o'rab
qo'yilmagan; `find_by_username` "Experimental"). Yo'q: avatarlar, boyitilgan matn statusi.

## 5. Maxfiylik, presence, kontaktlar, chat amallari, qurilmalar, akkaunt

| Imkoniyat | Holat | Izoh |
|---|---|---|
| Maxfiylik toifalari (last seen, online, rasm, About, guruhga qo'shish, o'qish receipti, qo'ng'iroq, xabarlar) | SUPPORTED | `fetch/set_privacy_setting` `R/src/client/iq_ops.rs:97,117`; "except" ro'yxatlari bor; boshqa qurilmadagi o'zgarish haqida bildirishnoma ishlovchisi yo'q |
| Disappearing default | PARTIAL | o'rnatish bor, hisob standartini o'qish yo'q (`R/src/handlers/notification/device.rs:91`) |
| Blok ro'yxati | SUPPORTED | `Blocking` `R/src/features/blocking.rs`; LID-PN moslik kerak |
| Link-preview maxfiyligi | SUPPORTED | `set_link_previews_disabled` |
| Ikki bosqichli tekshiruv | topilmadi | |
| Passkey | PARTIAL | faqat bog'lash (login) oqimi, `passkey` feature; yaratish/ro'yxat/o'chirish yo'q |
| Presence | SUPPORTED | `set_available`, typing/recording, obuna; `PresencePolicy::Automatic` telefonga bildirishnomani to'xtatadi |
| Raqam bo'yicha qidirish | SUPPORTED | `Contacts::is_on_whatsapp` `R/src/features/contacts.rs:195` |
| Kontaktlar sinxroni | ABSENT | `UsyncMode::Delta` turi bor, chaqiruvchi yo'q |
| Saqlangan nomlar | PARTIAL | faqat app-state `contact` mutatsiyalari; `lid_contact`, `out_contact`, `pnForLidChat`, `shareOwnPn` ishlanmaydi |
| Biznes tasdiq belgisi | PARTIAL | `VerifiedName` olinadi, sertifikat tekshirilmaydi |
| Arxiv, pin, mute, yulduz, o'qilgan/o'qilmagan, tozalash, o'chirish, qulf | SUPPORTED | `R/src/features/chat_actions.rs` |
| Sevimlilar | RECEIVE-ONLY | yozish `send_app_state_action(&schemas::FAVORITES)` orqali |
| Teglar | SUPPORTED | `R/src/features/labels.rs`; maxsus ro'yxatlarda `type`/`order_index` yo'q |
| Tezkor javoblar | SUPPORTED | `R/src/features/quick_replies.rs` |
| Chat mavzusi (wallpaper) | PROTO-ONLY | `chatThemeSetting`, kodda yo'q |
| Oxirgi emojilar | PROTO-ONLY | `recentEmojiWeightsAction` registrda ham yo'q |
| Sevimli stikerlar | RECEIVE-ONLY | setter yo'q |
| Bog'langan qurilmalar ro'yxati | PARTIAL | faqat qurilma id'lari (`get_user_devices`), nom va oxirgi faollik yo'q |
| Boshqa qurilmani uzish | ABSENT | `RemoveCompanionDeviceSpec` har qanday JID oladi, lekin server ruxsat berishi isbotlanmagan; faqat o'zini uzadi (`Client::logout`) |
| Yangi raqam (primary) | ABSENT | SMS/OTP kodi yo'q |
| Raqamni almashtirish | RECEIVE-ONLY | faqat boshqalarniki (`ContactNumberChanged`) |
| Akkauntni o'chirish, backup, chat eksporti | ABSENT | kutubxonada ombor yo'q; `create_labyrinth_backup` (MEX) generatsiya qilingan, chaqiruvchisi yo'q |

## 6. Qo'ng'iroqlar

README "1:1 audio" deydi, kod ancha ko'p. Vaqt: VoIP 2026-06-27 da qo'shilgan, 1:1 video
2026-07-16, guruh qo'ng'irog'i va call link 2026-07-29 (rev uchun ~3 oylik kod).

| Imkoniyat | Holat | Dalil |
|---|---|---|
| 1:1 ovoz, chiquvchi/kiruvchi | ishlaydi | `voip().call(..)` `R/src/client/voip.rs:1176`, `accept` `:1165` |
| Rad etish, tugatish | ishlaydi, rad etishda sabab yo'q | `reject` `:1100`, `build_reject` `count="0"` |
| 1:1 video (faqat H.264) | tajribaviy | `R/src/voip/video.rs:1-6`; ovozdan videoga ko'tarish bor |
| Guruh ovoz/video (32 tagacha) | tajribaviy | `R/wacore/src/types/group_call.rs:12`; guruhda kodek kelishuvi qamrab olinmagan |
| Call link va kutish xonasi | tajribaviy | `R/src/client/voip.rs:1286-1646` |
| Ekran ulashish | faqat signal | capture va alohida kodek yo'q |
| Qo'l ko'tarish, reaksiya | tajribaviy | guruh va link qo'ng'iroqlarida |
| Hold, ko'chirish, rejalashtirilgan, voicemail, sababli rad etish, avtomatik "band" | yo'q | |
| O'tkazib yuborilgan, boshqa joyda javob berilgan | ishlaydi | `Event::MissedCall`, `CallEndedElsewhere` |
| Qo'ng'iroq tarixi | faqat qabul | `Event::CallLogSync`; o'zimiz qilganlar tarixga yozilmaydi |
| Shifrlash | ishlaydi | E2E-SRTP + WARP + HBH; SFrame faqat qabulda |
| Relay | ishlaydi, faqat relay | UDP/DTLS/SCTP; 3480 port; 3478 da qarshi tomon oqimi qaytmaydi (#1098) |
| P2P, ICE, o'tkazuvchanlik baholash, tiqilish nazorati, NACK, FEC | yo'q | `rtcp.rs:573-575` nol bilan to'ldirilgan |
| Jitter bufer | qotirilgan, faqat PCM yo'lida | `R/wacore/src/voip/engine.rs:98-116` |
| Exo/shovqin bostirish, AGC | yo'q | ilova beradi |
| Kodeklar | MLOW (sof Rust), libopus | MLOW runtime kodlovchisi WhatsApp'nikidan baytma-bayt farq qiladi (ataylab) |

Tekshirilganlik: baytlar, kripto va kodek fixture'lari WhatsApp Web'ning wasm'iga qarshi
mahkam. Jonli qo'ng'iroq darajasida zaif: hujjatda bitta Android bilan to'liq ikki tomonlama
qo'ng'iroq (`agent_docs/voip_audio_codecs.md:94-95`). iPhone bilan sinov izi yo'q. 26 sekin
stsenariy ignore qilingan, "to'liq ekvivalentlik" da'vo qilinmaydi.

Server tomoni: `enable_web_calling`, `enable_web_group_calling` AB prop'lari odatda `false`
(`R/wacore/src/iq/abprops.rs:4765-4789`). Kutubxona ularni tekshirmaydi, ya'ni qo'ng'iroq
akkauntga qarab kelmasligi mumkin. Telefon tomonidan qilingan qo'ng'iroq soketga hech narsa
yubormaydi, faqat `CallLogSync`.

Feature'lar: VoIP default'da o'chiq (`R/Cargo.toml:206-214`). `voip` = `voip-mlow` +
`voip-libopus` + `voip-relay-native`. Bizda faqat `macos/Bridge/Cargo.toml` yoqadi.

## 7. Protokol va hamrohlik chegaralari

### Pairing va identifikatsiya

- QR (`R/src/pair.rs`), telefon raqami bilan kod (`R/src/pair_code.rs`), passkey
  (`passkey` feature, WebAuthn imzosini host beradi; macOS'da `rpId` `web.whatsapp.com`
  bo'lgani uchun native ilova buni o'zi hosil qila olmasligi taxmin qilinadi), Business (alohida
  oqim yo'q, shu yo'llar).
- Yangi raqamni primary sifatida ro'yxatdan o'tkazish yo'q.
- Aniqlik: `ClientProfile` (default `web()`: WEB, Desktop, os_version 0.1.0, mcc/mnc 000). Telefondagi
  "Linked devices" nomi `DevicePropsOverride` dan, faqat pairing paytida qo'llanadi.
- WA Web versiyasi: kompilyatsiya vaqtida `2.3000.1045368834`, har ulanishda `sw.js` dan olinadi,
  24 soat keshlanadi, native'da olinmasa ulanish yiqiladi. 405 da `ClientOutdated` chiqadi,
  avtomatik yangilanmaydi.

### Ko'p qurilma modeli

- Hamrohning o'z Signal identifikatori bor, telefon oddiy trafik uchun shart emas.
- Telefon onlayn bo'lishi kerak: PDO placeholder qayta yuborish, on-demand tarix, app-state
  kalitlari, snapshot tiklash (`R/src/pdo.rs:244`, `:333`). Telefon o'chiq bo'lsa jim kutadi.
- View-once, hosted va bot tarkibi hamrohga berilmaydi (`R/wacore/src/types/events.rs:1998`).
- Bitta jonli sessiya: `conflict replaced` yoki 409 da `StreamReplaced`, qayta ulanish o'chadi.
- Repoda yo'q (tashqi bilim): hamrohlar soni chegarasi (odatda 4) va ~14 kunlik faolsizlik
  qoidasi. Tasdiqlanmagan.

### Tarix sinxroni

- `HistorySyncConfig` (kunlar, hajm, chat boshiga xabarlar) mavjud, lekin default faqat `support_*`
  bayroqlarini qo'yadi; chegarani telefon hal qiladi. To'liq tarix uchun
  `with_require_full_sync(true)` va "win_hybrid" qatori kerak (`R/wacore/src/store/device.rs`).
- Kutubxona tarixni saqlamaydi: bitta `Event::HistorySync(LazyHistorySync)` beradi.
  Ochish chegarasi 64 MiB (`R/wacore/src/history_sync.rs:30`).
- Jim yo'qolish: qabul tasdig'i yuklashdan OLDIN yuboriladi, yuklash/parse xatosi faqat logga
  yoziladi, hodisa ham, qayta urinish ham yo'q (`R/src/history_sync.rs:~390-470`).
- Eski xabarlar: `fetch_message_history` (`R/src/pdo.rs:244`) telefonga so'rov yuboradi, javob
  keyin `HistorySync` bilan keladi. Kutubxona chegara qo'ymaydi. PDO placeholder 14 kundan
  eski xabarga yuborilmaydi (`R/src/pdo.rs:1069`).
- Faqat 3 ta PDO oqimi: placeholder resend, on-demand tarix, syncd snapshot tiklash.

### Hodisalar

`Event` `#[non_exhaustive]`, 75 variant (`R/wacore/src/types/events.rs:955-1175`): ulanish (14),
pairing (11), xabar (5), presence/identifikatsiya (13), guruh/kanal (3), qo'ng'iroq (4),
syncd (20), xom/diagnostika (5).

Xabar berilmaydigan yoki faqat xom keladiganlar: ishlovchisiz bildirishnoma turlari (`pay`,
`psa`, `hosted`, `waffle`, `w:growth`, `registration`, `server`, `fb:update`, ...) faqat
`Event::Notification` bilan, `mediaretry` faqat debug logda.

Yetkazish standart bo'yicha "ko'pi bilan bir marta": ack ilova saqlashdan oldin ketadi
(`R/src/types/durability_hook.rs:5-20`). `InboundDurabilityHook` "kamida bir marta" qiladi.
Kanal xabarlari va PDO bilan tiklanganlar hook'dan o'tmaydi.

## 8. App-state (syncd) verb'lar

- Kolleksiyalar: critical_block, critical_unblock_low, regular_low, regular_high, regular.
- Konflikt: 409 + `has_more` qayta yuklaydi; chiquvchi patch 5 martagacha qayta quriladi.
  400/404 fatal (`AppStateSyncFailed.fatal`), lekin kutubxona WA Web'dan farqli logout qilmaydi.
  Boshqa xatolarda kutish 1 s dan 1 soatgacha ikki baravar o'sadi, ulanishga 8 raund.
- Snapshot MAC mismatch'i telefondan so'raladi (`COMPANION_SYNCD_SNAPSHOT_FATAL_RECOVERY`),
  telefon o'chiq bo'lsa kolleksiya tiqilib qoladi.
- 66 ta e'lon qilingan verb (`R/src/appstate_known_verbs.rs:9`), 22 tasi ishlanadi, **45 tasi
  dekodlanib tashlanadi** (hodisa ham, xom hook ham yo'q; `AppStateDispatchOutcome::Unclaimed`,
  `R/src/client/app_state.rs:3677`):
  - Hisob va maxfiylik: `status_privacy`, `setting_chatLock`, `setting_locale`, `time_format`,
    `setting_relayAllCalls`, `setting_unarchiveChats`, `settings_sync`, `primary_feature`,
    `primary_version`, `nux`, `sentinel`.
  - Kontakt va identifikatsiya: `lid_contact`, `out_contact`, `pnForLidChat`, `shareOwnPn`,
    `avatar_updated_action`.
  - Ro'yxat va pin: `label_sublist`, `label_reordering`, `thread_pin`.
  - Qurilma va AI: `android_unsupported_actions`, `deviceAgent`, `agentChatAssignment*`,
    `external_web_beta`, `ai_thread_delete`, `ai_thread_rename`.
  - Biznes va to'lov: `business_broadcast_*`, `customer_data`, `custom_payment_methods`,
    `payment_info`, `payment_tos`, `marketingMessage*`, `note_edit`, `subscriptions_sync_v2`,
    `waffle_account_link_state`, `wasa_root_secret` va boshqalar.
- Registrda umuman yo'q (jim modellashtirilmagan): `recentEmojiWeights`, `usernameChatStartMode`,
  `privateProcessingSetting`, `notificationActivitySetting`, `musicUserId`,
  `statusPostOptInNotificationPreferences`.
- `resync_app_state_collection` (`R/src/client/app_state.rs:955`) bor.

## 9. Yetuklik, xavf, litsenziya

- Yetuklik: 0.7.0, ~1744 commit (~1550 tasi bitta muallifdan), `nightly-2026-06-16` mahkamlangan.
  Hujjatda 3643 lib testi o'tadi deyilgan. E2E testlar yopiq "bartender" mock serverga qarshi
  (`agent_docs/e2e_testing.md`), jonli WhatsApp qabul testi yo'q. Bitta flaky test hujjatlashtirilgan
  (`online_device_sync_releases_its_dedup_entry`, 1000 dan 729-takrorda). SQLite `Synchronous::Normal`
  to'satdan elektr o'chishida checkpoint'gacha yozilganni saqlamasligi mumkin.
- Tajribaviy/"hali yo'q" belgilari: `find_by_username` "Experimental"
  (`R/src/features/contacts.rs:473`), guruh qo'ng'irog'ida tctoken
  (`R/src/features/tctoken.rs:18`), biznes sahifalash (`R/src/features/business.rs:252`),
  poll `result_snapshot` TODO (`R/src/send/mod.rs:662`), advAccountType TODO
  (`R/src/client/device_registry.rs:1033`).
- LID/PN: ikki tomonlama kesh; LID kiritilganda PN moslik yo'q bo'lsa migratsiyalanmagan
  hisobda "400" bo'lishi mumkin (`R/src/client/lid_pn.rs:810`); login'da `lid_db_migrated=false`
  qattiq yozilgan (`R/wacore/src/store/device.rs:638-643`).
- Dekodlash xatolari: retry kvitansiyasi chegarasi 5, `UndecryptableMessage` 5 daqiqa dedup;
  protobuf'ga ochilmagan plaintext tashlanadi va ratchet allaqachon oldinga siljigan bo'ladi.
- Akkaunt xavfsizligi: README ogohlantiradi (Meta shartlariga zid, bloklanishi mumkin).
  `TemporaryBan` sabablari 101-106, 429 da qayta ulanish xatolari hisobi oshadi. Chat boshiga
  qayta yuborish limitchisi bor (20 burst, daqiqasiga 10), lekin **umumiy yuborish tezligini
  cheklash yo'q**: ilova o'zi sekinlatishi kerak. WAM telemetriya default'da o'chiq (436 hodisadan
  7 tasini chiqaradi), bu rasmiy mijozdan farq. Ban xavfiga ta'siri hujjatda aytilmagan.
- Rasmiy mijozdan farqlar: `lid_db_migrated=false`, soxta Chrome UA versiya so'rovida,
  `os_version` 0.1.0, WAM deyarli yo'q, Android attestatsiya yo'q, rustls ClientHello Chrome'dan
  farq qilishi taxmin qilinadi.
- **Litsenziya (tasdiqlangan):** `R/wacore/libsignal` ichida 31 ta faylda
  `SPDX-License-Identifier: AGPL-3.0-only`, `R/wacore/libsignal/Cargo.toml`, `R/Cargo.toml` va
  `R/LICENSE` esa MIT deydi. Tarqatiladigan ilova uchun hal qilinmagan savol. Bu yuridik maslahat
  emas. Hozir ZapFast faqat shaxsiy foydalanishda.
- Hujjat nomuvofiqliklari: `ClientProfile.phone_id` izohi eskirgan, `receipt.rs:760` da eskirgan
  "VoIP not implemented" xabari, `Cargo.toml` repository URL (jlucaso1) va upstream (oxidezap) farqi.

## 10. ZapFast holati

Upstream README "What it does not do yet" ro'yxati: qo'ng'iroqlar, status postlari, jamoalar,
kanallar, guruh boshqaruvi (a'zolar, adminlar, tavsif, sozlamalar), interaktiv shakllar, to'lov,
H.264 dan boshqa videolar.

Kutubxona qila oladi, ZapFast hali qilmaydi:

- Guruh boshqaruvi: a'zolar, adminlar, tavsif, taklif havolasi, qo'shilish so'rovlari, announce,
  locked, ephemeral. (Kutubxonada to'liq.)
- Jamoalar: yaratish, kichik guruhlar, qo'shilish.
- Kanallar: matnli post yuborish (media yo'q).
- Status: matn/rasm/video yuborish va ko'rish (lenta va auditoriyani o'zimiz qurishimiz kerak).
- Maxsus teglar ro'yxatlari, tezkor javoblar, blok ro'yxati, biznes katalogini o'qish, call link,
  guruh qo'ng'irog'i.

Fork'da (macOS): qo'ng'iroqlar `main` da (1:1 ovoz jonli tekshirilgan; video, guruh, kutish,
tarix jonli sinalmagan, xotira yozuviga ko'ra). Qoralamalar lokal arxivda saqlanadi
(`Command::SaveDraft`). Rasm sifati: `MediaQuality` standard 1600 px va HD 4096 px, JPEG
(`macos/Packages/ZapFastKit/Sources/ZapFastCore/Models/MediaEdit.swift:347`), protokol darajasidagi
HD belgisi va ikkilamchi yuklash yo'q.

## 11. Eng muhim bo'shliqlar

Ilova muallifi tuzata olmaydi (tuzilmaviy):

1. Faqat hamrohlik: ro'yxatdan o'tish, o'chirish, raqam almashtirish, rasmiy backup yo'q.
2. Tarix, kalitlar va tiklash telefonda; telefon o'chiq bo'lsa jim kutish.
3. Meta shartlari, ban xavfi, server versiyani kesishi (405), `client_expiration`.
4. Protokol qayta tiklangan (WA Web bundle'idan statik tahlil): har bir o'zgarish kutubxona
   relizini talab qiladi.
5. Server tomonidagi cheklovlar: web qo'ng'iroq AB prop'lari, bitta jonli sessiya, `available`
   presence telefon bildirishnomasini to'xtatishi.

Upstream'da yopilishi mumkin:

1. 45 ta tashlanadigan syncd verb, ayniqsa `lid_contact`, `pnForLidChat`, `status_privacy`,
   `setting_chatLock`, `label_*`. Ishlanmaydigan bildirishnoma turlari uchun xom hook.
2. Tarix bo'lagi yuklanmasa hodisa bermaslik; on-demand tarix chegaralari va
   `FULL_HISTORY_SYNC_ON_DEMAND`, `HISTORY_SYNC_CHUNK_RETRY` PDO oqimlari.
3. Versiyani 405 da avtomatik yangilash.
4. Noma'lum protobuf maydonlarini saqlash (yoki yangi xabar turi uchun hook).
5. Yuborish tezligini cheklash.
6. macOS'da ishlatsa bo'ladigan passkey autentifikatori.
7. Litsenziya metama'lumotlari (AGPL sarlavhalari va MIT).

## 12. "Kutubxonada yo'q" bandlarini biz amalga oshira olamizmi?

Savol: 3 va 5-bo'limlardagi "yo'q" bandlarni ZapFast (macOS) tomonida qilib bo'ladimi.
Cheklov: upstream fayllariga tegilmaydi, hammasi `macos/` ichida (Swift va Bridge). Bridge
kutubxona `Client` ining o'ziga `set_client_hook` orqali chiqadi, ya'ni 2-bo'limdagi to'rtta
chiqish yo'li (xom protobuf, `execute`, `mex`, `send_app_state_action`) bizga ochiq.

Tekshiruv (2026-10-02, shu Mac, `sw_vers`: macOS 27.0, build 26A428): Apple'ning qurilma
ichidagi tillari. Ro'yxatlar OS versiyasiga va o'rnatilgan til paketlariga qarab farq qiladi.

| API | Tillar soni | O'zbek (`uz`) | Rus | Turk | Ingliz |
|---|---|---|---|---|---|
| `Translation` (`LanguageAvailability().supportedLanguages`) | 47 | yo'q | `ru-RU` | `tr-TR` | bor |
| `SFSpeechRecognizer.supportedLocales()` | 62 | yo'q | `ru-RU` | `tr-TR` | 13 variant |
| `SpeechTranscriber.supportedLocales` (macOS 26+) | 45 | yo'q | yo'q (bu ro'yxatda) | yo'q | bor |

### Natija bandma-band

| Band | Javob | Qanday va nima to'sqinlik |
|---|---|---|
| Boshqa bog'langan qurilmani uzish, qurilmalar metama'lumoti | Yo'q | `RemoveCompanionDeviceSpec` har qanday JID oladi, lekin hamrohning boshqa hamrohni uza olishi isbotlanmagan (WhatsApp Web'da ham "Linked devices" ekrani yo'q, bu taxmin). Qurilma nomi va oxirgi faolligi hamrohga berilmaydi, faqat id'lar. Sinab ko'rish xavfli: o'z sessiyamizni uzib qo'yishi mumkin. Telefonda qilinadi. |
| Ikki bosqichli tekshiruv, passkey yaratish | Yo'q | Asosiy qurilmaning xavfsizlik sozlamasi, kutubxonada kod yo'q, hamrohda UI ham yo'q. Passkey faqat bog'lashda kerak bo'lishi mumkin, QR va kod bilan bog'lash ishlaydi. |
| Kontaktlar sinxroni (address book yuklash) | Yuklash: yo'q. Nomlar: qisman | Yuklashni kutubxona qilmaydi va bu maxfiylik chegarasiga zid. Telefon yuborgan `contact` mutatsiyalarini ZapFast allaqachon oladi. Yetishmayotgani LID kalitli nomlar (`lid_contact`, `pnForLidChat`): tuzatish upstream'da. Ixtiyoriy mahalliy yo'l: Contacts.framework bilan raqamni Mac kontaktidagi nomga moslash (hech narsa yuklanmaydi, lekin ruxsat so'raladi; hozir loyihada Contacts ishlatilmaydi). |
| Yangi raqamni ro'yxatdan o'tkazish | Yo'q | Boshqa protokol (SMS/qo'ng'iroq OTP, attestatsiya), kutubxonada yo'q, AGENTS.md protokolni o'zimizda qayta yozishni taqiqlaydi, ban xavfi yuqori, foydasi yo'q. |
| Akkauntni o'chirish, o'z raqamini almashtirish | Yo'q | Faqat asosiy telefon. |
| Backup | Rasmiy: yo'q. O'zimizniki: ha | WhatsApp'ning iCloud/Google Drive zaxirasi telefondagi kalit bilan shifrlangan, hamrohga ochiq emas. Bizning arxiv (`archive.db`, SQLCipher) va media keshni zaxiralash/tiklash mumkin. Qiyin joyi: kalit Keychain'da, shuning uchun boshqa Macda ochilishi uchun kalitni foydalanuvchi parolidan hosil qilingan kalit bilan o'rab eksport qilish dizayni kerak. |
| Chat eksporti | Ha | To'liq bizning tomonda. Arxivdan sahifalab o'qib (`LoadChat`, `FetchOlder`, `LoadUntil` buyruqlari yoki Bridge'da arxiv API) `.txt` va media bilan zip. Chegara: faqat arxivdagi xabarlar (bog'langandagi tarix va keyin telefondan olinganlar) va faqat yuklab olingan media. Xotira qoidasi: tuzatish paytida haqiqiy chat o'qilmaydi, fixture bilan sinaladi. |
| HD media | Asosan bor | Fork allaqachon 4096 px, JPEG 0.92 gacha yuboradi (`MediaQuality.hd`, `MediaEdit.swift:347`). Yetishmaydigani protokol darajasidagi HD belgisi va ikkilamchi yuklash (`midQuality*`, `MediaQualitySetting`): to'g'ri simlar WhatsApp Web'dan olingan namunasiz noma'lum, qiymati past. |
| Jonli joylashuv yangilanishi | Qabul: ZapFast'da bor. Yuborish: yo'q | Qabul: yangilanishlar bitta pufakka yig'iladi (`src/backend/worker.rs:3157`); kod izohida hamrohlar masklangan yangilanishlarni kuzata olmasligi aytilgan, ya'ni protokol bergan chegaradan ortig'i bo'lmaydi. O'zimiz ulashish: kutubxonada mexanizm yo'q, protokoli noma'lum. |
| Lottie stiker | Shartli, qiymati past | Hozir "unsupported (animated sticker)" ko'rsatiladi (`src/backend/worker.rs:7967`). Qabul qilib ko'rsatish uchun Lottie renderer va `.was` formatini tahlil qilish, ya'ni yangi Swift/Rust bog'liqlik kerak. Yuborish ma'nosiz. Avval haqiqatda qanchalik uchrashini aniqlash kerak. |
| @everyone | Shartli | Simlari tasdiqlanmagan (`nonJidMentions` faqat son, AB prop orqasida). Namuna kerak (WhatsApp Web'dan kuzatish). Hozirgi mention yo'li bilan hamma a'zoni belgilash mumkin, lekin xulqi boshqacha (har biriga alohida mention). |
| Rejalashtirilgan xabar | Ha (mahalliy) | Serverda rejalashtirish yo'q. "Keyin yuborish": navbat Swift tomonda (o'z faylimiz yoki kichik baza), vaqti kelganda mavjud yuborish yo'li. Shart: ZapFast ishlab turishi (menyu satrida fon rejimi bor) va Mac uyg'oq bo'lishi. Uxlagan bo'lsa uyg'onganda "kechikdi" deb ogohlantirib yuborish. |
| Tarjima | Texnik ha, o'zbeksiz | `Translation` framework (macOS 15+, qurilmada, xabar tashqariga chiqmaydi) mahsulot chegarasiga mos. Lekin o'zbek yo'q: rus, turk, ingliz va boshqalar bor. O'zbek uchun muqobillar: qurilmadagi model (sifati tekshirilmagan) yoki bulut (xabar mazmunini uchinchi tomonga yuboradi, qoidaga zid). |
| Ovozli xabar transkripti | Texnik ha, o'zbeksiz | OGG/Opus ni Rust (`voice.rs`) PCM ga ochadi, keyin `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true`) yoki `SpeechTranscriber` ga beriladi. Kerak: Speech ruxsati va `NSSpeechRecognitionUsageDescription`. O'zbek yo'q; rus (`ru-RU`) va turk (`tr-TR`) eski API da bor. Muqobil: qurilmadagi Whisper modeli (o'zbekni biladi, sifati o'rtacha, yuzlab MB hajm), bu alohida qaror. |
| Qoralama | Allaqachon bor | Kutubxonada yo'q, lekin ZapFast lokal saqlaydi (`Command::SaveDraft`, `ChatStore.drafts`). Rasmiy WhatsApp'da ham qoralama qurilmaga xos. |

### Tavsiya etilgan tartib

1. Chat eksporti (kichik-o'rta, upstream shart emas).
2. "Keyin yuborish" (kichik-o'rta).
3. Arxiv zaxirasi va tiklash (o'rta, kalit dizayni bilan).
4. Tarjima va transkript: faqat qo'llab-quvvatlanadigan tillar uchun, o'zbek kerak bo'lsa avval
   model tanlash qarori kerak.
5. Kutayotganlar: @everyone, HD belgisi, Lottie (namuna yoki talab kerak), LID kontakt nomlari
   (upstream).
6. Qilmaymiz: ro'yxatdan o'tish, o'chirish, raqam almashtirish, boshqa qurilmani uzish,
   ikki bosqichli tekshiruv, address book yuklash.

Skrinshotlarda ko'rinmagan qatorlar (serverda qidirish, link preview yaratish, status auditoriya
ro'yxatlari, chat mavzusi, to'lov yuborish) 3 va 4-bo'limlarda, bu bo'limda tahlil qilinmagan.
