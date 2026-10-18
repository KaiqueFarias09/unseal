#!/usr/bin/env python3
"""Generates the derived FGbz fixtures of the D04 mission.

Every fixture is produced by the pinned DjVuLibre 3.5.29 producer tools
(cjb2, c44, bzz, djvuextract, djvumake, djvm, djvmcvt). The generator draws
its own PBM/PPM cards, so no third-party bytes enter the derived corpus;
`fgbz-inverted-order.djvu` additionally reuses the Sjbz/BG44 bytes of the
licensed `spec-bundled.djvu` fixture (djvu.js attribution record, Unlicense)
through the same native tools. The native oracle extractor (built from
tool/djvu_fgbz_oracle.cpp) reports the real blit list, and the generator
crafts each FGbz payload — palette in B, G, R order plus BZZ-compressed
big-endian indices — against that list.

Usage:
  python3 tool/djvu_fgbz_fixtures.py <repo-root> <oracle-extractor>

Writes fixtures under <repo-root>/test/resources/djvu/derived/ and prints
the SHA-256 of every file it wrote. Rerunning is deterministic given the
same pinned tools.
"""

import json
import os
import struct
import subprocess
import sys
import tempfile

RED = (0xFF, 0x00, 0x00)
LIME = (0x00, 0xFF, 0x00)
BLUE = (0x00, 0x00, 0xFF)
YELLOW = (0xFF, 0xFF, 0x00)
CYAN = (0x00, 0xFF, 0xFF)
MAGENTA = (0xFF, 0x00, 0xFF)
ORANGE = (0xFF, 0xA5, 0x00)
GRAY = (0x80, 0x80, 0x80)


def run(argv, cwd=None):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(
            f"command failed ({result.returncode}): {' '.join(argv)}\n"
            f"{result.stdout}\n{result.stderr}"
        )
    return result.stdout


