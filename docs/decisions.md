# Texnologik qarorlar

Namuna: [driceroland/Search](https://github.com/driceroland/Search) (MIT) — o'sha yo'ldan boramiz.

## Qabul qilingan

| # | Qatlam | Qaror | Nega |
|---|---|---|---|
| 1 | Platforma | Faqat macOS | O'zim macOS ishlataman; Windows/Linux'da Chrome kengaytmalari faqat Chromium bilan to'liq ishlaydi, bu esa "yengil" maqsadiga zid |
| 2 | Engine | WebKit (`WKWebView`) | Tizimda bor: ilova bir necha MB, Chromium'ning 300 MB'i yo'q |
| 3 | Til | Swift | Apple API'lari uchun yagona tabiiy tanlov |
| 4 | UI | SwiftUI + kerak joyda AppKit | Search shunday qilgan va ishlaydi |
| 5 | Loyiha | SwiftPM (`Package.swift`) + `build.sh` `.app` bundle yig'adi | Faqat matn fayllari; Xcode shart emas (Command Line Tools yetadi) |
| 6 | Minimal OS | macOS 15.4 | `WKWebExtensionController` shundan boshlab bor (build'da tekshirildi) |
| 7 | Chrome kengaytmalari | `WKWebExtension` + Chrome Web Store'dan `.crx` o'rnatish | Asosiy foydalanuvchilar shundan keladi |
| 8 | Reklama bloklash | `WKContentRuleList` | WebKit tarmoq qatlamida ishlaydi, JS narxi yo'q |
| 9 | RAM | Ishlatilmagan tablarni uxlatish (web view yo'q qilinadi, snapshot qoladi); xotira tanqisligida tezroq | Tab boshiga 100–300 MB — asosiy xarajat shu |
| 10 | Saqlash | JSON fayllar, bitta papkada | Server yo'q, akkaunt yo'q |
| 11 | Parollar | macOS Keychain | Tizimda bor |
| 12 | Tashqi bog'liqliklar | Yo'q — faqat Apple framework'lari | |
| 13 | Kod bazasi | Noldan yoziladi; kerakli qismlar (masalan `Crx.swift`, `ExtensionShims.swift`) Search'dan olinadi, MIT litsenziya matni bilan | Tuzilish o'zimniki bo'lsin |
| 14 | Asboblar | Xcode (Instruments, debugger), `swift format` (toolchain ichida) | Build uchun Command Line Tools yetadi |
| 15 | Kirish nuqtasi | AppKit (`NSApplication`, `main.swift`); SwiftUI ko'rinishlar `NSHostingView` orqali | Oynalar ustidan to'liq nazorat; SwiftUI `App` har doim biror Scene talab qiladi |
| 16 | Concurrency | Swift 6, standart izolyatsiya `MainActor` | AppKit va WebKit baribir main thread'da; fon ishi alohida belgilanadi |

## Ma'lum cheklovlar

- Kengaytmalar Safari darajasida: MV3'da `webRequest` ishlamaydi; ba'zilari (masalan Vimium C) ochilmaydi.
- DRM: faqat FairPlay (Netflix va h.k. Safari'dagidek).
