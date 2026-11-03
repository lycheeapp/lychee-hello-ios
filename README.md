# Lychee Hello — iOS

Conversational payments client for the Lychee platform. Talks to the `hello/v1` module in
`lychee-api`.

Independent of `lychee-ios` (the main Lychee app): separate repo, separate bundle id, separate
Firebase app, independently buildable and releasable.

---

## Requirements

| | |
|---|---|
| Xcode | 15+ (iOS 17 SDK) |
| Deployment target | iOS 17.0 |
| Language | Swift 5, SwiftUI, `@Observable`, strict concurrency |
| Dependencies | Swift Package Manager only — **no CocoaPods** |
| Project generation | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |

## Getting started

```bash
brew install xcodegen
make open          # regenerates the project, then opens Xcode
```

The `.xcodeproj` is **generated and git-ignored**. Edit `project.yml`, not the project file — a
hand-maintained `pbxproj` is the usual source of merge conflicts on a mobile team.

> ### ⚠️ Regenerate after adding files
> XcodeGen enumerates sources at **generation time**. Add a file without regenerating and it simply
> is not in the target. When the missing file is the `@main` entry point, the symptom is:
>
> ```
> Undefined symbol: _main
> Linker command failed with exit code 1
> ```
>
> `make build`, `make test` and `make open` all regenerate first, which is why they exist. If you
> ever run `xcodebuild` directly, run `xcodegen generate` first.

## Running the tests

```bash
make test
```

Or `⌘U` in Xcode (after regenerating). There is no CI configured in this workspace; the `make`
targets are CI-ready if one is added later (decision U10).

---

## Configuration

Nothing is hardcoded in Swift. Values flow:

```
Config/{Debug,Release}.xcconfig  ->  Info.plist  ->  AppEnvironment.current
```

| Environment | API base |
|---|---|
| Debug (`dev`) | `https://apitest.lycheeapp.org/rest/lychee-v2` |
| Release (`prod`) | `https://apiproduction.lycheeapp.org/rest/lychee-v2` |

There is no staging tier at launch. Adding one is a new `Staging.xcconfig` plus a scheme — **no code
change**, which is the point of the indirection.

`AppEnvironment` **fails at startup** on missing or placeholder configuration. That is deliberate: a
payments build that silently falls back to a default host is far more dangerous than one that
refuses to launch.

### xcconfig gotcha

`//` starts a comment in xcconfig **even inside a value**, so URLs use the `$(SLASH)` indirection.
Removing it silently truncates the base URL to `https:`.

---

## Firebase

`LycheeHello/Resources/GoogleService-Info.plist` is the provided Hello iOS app config
(project `lychee-hello`).

⚠️ **Bundle id must match the plist exactly.** The plist declares:

```
BUNDLE_ID = org.lycheeapp.hello
```

`project.yml` sets `PRODUCT_BUNDLE_IDENTIFIER` to the same value. If they diverge, FCM registration
silently targets the wrong app and Crashlytics reports land in the wrong place — with no build
error.

> Note: this differs from the `com.lychee.mobile.hello` identifier discussed during planning. The
> Firebase project is the concrete provisioned artifact, so it wins. Recreate the Firebase apps if
> you want the other identifier.

Enabled services: **Crashlytics** and **Messaging (FCM)**. Analytics is off in the plist.

---

## Request signing (LYCHEE-SIGN-V1)

Every request carries `X-Lychee-*` signing headers. Two files matter:

- `SigningCanonical.swift` — **copied verbatim** from `lychee-ios`, validated against the committed
  `TEST_VECTORS.md`. Do not reimplement or "tidy" it: a one-byte divergence from the Java
  `CanonicalRequestBuilder` yields a 401 with no indication of which byte was wrong.
- `RequestSigner.swift` — key handling and header assembly.

### Keys

| Build | Key | Source |
|---|---|---|
| Debug | `test-key-1` | Committed test key (already public in this repo) |
| Release | prod key id | **Injected at build time**, never committed |

This differs from `lychee-ios`, which hardcodes its production key in source. Hello reads the
production key from `LYCHEE_SIGNING_PRIVATE_KEY` (Info.plist, from the build setting), and a
Release build without it stops at the "Check release signing key" build phase.

Before archiving for the App Store, on the build Mac:

