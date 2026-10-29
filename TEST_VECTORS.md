# LYCHEE-SIGN-V1 — Canonical Signing Test Vectors

**This file is the cross-implementation oracle.** The Java verifier, CRM, Store, Android,
and iOS signers MUST each reproduce these canonical strings **byte-for-byte** and produce a
signature the test public key verifies. Assert the canonical string equals the expected bytes
**before** wiring real keys — that is the #1 defense against 5-implementation drift.

A copy of this file is committed in every client repo. Keep them identical.

---

## The canonical string

Exactly **9 lines, each terminated by a single `\n` (U+000A), trailing newline included**:

```
LYCHEE-SIGN-V1\n
{METHOD}\n                  uppercase ASCII
{PATH}\n                    app-relative, context-path (/rest/lychee-v2) stripped, raw on-the-wire form, leading "/"
{CANONICAL_QUERY}\n         rules below; "" if no query
{BODY_MODE}:{BODY_HASH}\n   "sha256:<lowercase hex>" or "none:e3b0c4...b855"
{TIMESTAMP_MS}\n            unix epoch MILLISECONDS (decimal) — NOT seconds
{NONCE}\n                   >=16 bytes CSPRNG, lowercase hex
{CLIENT_ID}\n               lychee-crm | lychee-store | lychee-android | lychee-ios
{KEY_ID}\n                  selects the public key
```

