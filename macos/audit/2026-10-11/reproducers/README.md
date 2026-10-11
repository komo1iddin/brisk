# Audit regression proberlari

Bu fayllar sun’iy ma’lumotlar bilan hozirgi to‘rtta bugni ko‘rsatadi. Baseline commit `cec8c150cf50b6d6566e99ad1e50e04250add795`da to‘rtta assertion FAIL bo‘lishi kutiladi; serial layout control PASS. Ular odatiy test suite’ni failing holatda qoldirmaslik uchun alohida saqlangan.

Native bridge va package dependency’lari tayyor bo‘lgach, repo root’dan:

```sh
cp macos/audit/2026-10-11/reproducers/AuditLayoutLifetimeTests.swift macos/Packages/ZapFastKit/Tests/FeatureConversationTests/
cp macos/audit/2026-10-11/reproducers/AuditVideoOrientationTests.swift macos/Packages/ZapFastKit/Tests/ZapFastCoreTests/
cp macos/audit/2026-10-11/reproducers/AuditCacheIsolationTests.swift macos/Packages/ZapFastKit/Tests/ZapFastCoreTests/
cd macos/Packages/ZapFastKit
swift test --filter AuditLayoutLifetimeTests
swift test --filter AuditVideoOrientationTests
swift test --filter AuditCacheIsolationTests
```

Har bir buyruq alohida bajariladi; FAIL kutilgan natijadir. `.was` testi `/usr/bin/ditto` bilan faqat temporary directory ichida ikki sun’iy ZIP yaratadi va ularni tozalaydi. Thumbnail testi 2×2 qizil/ko‘k PNG ishlatadi. Video testi bo‘sh data va orientation eventlari bilan hardware/camera yoki real call ochmasdan ishlaydi.

Qayta tekshirib bo‘lgach qo‘shilgan uchta test faylini `Tests/`dan olib tashlang yoki fix bilan birga normal regression suite’ga qo‘shing. Foydalanuvchi archive/session/cache’ini test fixture sifatida bermang.

Audit vaqtida Swift testlarining audio fixture’lari agent OS sandboxida CoreAudio init’da abort bo‘ldi. Normal host muhitidagi original 471 test o‘tdi. Auditda local cache yo‘llari bilan quyidagi shakl ishlatildi:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/audit-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/audit-module-cache" swift test --disable-sandbox --cache-path .build/audit-cache --config-path .build/audit-config --security-path .build/audit-security --filter AuditLayoutLifetimeTests
```

`--disable-sandbox` SwiftPM package build sandboxiga taalluqli, tashqi agent OS sandboxini o‘zi olib tashlamaydi. Normal maintainer terminalida project’ning `make check`/`swift test` yo‘li afzal.
