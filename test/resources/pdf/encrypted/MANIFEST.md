# Encrypted-PDF fixtures

Fixtures for `test/tests/pdf/pdf_encryption_test.dart`. All of them derive
from the same small public-domain source, `../dickens-sample.pdf` (see
`../MANIFEST.md` there for its origin), so every revision below must extract
the exact same page text as the unencrypted original.

Every file is committed ready-to-use: tests never generate fixtures.

## qpdf-generated (qpdf 12.4.1, Homebrew)

Regenerate any of them with the exact command listed (run from any
directory; `<src>` is `../dickens-sample.pdf` relative to this folder):

| File | V / R | Method | User password | Owner password | Generator command |
| --- | --- | --- | --- | --- | --- |
| `r3-rc4-128.pdf` | 2 / 3 | RC4-128 | `user123` | `owner456` | `qpdf --allow-weak-crypto --encrypt --user-password=user123 --owner-password=owner456 --bits=128 -- <src> r3-rc4-128.pdf` |
| `r4-rc4-128.pdf` | 4 / 4 | RC4-128 (`/V2`) | `user123` | `owner456` | `qpdf --allow-weak-crypto --encrypt --user-password=user123 --owner-password=owner456 --bits=128 --force-V4 -- <src> r4-rc4-128.pdf` |
| `r4-aes128.pdf` | 4 / 4 | AES-128 (`/AESV2`) | `user123` | `owner456` | `qpdf --allow-weak-crypto --encrypt --user-password=user123 --owner-password=owner456 --bits=128 --use-aes=y -- <src> r4-aes128.pdf` |
| `r5.pdf` | 5 / 5 | AES-256 (`/AESV3`, deprecated R5) | `user123` | `owner456` | `qpdf --encrypt --user-password=user123 --owner-password=owner456 --bits=256 --force-R5 -- <src> r5.pdf` |
| `r6.pdf` | 5 / 6 | AES-256 (`/AESV3`, R6 / ISO 32000-2) | `user123` | `owner456` | `qpdf --encrypt --user-password=user123 --owner-password=owner456 --bits=256 -- <src> r6.pdf` |
| `owner-only.pdf` | 5 / 6 | AES-256 (`/AESV3`), empty user password | *(empty)* | `owner456` | `qpdf --encrypt --user-password= --owner-password=owner456 --bits=256 -- <src> owner-only.pdf` |

`--allow-weak-crypto` is required by qpdf ≥ 11.9 for the RC4 variants; the
flag only unlocks writing these intentionally insecure test files.

## Ported from pdf.js

| File | V / R | Method | User password | Owner password | Origin |
| --- | --- | --- | --- | --- | --- |
| `pr6531_1.pdf` | 5 / 6 | AES-256 (`/AESV3`) | `asdfasdf` | *(unknown)* | pdf.js `test/pdfs/pr6531_1.pdf` (Apache-2.0). The password is asserted by `pdf.js/test/unit/api_spec.js`, "creates pdf doc from PDF file protected with user and owner password" (`qwerty` must fail, `asdfasdf` must open). Copied byte-for-byte. |

Note: the brief pointed at `test/pdfs/encrypted.pdf`, which does not exist in
the pdf.js v3.11.174 sparse checkout; `pr6531_1.pdf` is the password-bearing
R6 fixture that pdf.js's own suite exercises, so it was ported instead (the
empty-password case is covered by `owner-only.pdf`).