def write_pbm(path, width, height, ink_rows):
    """Writes a P4 PBM; ink_rows is a list of (x0, y0, x1, y1) filled rects."""
    rows = [bytearray((width + 7) // 8) for _ in range(height)]
    for x0, y0, x1, y1 in ink_rows:
        for y in range(y0, y1 + 1):
            row = rows[y]
            for x in range(x0, x1 + 1):
                row[x // 8] |= 0x80 >> (x % 8)
    with open(path, "wb") as handle:
        handle.write(b"P4\n%d %d\n" % (width, height))
        for row in rows:
            handle.write(bytes(row))


def write_ppm(path, width, height, rgb_fn):
    with open(path, "wb") as handle:
        handle.write(b"P6\n%d %d\n255\n" % (width, height))
        for y in range(height):
            for x in range(width):
                handle.write(bytes(rgb_fn(x, y)))


def fgbz_payload(palette_bgr, indices=None, datasize_bytes=True):
    """Builds an FGbz chunk payload; entries are (b, g, r) triples."""
    payload = bytearray()
    version = 0x80 if indices is not None else 0x00
    payload.append(version)
    payload += struct.pack(">H", len(palette_bgr))
    for entry in palette_bgr:
        payload += bytes(entry)
    if indices is None:
        return bytes(payload)
    raw = bytearray()
    for index in indices:
        raw += struct.pack(">H", index)
    with tempfile.NamedTemporaryFile(suffix=".raw", delete=False) as raw_file:
        raw_file.write(raw)
        raw_path = raw_file.name
    bzz_path = raw_path + ".bzz"
    try:
        run(["bzz", "-e", raw_path, bzz_path])
        with open(bzz_path, "rb") as handle:
            compressed = handle.read()
    finally:
        os.unlink(raw_path)
        if os.path.exists(bzz_path):
            os.unlink(bzz_path)
    payload += struct.pack(">I", len(indices))[1:]  # INT24
    payload += compressed
    return bytes(payload)


def oracle_blits(extractor, path, page):
    """The native blit list of one page, from the pinned DjVuLibre extractor."""
    with tempfile.TemporaryDirectory() as out:
        run([extractor, path, out])
        base = os.path.basename(path) + ".fgbz-oracle.json"
        with open(os.path.join(out, base)) as handle:
            data = json.load(handle)
    return data["pages"][page - 1]["sjbz"]["blits"]


def palette_rgb_to_bgr(entry):
    (r, g, b) = entry
    return (b, g, r)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    root = os.path.abspath(sys.argv[1])
    extractor = os.path.abspath(sys.argv[2])
    derived = os.path.join(root, "test", "resources", "djvu", "derived")
    os.makedirs(derived, exist_ok=True)
    written = []

    def keep(name, source=None):
        """Copies the built file out of the temp work dir into derived/."""
        destination = os.path.join(derived, name)
        if source is None:
            source = os.path.join(work, name)
        with open(source, "rb") as reader, open(destination, "wb") as writer:
            writer.write(reader.read())
        written.append((name, destination))

    with tempfile.TemporaryDirectory() as work:
        def abs_p(name):
            return os.path.join(work, name)

        # ---- 1. repeated symbol, four colors, mask-only page --------------
        # The same glyph at four x-ordered positions; cjb2's symbol coding
        # represents the repeats as copy blits of one shape.
        glyph_rows = []
        for ox in (6, 22, 38, 54):
            glyph_rows += [(ox, 6, ox + 5, 16), (ox + 1, 17, ox + 4, 20)]
        write_pbm(abs_p("repeat.pbm"), 64, 32, glyph_rows)
        run(["cjb2", "-dpi", "300", abs_p("repeat.pbm"), abs_p("repeat.djvu")])
        run(
            ["djvuextract", abs_p("repeat.djvu"), "Sjbz=" + abs_p("repeat.jb2")],
        )
        blits = oracle_blits(extractor, abs_p("repeat.djvu"), 1)
        order = sorted(range(len(blits)), key=lambda i: (blits[i]["left"], blits[i]["bottom"]))
        palette = [RED, LIME, BLUE, YELLOW]
        indices = [0] * len(blits)
        for rank, blit_index in enumerate(order):
            indices[blit_index] = rank % len(palette)
        payload = fgbz_payload(
            [palette_rgb_to_bgr(entry) for entry in palette], indices
        )
        with open(abs_p("repeat.fgbz"), "wb") as handle:
            handle.write(payload)
        run(
            [
                "djvumake", abs_p("fgbz-repeat-colors.djvu"),
                f"INFO=64,32,300",
                f"Sjbz={abs_p('repeat.jb2')}",
                f"FGbz={abs_p('repeat.fgbz')}",
            ]
        )
        keep("fgbz-repeat-colors.djvu")

        # The index-shift twin: the same Sjbz with the color sequence
        # rotated one blit forward. Only the per-blit indices change, so the
        # image must change color in place without moving anything.
        rotated = indices[-1:] + indices[:-1]
        payload = fgbz_payload(
            [palette_rgb_to_bgr(entry) for entry in palette], rotated
        )
        with open(abs_p("rotated.fgbz"), "wb") as handle:
            handle.write(payload)
        run(
            [
                "djvumake", abs_p("fgbz-index-shift.djvu"),
                "INFO=64,32,300",
                f"Sjbz={abs_p('repeat.jb2')}",
                f"FGbz={abs_p('rotated.fgbz')}",
            ]
        )
        keep("fgbz-index-shift.djvu")

        # Same Sjbz with a palette-only FGbz (version 0x00): the black-ink
        # default must equal a page without any FGbz chunk.
        only = fgbz_payload([palette_rgb_to_bgr(RED), palette_rgb_to_bgr(BLUE)])
        with open(abs_p("only.fgbz"), "wb") as handle:
            handle.write(only)
        run(
            [
                "djvumake", abs_p("fgbz-palette-only.djvu"),
                "INFO=64,32,300",
                f"Sjbz={abs_p('repeat.jb2')}",
                f"FGbz={abs_p('only.fgbz')}",
            ]
        )
        keep("fgbz-palette-only.djvu")
        run(
            [
                "djvumake", abs_p("fgbz-colors-absent.djvu"),
                "INFO=64,32,300",
                f"Sjbz={abs_p('repeat.jb2')}",
            ]
        )
        keep("fgbz-colors-absent.djvu")

        # ---- 2. shifted variant: one glyph moves, everything else stays ---
        # The baseline is fgbz-repeat-colors.djvu itself (shift 0), so only
        # the moved variant is committed; the generator builds the baseline
        # shift=0 card under `fgbz-shifted-base.djvu` for the bundle's third
        # page slot and the comparison lanes.
        for tag, dy in (("base", 0), ("b", -8)):
            rows = []
            for index, ox in enumerate((6, 22, 38, 54)):
                oy = 6 - dy if index == 2 else 6
                rows += [(ox, oy, ox + 5, oy + 10), (ox + 1, oy + 11, ox + 4, oy + 14)]
            write_pbm(abs_p(f"shift-{tag}.pbm"), 64, 32, rows)
            run(["cjb2", "-dpi", "300", abs_p(f"shift-{tag}.pbm"), abs_p(f"shift-{tag}.djvu")])
            run(["djvuextract", abs_p(f"shift-{tag}.djvu"), "Sjbz=" + abs_p(f"shift-{tag}.jb2")])
            blits = oracle_blits(extractor, abs_p(f"shift-{tag}.djvu"), 1)
            order = sorted(
                range(len(blits)), key=lambda i: (blits[i]["left"], blits[i]["bottom"])
            )
            indices = [0] * len(blits)
            for rank, blit_index in enumerate(order):
                indices[blit_index] = rank % len(palette)
            payload = fgbz_payload(
                [palette_rgb_to_bgr(entry) for entry in palette], indices
            )
            with open(abs_p(f"shift-{tag}.fgbz"), "wb") as handle:
                handle.write(payload)
            run(
                [
                    "djvumake", abs_p(f"fgbz-shifted-{tag}.djvu"),
                    "INFO=64,32,300",
                    f"Sjbz={abs_p(f'shift-{tag}.jb2')}",
                    f"FGbz={abs_p(f'shift-{tag}.fgbz')}",
                ]
            )
            keep(f"fgbz-shifted-{tag}.djvu")

        # ---- 3. colored mask over an IW44 background (compound page) ------
        # Two distinct glyphs; the background is a simple horizontal gradient
        # encoded by c44. FGbz colors every blit: blue for the left glyph,
        # orange for the right one.
        write_pbm(abs_p("two.pbm"), 64, 32, [(6, 6, 11, 20), (40, 6, 49, 20)])
        run(["cjb2", "-dpi", "300", abs_p("two.pbm"), abs_p("two.djvu")])
        run(["djvuextract", abs_p("two.djvu"), "Sjbz=" + abs_p("two.jb2")])

        def bg(x, y):
            return (160 + x, 100 + 2 * y, 40 + x)

        write_ppm(abs_p("two.ppm"), 64, 32, bg)
        run(
            ["c44", "-dpi", "300", "-slice", "74,74", abs_p("two.ppm"), abs_p("two-bg.djvu")]
        )
        run(["djvuextract", abs_p("two-bg.djvu"), "BG44=" + abs_p("two.iw4")])
        blits = oracle_blits(extractor, abs_p("two.djvu"), 1)
        indices = [0 if blits[i]["left"] < 32 else 1 for i in range(len(blits))]
        payload = fgbz_payload(
            [palette_rgb_to_bgr(BLUE), palette_rgb_to_bgr(ORANGE)], indices
        )
        with open(abs_p("two.fgbz"), "wb") as handle:
            handle.write(payload)
        run(
            [
                "djvumake", abs_p("fgbz-overlap-bg.djvu"),
                "INFO=64,32,300",
                f"Sjbz={abs_p('two.jb2')}",
                f"BG44={abs_p('two.iw4')}",
                f"FGbz={abs_p('two.fgbz')}",
            ]
        )
        keep("fgbz-overlap-bg.djvu")

        # ---- 4. painting-order discriminator over licensed real bytes -----
        # spec-bundled page 21's Sjbz and BG44 with a crafted colordata that
        # forces a color-group inversion: blit 0 is red, an overlapping later
        # blit i is lime, and a still-later overlapping blit j is red again.
        # The overlap pixel must render lime (the group of the LATER blit i
        # paints last even though red's group leads), which fails under a
        # naive last-blit-wins pass. The page's shared Djbz is embedded
        # inline so the rebuilt single page still decodes its symbols.
        page4 = os.path.join(work, "spec-page")
        os.makedirs(page4, exist_ok=True)
        spec = os.path.join(root, "test", "resources", "djvu", "spec-bundled.djvu")
        spec_page = 21
        run(
            [
                "djvuextract", spec, f"-page={spec_page}",
                "Sjbz=" + os.path.join(page4, "p.jb2"),
                "BG44=" + os.path.join(page4, "p.iw4"),
            ]
        )
        spec_bytes = open(spec, "rb").read()
        djbz_candidates = []
        root_length = struct.unpack(">I", spec_bytes[8:12])[0]
        offset = 16  # AT&T magic + FORM header + DJVM type
        end = 12 + root_length
        while offset + 8 <= end:
            chunk = spec_bytes[offset:offset + 4]
            length = struct.unpack(">I", spec_bytes[offset + 4:offset + 8])[0]
            if chunk == b"FORM" and spec_bytes[offset + 8:offset + 12] == b"DJVI":
                inner = offset + 12
                inner_end = offset + 8 + length
                while inner + 8 <= inner_end:
                    inner_id = spec_bytes[inner:inner + 4]
                    inner_len = struct.unpack(">I", spec_bytes[inner + 4:inner + 8])[0]
                    if inner_id == b"Djbz":
                        djbz_candidates.append(
                            spec_bytes[inner + 8:inner + 8 + inner_len]
                        )
                    inner += 8 + inner_len + (inner_len & 1)
            offset += 8 + length + (length & 1)
        if not djbz_candidates:
            raise SystemExit("no Djbz dictionaries found in spec-bundled.djvu")

        blits = None
        working_djbz = None
        for candidate in djbz_candidates:
            with open(abs_p("dict.jb2"), "wb") as handle:
                handle.write(candidate)
            try:
                with open(os.devnull, "w") as devnull:
                    subprocess.run(
                        [
                            "djvumake", abs_p("trial.djvu"),
                            "INFO=2539,3295,300",
                            f"Djbz={abs_p('dict.jb2')}",
                            f"Sjbz={os.path.join(page4, 'p.jb2')}",
                        ],
                        check=True,
                        stdout=devnull,
                        stderr=devnull,
                    )
                blits = oracle_blits(extractor, abs_p("trial.djvu"), 1)
                working_djbz = candidate
                break
            except (SystemExit, subprocess.CalledProcessError):
                continue
        if blits is None:
            raise SystemExit("no Djbz candidate decodes the spec page's Sjbz")

        def rects_overlap(a, b):
            return (
                a["left"] < b["left"] + b["w"]
                and b["left"] < a["left"] + a["w"]
                and a["bottom"] < b["bottom"] + b["h"]
                and b["bottom"] < a["bottom"] + a["h"]
            )

        pair = None
        for i in range(len(blits)):
            for j in range(i + 1, len(blits)):
                if rects_overlap(blits[i], blits[j]):
                    pair = (i, j)
                    break
            if pair:
                break
        if pair is None:
            raise SystemExit("no overlapping blit pair found on spec page 4")
        i, j = pair
        indices = [0] * len(blits)
        indices[0] = 0
        indices[i] = 1
        indices[j] = 0
        payload = fgbz_payload(
            [palette_rgb_to_bgr(RED), palette_rgb_to_bgr(LIME)], indices
        )
        with open(abs_p("inverted.fgbz"), "wb") as handle:
            handle.write(payload)
        run(
            [
                "djvumake", abs_p("fgbz-inverted-order.djvu"),
                "INFO=2539,3295,300",
                f"Djbz={abs_p('dict.jb2')}",
                f"Sjbz={os.path.join(page4, 'p.jb2')}",
                f"BG44={os.path.join(page4, 'p.iw4')}",
                f"FGbz={abs_p('inverted.fgbz')}",
            ]
        )
        keep("fgbz-inverted-order.djvu")
        with open(os.path.join(derived, "fgbz-inverted-order.origin.json"), "w") as handle:
            json.dump(
                {
                    "source": "test/resources/djvu/spec-bundled.djvu page 21",
                    "sourceSha256": "2f5e8995c86902daf2038fa8833b6e0dec63cf5aac69202f6b5cd349f1bc6bbc",
                    "overlapPair": {"i": i, "j": j},
                    "expectation": (
                        "the blit-i/blit-j overlap pixel renders lime: color groups"
                        " paint in first-appearance order, so the later red blit j"
                        " does not win over the earlier lime blit i"
                    ),
                    "generator": "tool/djvu_fgbz_fixtures.py",
                },
                handle,
                indent=2,
            )
        written.append(
            ("fgbz-inverted-order.origin.json", os.path.join(derived, "fgbz-inverted-order.origin.json"))
        )

        # ---- 4b. budget card: a large dict-free colored page ---------------
        # 2040x2040 with sparse glyphs; every copy reserves ~20 MB of raster
        # bytes, so a synthetic bundle of 52 copies crosses the 1 GiB book
        # limit without a shared dictionary or DIRM name table.
        big_rows = []
        for ox, oy in ((10, 10), (1000, 10), (10, 1000), (1000, 1000), (1010, 1010)):
            big_rows += [(ox, oy, ox + 61, oy + 161), (ox + 10, oy + 162, ox + 51, oy + 200)]
        write_pbm(abs_p("big.pbm"), 2040, 2040, big_rows)
        run(["cjb2", "-dpi", "300", abs_p("big.pbm"), abs_p("big.djvu")])
        run(["djvuextract", abs_p("big.djvu"), "Sjbz=" + abs_p("big.jb2")])
        blits = oracle_blits(extractor, abs_p("big.djvu"), 1)
        order = sorted(range(len(blits)), key=lambda i: (blits[i]["left"], blits[i]["bottom"]))
        big_palette = [RED, LIME, BLUE, YELLOW, MAGENTA]
        big_indices = [order.index(i) % len(big_palette) for i in range(len(blits))]
        payload = fgbz_payload(
            [palette_rgb_to_bgr(entry) for entry in big_palette], big_indices
        )
        with open(abs_p("big.fgbz"), "wb") as handle:
            handle.write(payload)
        run(
            [
                "djvumake", abs_p("fgbz-budget-page.djvu"),
                "INFO=2040,2040,300",
                f"Sjbz={abs_p('big.jb2')}",
                f"FGbz={abs_p('big.fgbz')}",
            ]
        )
        keep("fgbz-budget-page.djvu")

        # ---- 5. bundled multi-page document --------------------------------
        run(
            [
                "djvm", "-c", abs_p("fgbz-bundled.djvu"),
                abs_p("fgbz-repeat-colors.djvu"),
                abs_p("fgbz-overlap-bg.djvu"),
                abs_p("fgbz-shifted-base.djvu"),
            ]
        )
        keep("fgbz-bundled.djvu")

    # ---- 6. indirect variant of the bundle ---------------------------------
    indirect = os.path.join(derived, "fgbz-indirect")
    os.makedirs(indirect, exist_ok=True)
    bundle = os.path.join(derived, "fgbz-bundled.djvu")
    run(["djvmcvt", "-i", bundle, indirect, "index.djvu"])
    for name in sorted(os.listdir(indirect)):
        written.append((f"fgbz-indirect/{name}", os.path.join(indirect, name)))

    import hashlib

    for name, path in written:
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        print(f"{digest}  {path}")


if __name__ == "__main__":
    main()
