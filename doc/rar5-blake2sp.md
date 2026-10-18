# RAR 5 BLAKE2sp data-hash verification

This document fixes the contract the RAR 5 reader follows for the extra-area
hash record (record type `0x02`) and the comparison protocol its acceptance
uses. The policies here were written before the verification code; the
comparison tooling reads them, it does not define them.

Reference implementations (development oracles only; the library stays pure
Dart and never calls them at runtime):

- BLAKE2 reference C package, pinned revision
  `ed1974ea83433eba7b2d95c5dcd9ac33cb847913` (CC0 / OpenSSL / Apache-2.0
  tri-license), files `ref/blake2s-ref.c` and `ref/blake2sp-ref.c`. The
  unkeyed key-value tests (input lengths 0..255 of the standard buffer
  `buf[i] = i`) and the block/chunk boundary probes compare bit for bit
  against this implementation. BLAKE2s (the sequential hash) is never a
  substitute for BLAKE2sp (the 8-lane parallel tree); a digest that is
  BLAKE2s of the payload must fail verification.
- RAR 7.23 for macOS ARM (official rarlab trial distribution, development
  cache only) produced the committed `-htb` corpus and re-tests it with
  `rar t`. Its listing (`rar lt`) records the digest RAR itself uses.
- `unrar`/`rar p` extracts the corpus members; extracted bytes must equal
  the bytes Unseal verifies.

## Format contract

The RAR 5 file-header extra area may carry one or more records
`(size vint, type vint, payload)`. For the hash record (`type = 2`):

- `hash type` vint follows. Only `0x00` (BLAKE2sp) is inside the cut. Any
  other value is a typed failure naming the entry and the type; no
  fallback interprets an unknown hash.
- For hash type `0x00` the record payload is exactly 32 digest bytes after
  the type field. A record that ends early (truncation) or leaves extra
  bytes is a typed failure. There is no flags field; producers write
  BLAKE2sp instead of the header CRC-32 (WinRAR/RAR `-htb`), so a `-htb`
  entry commonly declares no file-header CRC-32 at all.
- A digest of 32 zero bytes is a present digest (it verifies against the
  computed hash and will normally fail, because no payload's BLAKE2sp is
  all-zero). Absence of the record is absence: entries without the record
  keep the CRC-32-only contract, and the public APIs keep their shapes.
- Two hash records on one entry must agree when both declare a BLAKE2sp
  digest; conflicting digests are a typed failure. A repeated identical
  digest is accepted once.
- The digest is stored on the parsed entry and is verified before any
  payload of that entry is published. Verification is integrity only:
  BLAKE2sp here is an unauthenticated checksum declared by the archive
  itself, never proof of origin.

## Verification contract

- The hasher is an incremental pure-Dart BLAKE2sp (RFC 7693 parallel
  variant): 8 BLAKE2s leaves (fanout 8, depth 2, node offset 0..7, leaf 7
  and the root carry the last-node flag), a 512-byte shared tail buffer,
  64-byte blocks, 10 rounds, and 32-byte output. All state is fixed size.
  Integer arithmetic is masked to 32 bits so the VM and compiled
  JavaScript agree bit for bit.
- The hasher consumes the entry's final decompressed, post-filter payload
  in order — the same bytes the CRC-32 sees — in whole-buffer views; it
  never triggers a second full copy of the payload, never hashes
  pre-filter output, and never hashes the packed payload of a non-split
  entry.
- Stored, compressed (algorithm version 0, methods 1-5), and solid-chain
  entries all verify. Solid-chain intermediate entries — including
  members that are not pages — verify before their bytes are allowed to
  stand as dependencies for later members; backward replay and checkpoint
  restores re-verify every entry they re-decode, and a failure poisons the
  chain exactly like a failed decode (reset/poison/reopen follow the
  base solid contract).
- When an entry declares both a header CRC-32 and a BLAKE2sp digest, both
  verify; a correct checksum never excuses the other. Failures name their
  cause: a digest failure says BLAKE2sp, a CRC failure says checksum, a
  header CRC failure names the header, and decoder corruption keeps its
  existing wording. Eager parsing and sessions fail with the same typed
  `ComicException` hierarchy.
- Existing limits are untouched and precede hashing: header and data
  CRC-32 semantics, dictionary/replay/expansion caps, and the typed
  refusal of split volumes, encryption, redirects, unknown-size entries,
  dictionaries above 64 MiB, and algorithm versions above 0 (where a
  split volume's non-final packed-data hash never applies).

## Corpus and comparison protocol

- Committed fixtures (with provenance in the fixture directory): real
  RAR 7.23 `-htb` archives — stored, compressed methods 1/3/5, a solid
  multi-member chain including a stored member, an empty entry, plus
  derived negatives (corrupted digest byte, BLAKE2s digest in place of
  BLAKE2sp, all-zero digest, and a both-checksums archive with a corrupted
  digest under a repaired header CRC). Derived fixtures come from the
  committed originals through a versioned tool and record the
  transformation.
- Units are bytes; the comparison is lossless with zero differences at
  digest level. The comparator must fail when a reference is missing,
  when a reference command exits non-zero, or when any digest disagrees —
  absence of evidence is never a pass.
- Gates: the C reference recomputes the 256 unkeyed KATs (lengths 0..255)
  and the boundary set {63, 64, 65, 511, 512, 513, 1023, 1024, 1025,
  65535, 65536, 65537, 131072, 655363} with varied streaming chunkings
  (1, 3, 7, 63, 64, 65, 127, 255, 511, 512, 513, 4096, whole-buffer); the
  Dart hasher must reproduce every value bit for bit on the VM. The RAR
  corpus re-tests with `rar t`, re-extracts with `rar p`, and confirms
  producer compression version `v50` (algorithm version 0) on every
  compressed member. VM and Chrome (real worker) must agree on digests
  and on typed rejections.
- Out of scope: RAR4 (including its PPMd/VM filters), split volumes,
  encryption, archive repair, new compression algorithms, and any claim
  of cryptographic authentication.
