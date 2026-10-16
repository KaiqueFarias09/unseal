# JPEG 2000 (JPXDecode) reference fixtures

Oracle-backed fixtures for the `JPXDecode` image codec. Every codestream
was produced by OpenJPEG `opj_compress` at the pinned revision
[8314119b067c0fc77834731168daaebd379fdb12](https://github.com/uclouvain/openjpeg/tree/8314119b067c0fc77834731168daaebd379fdb12)
(BSD-2-Clause, see `licenses/openjpeg-LICENSE` at the repository root),
except the two `real-*-ffmpeg` codestreams, produced by the independent
ffmpeg native JPEG 2000 encoder (LGPL-2.1-or-later build; the encoder is
used only as a development tool and ships no code).

## Layout

- `src/`: compressor inputs. The `g*.pgm` and `c*.ppm` files regenerate
  deterministically from `tool/generate_jpx_fixtures.dart`. The
  `real-*.pgm|ppm` files are derived once from the NASA photograph
  "The Earth seen from Apollo 17" (public domain, NASA image, no
  copyright) via `ffmpeg -i <photo> -vf crop=2000:2000:500:500,scale=128:128 -pix_fmt gray|rgb24 -f rawvideo`;
  photo source: <https://upload.wikimedia.org/wikipedia/commons/9/97/The_Earth_seen_from_Apollo_17.jpg>
  (downloaded 2026-10-16; SHA-256 `9aefe39a…` and `578a2050…` pin the
  derived files).
- `*.j2k`, `*.jp2`: committed codestreams, one per accepted decoder
  variant plus rejection cases documented in the codec tests.
- `oracle/`: byte-exact sample payloads decoded by the Release build of
  the pinned revision (components written planar, one byte per 8-bit
  sample, `opj_decompress -i <fixture> -o <payload>.raw`). These are the
  pinned references the normal (offline) test suite compares against.
- `oracle-debug/`: the same payloads from an independent Debug build of
  the same revision. They exist to measure oracle-side variability and
  are never used as test references.
- `tolerances.json`: lossy ceilings, fixed before any Dart comparison
  ran. `dart run tool/generate_jpx_fixtures.dart` re-derives them and
  fails when they drift.

## Matrix

| Fixture | Covers |
| --- | --- |
| `gray53-lossless-lrcp` | grayscale, 5/3 reversible, lossless, LRCP |
| `gray53-lossless-rlcp` | RLCP progression |
| `gray97-lossy-lrcp` | 9/7 irreversible, lossy, LRCP |
| `gray97-lossy-rlcp` | 9/7, lossy, RLCP |
| `rgb53-lossless-rct` | RGB, RCT (reversible MCT) |
| `rgb53-lossless-nomct` | RGB without MCT |
| `rgb97-lossy-ict` | RGB, ICT (irreversible MCT) |
| `rgb97-lossy-nomct-rlcp` | RGB, no MCT, RLCP |
| `gray53-lossless-multitile` | 100x67 in 64x64 tiles, partial edge tiles |
| `rgb97-lossy-multitile` | RGB lossy multi-tile, partial edge tiles |
| `gray97-lossy-3layers` | three quality layers (tag-tree inclusion) |
| `gray53-lossless-jp2` | JP2 wrapper, grayscale (colr box) |
| `rgb97-lossy-jp2` | JP2 wrapper, sYCC colr box conversion |
| `rgb53-lossless-nomct-jp2` | JP2 wrapper, RGB no MCT |
| `gray53-lossless-sop-eph` | SOP/EPH markers inside packets |
| `gray53-lossless-bypass` | arithmetic coding bypass (raw passes) |
| `gray53-lossless-segmark` | segmentation symbols in cleanup passes |
| `gray53-lossless-precincts` | explicit precinct sizes (32x32, 16x16) |
| `gray97-lossy-256` | 256x256 lossy benchmark input |
| `real-rgb53-lossless-ffmpeg` | independent ffmpeg encoder, 5/3 lossless |
| `real-gray97-lossy-ffmpeg` | independent ffmpeg encoder, 9/7 lossy |

The pinned OpenJPEG encoder maps sRGB JP2 output to the `colr`
enumerated colourspace 16 (sYCC) even without MCT, and its decoder
applies the sYCC-to-RGB conversion whenever enumcs is 16; the Dart
decoder follows the box the same way, which is what makes the JP2
payloads comparable.

## Reproduction

Build the pinned revision twice (the repository root has no
machine-specific paths pinned; point the environment at your builds):

```sh
git clone https://github.com/uclouvain/openjpeg.git /tmp/openjpeg
git -C /tmp/openjpeg checkout 8314119b067c0fc77834731168daaebd379fdb12
cmake -S /tmp/openjpeg -B /tmp/openjpeg/build-oracle -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_CODEC=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_LCMS2=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_ZLIB=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_PNG=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_CURL=TRUE
cmake --build /tmp/openjpeg/build-oracle --target opj_decompress opj_compress -j 8
# repeat with -DCMAKE_BUILD_TYPE=Debug into build-debug, target opj_decompress

export OPJ_RELEASE_BIN=/tmp/openjpeg/build-oracle/bin
export OPJ_DEBUG_BIN=/tmp/openjpeg/build-debug/bin
dart run tool/generate_jpx_fixtures.dart            # verify byte-exact
dart run tool/generate_jpx_fixtures.dart --write    # regenerate
```

Verification fails on any drift between committed fixtures, a fresh
`opj_compress` run, the pinned oracle payloads, or the tolerance
ceilings.

## Hashes

SHA-256 of every committed file (see `tool/generate_jpx_fixtures.dart`
for the authoritative reproduction check):

```
db9a6784af96285e45025143f174fd058d55aa9c679db3ccc4ba9286bc427569  src/c100x67.ppm
7e0c75aa68a464ea0c854db88c40a5c7be6c9c7b0f1547ace3da7166eddb4fe7  src/c64.ppm
cff99ac7cc1c98164b37e1a0a55369b11f2a42c2ca000558065ef88f22d3cd6d  src/g100x67.pgm
fecd64d5ad9ecc8d845707a2c30b29ea84fb5ebba09ad374b7e911ab57ae1058  src/g128.pgm
8fe2a44650785c9afcbe40fd9f800bb51f1aed9d4433919d5644bafd6b449502  src/g256.pgm
04cf51fee2cb5146330c6d2b5008b0993d53c339c8d9bd530d2da5fe547cf644  src/g64.pgm
9aefe39a90dcd800f66f601054a1b0840993a0176546d84fdd068eec4901d908  src/real-gray128.pgm
578a2050f341c8258b3f8b44cbf7369b052e0ebde9616b42e55a8d26186cbfa2  src/real-rgb128.ppm
014cb5f0852a5e716ba0389195ae079adf6c7135a69336c62eefb95d95b2852d  gray53-lossless-bypass.j2k
468c7056d9e95472d544101941e3f5b3f8ae599e899270a87a7e60db7fdd11bd  gray53-lossless-lrcp.j2k
89af892ade331020b0c52ea612d59c83ce319be4942033c86a285d9888930f94  gray53-lossless-multitile.j2k
f396ebafd86c59eabfafdd2a458c358ee078b3f5343caf5ab08ae61e0efbcad8  gray53-lossless-precincts.j2k
be44c9a86ef084f2b4cb1412df056a7d662cd28f1268472e203d07ee54d0be4c  gray53-lossless-rlcp.j2k
2a6802fdba3b3a5678c93dd4c1c3d7c1fc02246e0d42b4c536538906fc928aaf  gray53-lossless-segmark.j2k
7d719ce7f7a6723875afd028e34f4d31a39768ffc3402dcc50643267f263076c  gray53-lossless-sop-eph.j2k
b8217b5af919e57fa000dbcca42ea8eaecf2dfebc33a48d8b68e2a46cb1ab38b  gray97-lossy-256.j2k
9999968b04db4ae62218c974d784d4f15992778a833d4a7ee34b91a4abfb9057  gray97-lossy-3layers.j2k
1e1725699359e74c15db431424ba7f840e9a7ed6f6288c18b9284739e901ea17  gray97-lossy-lrcp.j2k
85aa7e969d1e4677bff3a696f16e103609217afa3f63afa0fbe4f16ef04e6164  gray97-lossy-rlcp.j2k
cc0fffeb53b3073858cbcf0cce02936c69942f053ec73eb6bc7f044f37ddf1af  real-gray97-lossy-ffmpeg.j2k
bb7eb1b744b6477bed68fdb15c898fe98f3db7f7b5049e790140129a5f088f61  real-rgb53-lossless-ffmpeg.j2k
18323abe51ac8bb31342d3f52bf11b58f7add541316003a1213c341ca0942383  rgb53-lossless-nomct.j2k
2eff874c7badb4645735a1b1d3f8d0be22ee7210341f28f7a8d7f1e24699c85b  rgb53-lossless-rct.j2k
7eddac7046a9b4e63ce005039ad6ad2ae1aebaa318e734573441eb67bad4311a  rgb97-lossy-ict.j2k
196a463958c2ca1b93a8a458dba87fdd7a88d40f6884fceb848dfb72b5d300cd  rgb97-lossy-multitile.j2k
4d16d58fc8e76ece35147b3f87678486aa78bc4cb73033f848a4b0b4ebbfa99c  rgb97-lossy-nomct-rlcp.j2k
ec1fb646ec795990b8d833f8f74d84e1d0484f8f62876ec6ee3b8e5720013818  gray53-lossless-jp2.jp2
ddf756f29fdc134673eadf60d6eb07ba47bba3546a7cb649e4e5da77f6b00582  rgb53-lossless-nomct-jp2.jp2
6b81c8a47a87c47a209a0fb73daab1bd74d14d9f151086cbef497f80afe2fc6d  rgb97-lossy-jp2.jp2
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle/gray53-lossless-bypass.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle/gray53-lossless-jp2.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle/gray53-lossless-lrcp.raw
8fa691d6d477bf17e7e5be68ff462db70dbc9b0b98ec11627d49a6c9fe5acfcd  oracle/gray53-lossless-multitile.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle/gray53-lossless-precincts.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle/gray53-lossless-rlcp.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle/gray53-lossless-segmark.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle/gray53-lossless-sop-eph.raw
da85bcba11b03a887c47fdd4e3dd06ece50f7801e477b3c93e54ad5cbe71db5e  oracle/gray97-lossy-256.raw
9ad1f34295f9cce3bdd8dab2d0664147d8a5511fce41e071bba334e42944959d  oracle/gray97-lossy-3layers.raw
f7cb110083b0e1710c062f09f65582f632351c4adb8096dfdb5ee779ddc1ceb4  oracle/gray97-lossy-lrcp.raw
f7cb110083b0e1710c062f09f65582f632351c4adb8096dfdb5ee779ddc1ceb4  oracle/gray97-lossy-rlcp.raw
b76eb6f6574b76bbfc84742bdc7076a7c72edf267fcd8838561608d780ac3547  oracle/real-gray97-lossy-ffmpeg.raw
7c36c0a2d64ccac83104e17ae4820c1ce3e35aef09b0b6293c6c65a65ae8c7a2  oracle/real-rgb53-lossless-ffmpeg.raw
eb1b6d98c1f1770e712bd7fcdcc4c52da41edad8eff14d913d60b1c3a61ae3d7  oracle/rgb53-lossless-nomct-jp2.raw
eb1b6d98c1f1770e712bd7fcdcc4c52da41edad8eff14d913d60b1c3a61ae3d7  oracle/rgb53-lossless-nomct.raw
eb1b6d98c1f1770e712bd7fcdcc4c52da41edad8eff14d913d60b1c3a61ae3d7  oracle/rgb53-lossless-rct.raw
3446664f4c3fd0d33288cd9f797ace96afa6f388a39a12ea38a962fdeb1f493f  oracle/rgb97-lossy-ict.raw
ee2f653b70328fa3d2ff2fd425308250a5b4225e78a5646892c093cf876d6e31  oracle/rgb97-lossy-jp2.raw
19e9c0145e392043286cec17fe27495753f836581854585b8360598ddfccaf2a  oracle/rgb97-lossy-multitile.raw
b5e675922927a3fa86f1b754e47885f382e84939bdbae1cf743c7d386128da51  oracle/rgb97-lossy-nomct-rlcp.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle-debug/gray53-lossless-bypass.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle-debug/gray53-lossless-jp2.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle-debug/gray53-lossless-lrcp.raw
8fa691d6d477bf17e7e5be68ff462db70dbc9b0b98ec11627d49a6c9fe5acfcd  oracle-debug/gray53-lossless-multitile.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle-debug/gray53-lossless-precincts.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle-debug/gray53-lossless-rlcp.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle-debug/gray53-lossless-segmark.raw
30c24b2fd200224fc6cc194e902d9febf7870eb82468d3d32097bd684a16e49a  oracle-debug/gray53-lossless-sop-eph.raw
da85bcba11b03a887c47fdd4e3dd06ece50f7801e477b3c93e54ad5cbe71db5e  oracle-debug/gray97-lossy-256.raw
9ad1f34295f9cce3bdd8dab2d0664147d8a5511fce41e071bba334e42944959d  oracle-debug/gray97-lossy-3layers.raw
f7cb110083b0e1710c062f09f65582f632351c4adb8096dfdb5ee779ddc1ceb4  oracle-debug/gray97-lossy-lrcp.raw
f7cb110083b0e1710c062f09f65582f632351c4adb8096dfdb5ee779ddc1ceb4  oracle-debug/gray97-lossy-rlcp.raw
b76eb6f6574b76bbfc84742bdc7076a7c72edf267fcd8838561608d780ac3547  oracle-debug/real-gray97-lossy-ffmpeg.raw
7c36c0a2d64ccac83104e17ae4820c1ce3e35aef09b0b6293c6c65a65ae8c7a2  oracle-debug/real-rgb53-lossless-ffmpeg.raw
eb1b6d98c1f1770e712bd7fcdcc4c52da41edad8eff14d913d60b1c3a61ae3d7  oracle-debug/rgb53-lossless-nomct-jp2.raw
eb1b6d98c1f1770e712bd7fcdcc4c52da41edad8eff14d913d60b1c3a61ae3d7  oracle-debug/rgb53-lossless-nomct.raw
eb1b6d98c1f1770e712bd7fcdcc4c52da41edad8eff14d913d60b1c3a61ae3d7  oracle-debug/rgb53-lossless-rct.raw
3446664f4c3fd0d33288cd9f797ace96afa6f388a39a12ea38a962fdeb1f493f  oracle-debug/rgb97-lossy-ict.raw
ee2f653b70328fa3d2ff2fd425308250a5b4225e78a5646892c093cf876d6e31  oracle-debug/rgb97-lossy-jp2.raw
19e9c0145e392043286cec17fe27495753f836581854585b8360598ddfccaf2a  oracle-debug/rgb97-lossy-multitile.raw
b5e675922927a3fa86f1b754e47885f382e84939bdbae1cf743c7d386128da51  oracle-debug/rgb97-lossy-nomct-rlcp.raw
edff7c79d44bbc4aac36b55eb0af5121fc1b2d2e9ec402a33cb24733b73a1a6c  tolerances.json
```