```bash
# RSA-2048, PKCS#1 ("BEGIN RSA PRIVATE KEY"), which RequestSigner reads
openssl genrsa -traditional -out ~/secure/hello-ios-prod.pem 2048   # Homebrew OpenSSL 3
# openssl genrsa -out ~/secure/hello-ios-prod.pem 2048              # macOS LibreSSL
scripts/make-secrets-xcconfig.sh ~/secure/hello-ios-prod.pem <key-id>
```

That writes the gitignored `Config/Secrets.xcconfig`, which `Release.xcconfig` includes last. The
key id must match the public key registered on the backend for client `hello-ios`
(`openssl rsa -in ~/secure/hello-ios-prod.pem -pubout`).

Register the public halves with:

```bash
cd ../lychee-api && ./scripts/migrate.sh scripts/seed-hello-signing.sql   # dev only
```

Rollout order that avoids locking users out: `lychee.signing.mode=shadow` → verify clean logs → add
`hello-ios` to `lychee.signing.enforce-clients`.

**Threat model.** The signing key is a *build-time* secret: identical in every install and
extractable from the binary. It exists to stop scripted abuse and give the backend a revocation
lever — **not** to prove device identity. That is App Attest's job.

---

## Architecture

```
LycheeHello/
├── App/            entry point, root routing, Firebase bootstrap
├── DesignSystem/   Tokens.swift (single source of brand truth) + components
├── Core/
│   ├── Config/     AppEnvironment — all configuration, fails fast
│   ├── Security/   TokenStore (Keychain actor), RequestSigner, SigningCanonical
│   ├── Networking/ APIClient (actor), typed APIError
│   └── Realtime/   RealtimeClient protocol + SSERealtimeClient
├── Domain/         models mirroring the backend contract
├── Data/           HelloRepository — the app's whole API surface
└── Features/       Onboarding, Chat, Stores, Settings, Payment
```

### Rules worth keeping

1. **The server is the only authority on money.** Amounts, fees and totals are rendered, never
   derived. The client never decides that a payment succeeded.
2. **Realtime is abstracted.** Features depend on `RealtimeClient`, never on SSE. Swapping the
   transport must not touch a feature file.
3. **Events are hints, not state.** On any event, re-read the authoritative resource. FCM in
   particular can drop, delay, coalesce and truncate.
4. **Deduplicate on event id.** Delivery is at-least-once; overlapping replay windows are expected.
5. **Nothing sensitive is logged.** No tokens, voucher codes, phone numbers or bodies — including
   in Crashlytics.
6. **`payable`, not `amount`, gates payment UI.** A wallet can hold funds and still be suspended.

---

## Brand assets

Colours, type and the logo lockup are **sampled from the product screenshots** and drawn in code, so
the app builds and runs before real assets exist. All of it lives in `Tokens.swift` and
`CoreComponents.swift` — replacing it with the supplied artwork is a two-file change.

---

## Status

**Feature-complete for the flows in the product screenshots.**

| Area | State |
|---|---|
| Config, Keychain session, signing, API client | done |
| Realtime (SSE, dedup, resume, backoff, watchdog) | done |
| Firebase bootstrap, Crashlytics with redaction, FCM registration | done |
| Phone entry → OTP → onboarding | done |
| Chat with realtime refresh, balance card, quick actions | done |
| Payment review → biometric authorise → result | done |
| Stores directory (D4: directory now, messaging later) | done |
| Settings | done |
| Tests: signing, realtime, errors, money, phone, payment idempotency, redaction | done |

### Known refinements before shipping

1. **`SSERealtimeClient` is `@unchecked Sendable`.** `connect`/`disconnect` run on the main actor
   while connection state mutates on the stream task — a narrow but real data race. Convert to an
   `actor` with `nonisolated let` streams. Contained to one file; the `RealtimeClient` protocol does
   not change.
2. **Strict concurrency is set to `targeted`, not `complete`.** Complete checking flags SwiftUI
   patterns that are safe in practice (constructing a `@MainActor` view model in a `View` property
   initialiser, for one) and would block the build on migration work rather than real races. Raising
   it to `complete` is worth doing as a deliberate task — and item 1 above should be fixed first,
   since it is the one genuine issue `complete` would catch.
3. **Settings rows are non-navigating placeholders.** Deliberate — a dead `NavigationLink` promises
   a screen that does not exist.
4. **Stores is empty until the backend exposes store threads.** The empty state is honest rather
   than mock rows.
5. **Crashlytics dSYM upload build phase** needs the team id configured in `project.yml`.
