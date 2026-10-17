# RAR 5 fixture provenance

Two fixture families live in this directory: synthetic archives
generated inside this repository, and real RAR 5 archives taken from
the libarchive test suite. Every file's bytes and SHA-256 are pinned
by `manifest.json` (synthetic family) and the books manifest plus the
fuzz corpus inventory (both families).

## Synthetic archives (`rar5-*.cbr`)

Generated deterministically by `tool/rar5_pack.dart`:

```sh
dart run tool/rar5_pack.dart --out test/resources/books/comic/rar5
```

No external source is involved; the generator is part of the
repository. Each archive carries compressed entries (algorithm
version 0, single volume) whose decoded output is pinned by
the SHA-256 entries in `manifest.json`. Offline tests decode these and
verify the pinned digests; the oracle comparison below re-verifies the
same bytes against two independent decoders.

| File | Covers |
| --- | --- |
| `rar5-m1.cbr` … `rar5-m5.cbr` | compression methods 1-5 (the stream format is shared; the header field carries the level) |
| `rar5-dict-128k.cbr`, `rar5-dict-1m.cbr`, `rar5-dict-64m.cbr` | declared dictionaries at the subset edges (128 KiB, 1 MiB, 64 MiB) |
| `rar5-filter-delta.cbr`, `rar5-filter-e8.cbr`, `rar5-filter-e8e9.cbr`, `rar5-filter-arm.cbr` | one fixture per filter (0-3), with content crafted so the transform matters |
| `rar5-comic-utf8.cbr` | UTF-8 paths, `ComicInfo.xml`, declared CRC-32s, multiple entries |
| `rar5-solid-chain.cbr` | solid chain (archive flag + per-entry solid bits) where every entry after the first embeds its predecessor's head, so matches reach into the carried dictionary; independent streams cannot decode entries 2-4 |
| `rar5-solid-comic.cbr` | solid chain over a real CBR shape: `ComicInfo.xml` + UTF-8 JPEG pages, 1 MiB dictionary |
| `rar5-solid-mixed.cbr` | solid chain edge shapes: a directory between entries, a stored entry inside the chain, an empty file, and an entry whose declared CRC-32 is a real zero (content patched so its checksum is exactly 0) |
| `rar5-solid-dict-grow.cbr` | solid chain whose later entries declare a larger dictionary — the carried window must grow (rotate) without losing history |
| `rar5-solid-filter-e8.cbr` | solid chain with an E8-filtered middle entry — filter offsets restart at every entry while the dictionary carries on |

Solid layout notes fixed by the oracle run (rardecode v2.4.5 and
libarchive 3.7.4, both byte-identical over every file above):

- The first chain entry carries no solid bit: libarchive refuses a
  first-solid archive ("no window buffer initialized yet"), so real
  writers anchor the chain with a non-solid entry.
- Every entry keeps a self-contained block stream (own tables, own
  last-block flag); only the LZ dictionary continues across entries.
- Zero-byte framed blocks are never emitted; libarchive fails them
  ("truncated data in huffman tables") while rardecode tolerates them.

## libarchive test archives (`libarchive-*.rar`)

Source: the libarchive repository at the pinned commit
`87dec938e1578901f4919faa76e5f541b4d145b1`
(`libarchive/test/test_read_format_rar5_*.rar`, uudecoded). License:
the libarchive COPYING reproduced at `licenses/libarchive-COPYING`.
The files are used unmodified; the `libarchive-` prefix renames only
the checkout artifacts.

| File | Origin | Role |
| --- | --- | --- |
| `libarchive-compressed.rar` | `test_read_format_rar5_compressed.rar` | real compressed stream, byte-identical through all three decoders |
| `libarchive-arm-filter.rar` | `test_read_format_rar5_arm.rar` | real ARM-filtered ELF (90 808 bytes), byte-identical through all three decoders |
| `libarchive-arm-window-boundary.rar` | `test_read_format_rar5_arm_filter_on_window_boundary.rar` | malformed header; all three decoders reject (Unseal typed) |
| `libarchive-multiple-files.rar` | `test_read_format_rar5_multiple_files.rar` | four compressed entries, byte-identical through all three decoders |
| `libarchive-unicode-names.rar` | `test_read_format_rar5_unicode.rar` | real astral-plane UTF-8 names; link/redirect entries are typed rejections |
| `libarchive-solid.rar` | `test_read_format_rar5_multiple_files_solid.rar` | archive-solid flag with independent per-entry streams: decodes byte-identically through all three decoders (the per-entry solid bits are unset, so each entry is its own stream) |
| `libarchive-encrypted.rar` | `test_read_format_rar5_encrypted.rar` | encrypted entries are typed rejections |
| `libarchive-split-part1.rar` | `test_read_format_rar5_multiarchive.part01.rar` | split (multi-volume) archives are typed rejections |

## Oracle acceptance

The reference decoders and how to reproduce the byte-for-byte
comparison (fails without them; SKIP is never a pass):

```sh
# 1. rardecode (Go, BSD-2-Clause), pinned: ad22ba91a2ab
#    Requires the Go toolchain; the tool pins the module itself.
# 2. libarchive via bsdtar (developed against libarchive 3.7.4;
#    format source pinned at 87dec938).
dart run tool/rar5_compare.dart --allow-reject \
  test/resources/books/comic/rar5/*.cbr \
  test/resources/books/comic/rar5/libarchive-*.rar
```

All positive files must report `ok … both oracles`; the malformed and
out-of-subset files must report typed `reject` lines matching the
oracles' own refusals.
