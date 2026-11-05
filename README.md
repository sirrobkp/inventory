# Kibo Trade (Flutter, Android)

Offline-first inventory + POS with TRA Virtual Fiscal Device (VFD) integration.
Ported from the supplied React UI (same dark/lime design, same 4 tabs: Home, Stock, Sell, TRA).

## Build
Commit this folder's contents to a Git repo (pubspec.yaml at the root) and use `codemagic.yaml`:
- workflow `android-apk` -> APK
- workflow `ios-ipa-altstore` -> `KiboTrade-unsigned.ipa` (unsigned; AltServer/AltStore signs it with your Apple ID)
`tool/prepare.sh` runs first in both: it generates android/ + ios/ and a small local plugin (`packages/kibo_signer`)
that does certificate signing natively, adds permissions and sets minimum OS versions.
Local: `bash tool/prepare.sh && flutter pub get && flutter run` (the pubspec path dependency needs the script run first).

## What it does
- **Local storage**: SQLite (sqflite). Products, sales, VAT lines, stock movements, purchases, expenses, Z-reports, counters. Certificate password + VFD password in Android Keystore-backed secure storage. DB backup export in Settings.
- **Inventory**: add/edit/archive, barcode field + camera scan, categories, low-stock, receive stock (records supplier, TIN, invoice, supplier EFD no., input VAT, weighted-average cost), adjustments with audit trail.
- **POS**: continuous camera barcode scanning, USB/Bluetooth keyboard-wedge scanner support (catalogue search box), cart, VAT split per class, payment methods (cash/mobile money/card/cheque), optional customer TIN, stock check inside the DB transaction.
- **TRA**: on every approved sale, one DB transaction assigns GC/DC counters + verification number, deducts stock, queues the receipt; upload starts immediately and retries every 60 s and when connectivity returns. Receipts are printed straight away (verification code + QR) and uploaded in GC order. Z-reports auto-submit for past days once all receipts are accepted; manual "close day" for today.
- **Printing**: ESC/POS over Bluetooth (58/80 mm) with QR, or PDF via Android print/share.
- **Statements**: Income statement, VAT working paper, stock valuation (PDF); sales schedule and purchases schedule (CSV); Z-reports (XML).

## Before you go live (READ THIS)
1. **TRA must approve you.** A VFD is only legal after TRA onboarding: you obtain a test account, the current EFDMS/VFD API specification, a certificate (.pfx), its password and CERTKEY. Production use needs TRA's acceptance of your software.
2. **Verify the wire format against TRA's spec.** `lib/services/tra_service.dart` was written from the publicly known EFDMS flow without access to the current spec. Check: endpoint paths, header names (`Routing-Key`, `Cert-Serial`, `Client`), the Cert-Serial encoding, XML element names/order, tax code mapping (A..E -> 1..5), `RCTNUM`, Z-report fields (`GROSS`, `VATRATE` format, `CHANGES`), and what you must do for refunds/credit notes. Use TRA's test environment and fix any ACK errors.
3. **Not implemented**: refunds/credit notes, voided receipts, discounts, multi-user roles, multi-device sync, iOS.
4. **VAT return**: TRA's VAT return is filed on the TRA Tax Online Services portal. The app produces supporting schedules and a working paper; compare columns with TRA's current templates before uploading.
5. **PKCS#12**: some old .pfx files use legacy algorithms (RC2) that new Android versions reject - if import fails with a correct password, re-export the PFX with AES/3DES.
6. This code has not been compiled or run (no Flutter SDK in the build environment). Expect to fix small API drifts after `flutter pub get` / `flutter analyze` (package versions move).