The signed bytes are the **UTF-8** encoding of this string. Signature scheme: **`SHA256withRSA`**
(RSA PKCS#1 v1.5, SHA-256). Signature header is **standard Base64 with padding**.

### Empty-body constant
SHA-256 of the empty byte array (used for GET/DELETE bodies and `none` mode):
```
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

### Body mode
- `sha256` — JSON/form/text bodies ≤ cap (256 KB): `BODY_HASH` = lowercase-hex SHA-256 of the **raw request body bytes**.
- `none` — multipart/streaming/oversized: `BODY_HASH` = the empty constant above; the body is NOT hashed (but the request is still authenticated + replay-protected). The mode is inside the signed string so it cannot be downgraded.
- GET/DELETE / empty body: mode `sha256`, hash = the empty constant.
- **Server policy on protected paths: `sha256` is REQUIRED; `none` is rejected.** (`none` stays in the contract for future use.)

### Canonical query rules (the cross-platform footgun — get this exact)
1. Split the raw wire query on `&`. Drop empty tokens.
2. Split each token on the **first** `=`. No `=` ⇒ value is empty (canonicalizes to `name=`).
3. Percent-**decode** name and value: decode only `%XX` escapes to raw bytes. **`+` is left
   literal — never decoded to a space.**
4. Percent-**encode** each with the fixed unreserved set `A-Za-z0-9-_.~`; every other byte ⇒
   `%XX` uppercase hex. So a space ⇒ `%20`, a literal `+` ⇒ `%2B`.
5. Sort the encoded `name=value` strings by **byte order** (ASCII; equals `String.compareTo`).
6. Join with `&`.

> **Client rule:** clients MUST encode spaces as `%20`, never `+`. (`+`-as-space would canonicalize
> differently on the server, which treats `+` as a literal plus.)

### Path rule
Sign the **app-relative** path (strip the `/rest/lychee-v2` context) in its **raw percent-encoded
on-the-wire form** — no decode/re-encode. (Contrast with the query, which IS re-canonicalized.)

---

## Test keypair — **TEST USE ONLY. Never deploy. Never reuse in prod.**

Public key (SPKI PEM — the format stored in `signing_client_key.public_key_pem`):
```
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoA4RxVyXju2fftBpkbTV
SR46lP4K4ZsHdT9KFxDwlwRr1CML40W3yDedVIukb5YUz0jFeLDwGXYMu58K/IIx
05BEGGf3aoEEkrBU6X+gKpkIMlmo1IU4PDfBiHhHvPNuvH4Xlh//Cb56HzYYy0wM
uRh3pW8RY5i0O7Cc9/WIjvM0+HoKtwnntEjd9dVQ+oOZ+n/qlSOdcOF1ISuDfu3m
ji1J3Bm2skE61lV0dOLEmDgMYAyto91wqEwfdZi1d7CvsFTWyDznA+0fahcyLmXE
ULBsq6dDFQNAryLdCBIeYawhDh1UEtOH0dM9Sk7EX6CXZdVnKAk+SdP3wWfjzhY6
vwIDAQAB
-----END PUBLIC KEY-----
```

Private key (PKCS#8 PEM — used only to regenerate signatures in this file):
```
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCgDhHFXJeO7Z9+
0GmRtNVJHjqU/grhmwd1P0oXEPCXBGvUIwvjRbfIN51Ui6RvlhTPSMV4sPAZdgy7
nwr8gjHTkEQYZ/dqgQSSsFTpf6AqmQgyWajUhTg8N8GIeEe88268fheWH/8Jvnof
NhjLTAy5GHelbxFjmLQ7sJz39YiO8zT4egq3Cee0SN311VD6g5n6f+qVI51w4XUh
K4N+7eaOLUncGbayQTrWVXR04sSYOAxgDK2j3XCoTB91mLV3sK+wVNbIPOcD7R9q
FzIuZcRQsGyrp0MVA0CvIt0IEh5hrCEOHVQS04fR0z1KTsRfoJdl1WcoCT5J0/fB
Z+POFjq/AgMBAAECggEAJoGcBuZy1AEZKTJM47AkzBWItIW16ncYwT17vrblmv+G
TaAs4P3J7FJs+IUsB2iNEx2H3LR83zNGdvEZfIx6HlML/u8sWCQ4DG59zztUNktg
7HQjqRVv5RTo68M8Rxot3w1a8VQ7UIXR7aZfKrHeMb3QMy3YeiSn3+Bqs0EQHIvH
H+NJNQLlKi4gAzALkZSBwdYwDAe23dqRtS13VbI1z6fUyXhi2gE1Pd9prS9+0C2b
Ukb2CtN7Ve2l6CI8cVB72PDm1EoiRvXfod4DShOFkXx+F901oVx5AFqGVp1WXjHo
j6wgtia6WlLhfKWR9nJcFvG96TJS9y/oyDqUGa5n4QKBgQDMyk+eqaU50OdaWiPq
mjrjLGe+wVfo0lycVRov5ALe9NK6miDkYL/CfIj5wQfOaC6sxoaXtOra+kiznLCh
Hzplid1chfpBa2FJUcg3v+z3NSbm6Fz+8oWL/ZJmJDU6Hhfg4aFARFdxldeGlRog
loysbLFRT9oQXUvC9AMeVg/Y8QKBgQDIFAS0CjWTEHsl97AOZZu95RHju+ZJSX9y
ftP+Q4ZSsdw/xoHaFtvWkc3JGT/GFZjMTfiUc4J4K+UP0prAjnteeK0HcqVCAACd
jDGanmvRXIOzUQeClkmlWl223AJ6s8S4bXv1HXvuuu6lfRdvz/TyPgCglfwILqH1
L4l+K5/OrwKBgAh8qegNZ8eJnMzlx29FjQM1J+eD47zGWwgvjrJFZMkQpFsPYCWW
zNumhZa0JTqsnqKSZ6mJ2eHRVYn8CGXlAWqL2BypgMGNTa7YMM/+qDdmgII5RwFZ
06cFjzekcIBEFwE+2IvtSSJv70qoizimhJXwuzh/cq4S77zYl/h94JJBAoGBAKH5
ktUubrDgZtIV8zG0kKDrEdCMDaLHHaZThswRXm0UEHqQ+g7U8qSC5VYoWrjCQzEi
7ltAKB+haY+lsCKzNq0EhQ/CgIct+VGSbZX/KsoTW4uPzcSqZnS286dV9avgXSHx
gKivdeWO8CSJYK/kayixiVB4G9GD7xnPoj/CkV2BAoGBALAKN05ctsjluXj7Fx2s
UOf7E4nxZDpMa/+58qN1HHv0gGSFvHxnF6ZiGUfLLHG+J5WyykQpVXGBGbsPaX6X
ZVztwqjUG58xFCYQ12LmwI4BKEWGOEbFiPZ2Kk6ku8DjK8r7wxAFixgSLRGEcfih
WZtbP9YDmfzMKWQATTT0cAfv
-----END PRIVATE KEY-----
```

All vectors below share `timestamp = 1719662400000`, `nonce = 0123456789abcdef0123456789abcdef`,
`keyId = test-key-1`.

---

## Vector 1 — GET with query (sort + multi-value key + empty body)

| field | value |
|---|---|
| method | `GET` |
| path | `/vouchers/list` |
| raw query | `b=2&a=1&a=10` |
| body | _(none)_ → mode `sha256`, empty constant |
| client | `lychee-android` |

Note the canonical query reorders to `a=1&a=10&b=2` (`a=1` < `a=10` by byte order: shorter prefix sorts first).

Canonical string (`·` marks each `\n`, including the trailing one — do not include the dots):
```
LYCHEE-SIGN-V1·
GET·
/vouchers/list·
a=1&a=10&b=2·
sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855·
1719662400000·
0123456789abcdef0123456789abcdef·
lychee-android·
test-key-1·
```

Signature (Base64):
```
j77TRx0nhK32EkrMgb1hEbviFlB9WrF3XkpFBR9NeDiQ15skHIe+NUhqmBdzA2N0gpO+y7H9xI65Zg0SKq1D0QFBjgfXQiF/NsGZWzWExwFPRxt3aNLxJYpz1JQJ0lvEKcuwpUIPaYJBlYuNrMArt1T2lHIn0L9WEVmavwYlZMUBT0+Gbt9s3NcMLVtd/WJTX4+r4aa6SScUyVvj95zVPwkxvU4d6Hsm2KmaS441l4lLuryxAZhdcvEUNgHH8rK4kG3H7h8+NU80/usSKcI9ovpc6jWpund/NM6JC2gFB1pPEUwHBfo6G0e72TMhujNk5EDkqwibhOxQHK/SPvs8/A==
```

---

## Vector 2 — POST JSON (real body hash)

| field | value |
|---|---|
| method | `POST` |
| path | `/auth/v1/lytchee-work-station/login` |
| raw query | _(none)_ → `""` |
| body (exact bytes) | `{"phone":"+970599","otp":"1234"}` |
| client | `lychee-ios` |

Body SHA-256 (lowercase hex): `a405f29226f38537f4b1798b0e119752e046e7387221a8be0320ed815df571fe`

Canonical string:
```
LYCHEE-SIGN-V1·
POST·
/auth/v1/lytchee-work-station/login·
·
sha256:a405f29226f38537f4b1798b0e119752e046e7387221a8be0320ed815df571fe·
1719662400000·
0123456789abcdef0123456789abcdef·
lychee-ios·
test-key-1·
```
(Line 4 is empty — there is no query — so it is just `\n`.)

Signature (Base64):
```
CHck734UjAB16qWhAXMt2aukNd3lI96PRpF0avGCzN/xlYOGMDC7KS0LJEzK5v+gHn77AzVAYH8Aj1pb8MBZytKRjUxnHOJT6uXx/jS3cooeuZ+K+E9D5gJwMxjJi2WOYdgBsA11XVOeG0G5U9dwJYGv6XoL4d0ziDAz6Rec+0kiso3ZtdSe5hCxWHB1jJ+JVo4xPlO3ARDpSwEV6FkMaxtF2nc5cpQ6fPFh8fZeYnTOqx0DVrULVn4pToIQYoXSarZ4TaXuJbPCvRWOKpCX7/JBZCcnfDiSSLYjXwGR3bzdFs16wS3JLaOjTwWqcMYztlhfaaPV/1oPnTgatTqp+w==
```

---

## Vector 3 — POST multipart (`none` mode)

| field | value |
|---|---|
| method | `POST` |
| path | `/files/upload` |
| raw query | _(none)_ |
| body | _(multipart, NOT hashed)_ → mode `none`, empty constant |
| client | `lychee-android` |

> Illustrative path only — no current **protected** endpoint uses `none` mode (all protected
> bodies are bound via `sha256`). This vector exists so clients exercise `none` formatting.

Canonical string:
```
LYCHEE-SIGN-V1·
POST·
/files/upload·
·
none:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855·
1719662400000·
0123456789abcdef0123456789abcdef·
lychee-android·
test-key-1·
```

Signature (Base64):
```
dxLCWPUnqtyBbQzz0kNzqM95oKm0nXZEBrned4uV+aJQmjzFIy3nhuhb0Z235BlCGdhYS2wXchwAqaKEdtckFIH7OpAN2a6+jU68J75GT/5QPK9a8UNChy4w7zidiwZ0loFtRkkmCLgVb1xILNL3BRX2Tq0syNNll6dKUIa9MwWM2Bsl/6mA7U1j4EKHpc6GFpiSg0cVk48pRiJfqNjPK9nn54oJ6Y3B/4rsXRpR7iAnHzn/E/PnV2/gOKW65lSWs+tu44SpGtgMGk8JqPCzEZKPJFozlzmHfFDeTWUrZTK5uwpVBcxLY58BHGHpgGKtwekqxkqReGjNz+l/ZzQ6MQ==
```

---

## Vector 4 — POST, query with encoded space and plus (round-trip), empty body

| field | value |
|---|---|
| method | `POST` |
| path | `/payment-tags/request` |
| raw query | `q=a%20b&x=1%2B2` |
| body | _(none)_ → mode `sha256`, empty constant |
| client | `lychee-ios` |

Canonicalization: `q`=`a b` (space) → `a%20b`; `x`=`1+2` (literal plus) → `1%2B2`. Sorted `q`<`x`.

Canonical string:
```
LYCHEE-SIGN-V1·
POST·
/payment-tags/request·
q=a%20b&x=1%2B2·
sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855·
1719662400000·
0123456789abcdef0123456789abcdef·
lychee-ios·
test-key-1·
```

Signature (Base64):
```
Km2CWi8RED0Vv7/jmQCX3ImfbGT3WAKxct3RibD8gl4lKo2R3HR6+6iITyM+I2O/yWAZ28Y7IkYZ6YDDRtSmhI6xcO/GxO4bLu4LqW5skwkeFEY/Q8sB/GN7cKiR/JmApVuCuF2WFeAeT5Uz6URKZC67C5PKuTVYkWXXDUcR2FAJ0K6wxm3sc2Q3qlAHS50VYqDog/lfNW0BU4CoWKKlGMPlIFNMytrHbzSjbMs2uNAbF3788QqpB44tz4wGJMwxB6KF/i1CLfCf54GbVdQKRyichk4bVl36KeoQLkSV2SHidmDiP9Z++R2YtGPZPyKoXfeGh0KjLnNpFV9TgX0REQ==
```

---

## Regenerating these vectors (if the contract changes)

```sh
# canonical string for a case → file with exactly 9 newline-terminated lines
printf '%s\n' "LYCHEE-SIGN-V1" "$METHOD" "$PATH" "$CANON_QUERY" "$BODY_MODE:$BODY_HASH" \
              "$TS" "$NONCE" "$CLIENT" "$KEY_ID" > case.txt

# sign + verify with the test keypair
openssl dgst -sha256 -sign test_priv_pkcs8.pem case.txt | openssl base64 -A      # signature
openssl dgst -sha256 -verify test_pub_spki.pem -signature sig.bin case.txt        # -> Verified OK
```
