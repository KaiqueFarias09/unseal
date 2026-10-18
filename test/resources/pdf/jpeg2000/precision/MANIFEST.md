# JPEG 2000 precision and subsampling fixtures

Generated and verified by `tool/generate_jpx_precision_fixtures.dart`;
the contract and comparison protocol are in `doc/jpeg2000-precision.md`.
`corpus.json` lists every fixture with its declared geometry, producer and
comparison lanes; `tolerances.json` carries the lossy ceilings fixed before
any Dart decode.

Reference: OpenJPEG `openjp2` 2.5.4 (Homebrew 2.5.4_1; upstream tag `v2.5.4`,
commit `6c4a29b00211eb0430fa0e5e890f1ce5c80f409f`, BSD-2-Clause, see
`licenses/openjpeg-LICENSE`). `oracle/*.native.*` come from
`tool/jpx_oracle/opj_oracle dump` (the library, no post-processing);
`oracle/*.upsample.rawl` and `oracle/*.rgb.rawl` from `opj_decompress`
(`-upsample`, and the sYCC conversion of its `color.c`).

Producers: `synth-*` are encoded by `opj_oracle encode` (libopenjp2 2.5.4
through its public API) from the seeded synthetic pattern; `real-*` are
encoded by the independent ffmpeg 9.0.2 native `jpeg2000` encoder (GPL
build, used as a development tool only, no code shipped) from
`../src/real-rgb128.ppm`, the public-domain NASA photograph "The Earth seen
from Apollo 17" derivative documented in `../MANIFEST.md`.

Payload layout (`.bin` and `.rawl`): components in order, row-major, one
byte per sample up to 8 bits and two little-endian bytes above.

## Matrix

| Fixture | Precision | Grid | Components (dx,dy) | Transform | Lanes |
| --- | --- | --- | --- | --- | --- |
| `synth-gray9-lossless.j2k` | 9 | 64x48 @0,0 | 1,1 | 5/3 lossless | native |
| `synth-gray10-lossless-odd.j2k` | 10 | 63x45 @0,0 | 1,1 | 5/3 lossless | native |
| `synth-gray12-lossless-tiles.j2k` | 12 | 100x67 @0,0 tiles 32x32 | 1,1 | 5/3 lossless | native |
| `synth-gray12-lossless-coc-qcc.j2k` | 12 | 64x48 @0,0 | 1,1 | 5/3 lossless | native |
| `synth-gray16-lossless.j2k` | 16 | 64x48 @0,0 | 1,1 | 5/3 lossless | native |
| `synth-gray16-lossy.j2k` | 16 | 64x48 @0,0 | 1,1 | 9/7 lossy | native |
| `synth-gray16-lossless-origin-tiles.j2k` | 16 | 64x48 @5,3 tiles 32x32 | 1,1 | 5/3 lossless | native |
| `synth-gray12-sub2x2-odd.j2k` | 12 | 63x45 @0,0 | 2,2 | 5/3 lossless | native, upsample |
| `synth-gray16-sub2x2-odd-lossless.j2k` | 16 | 63x45 @0,0 | 2,2 | 5/3 lossless | native, upsample |
| `synth-gray16-sub2x2-odd-lossy.j2k` | 16 | 63x45 @0,0 | 2,2 | 9/7 lossy | native, upsample |
| `synth-gray8-sub2x1-origin.j2k` | 8 | 63x48 @3,0 | 2,1 | 5/3 lossless | native, upsample |
| `synth-gray12-sub1x3-tiles.j2k` | 12 | 64x50 @0,0 tiles 40x24 | 1,3 | 5/3 lossless | native, upsample |
| `synth-rgb12-rct-lossless.j2k` | 12 | 64x48 @0,0 | 1,1 1,1 1,1 | 5/3 lossless + MCT | native |
| `synth-rgb16-rct-lossless-odd.j2k` | 16 | 63x45 @0,0 | 1,1 1,1 1,1 | 5/3 lossless + MCT | native |
| `synth-rgb16-ict-lossy-odd.j2k` | 16 | 63x45 @0,0 | 1,1 1,1 1,1 | 9/7 lossy + MCT | native |
| `synth-rgb12-rct-lossless-jp2.jp2` | 12 | 64x48 @0,0 | 1,1 1,1 1,1 | 5/3 lossless + MCT colr 16 | native |
| `synth-rgb8-sub-dy2.j2k` | 8 | 64x48 @0,0 | 1,2 1,2 1,2 | 5/3 lossless | native, upsample |
| `synth-rgb10-sub2x2-all.j2k` | 10 | 64x48 @0,0 | 2,2 2,2 2,2 | 5/3 lossless | native, upsample |
| `synth-sycc8-444-lossless.jp2` | 8 | 64x48 @0,0 | 1,1 1,1 1,1 | 5/3 lossless colr 18 | native, rgb |
| `synth-sycc8-420-lossless.jp2` | 8 | 64x48 @0,0 | 1,1 2,2 2,2 | 5/3 lossless colr 18 | native, rgb |
| `synth-sycc8-420-lossless-odd.jp2` | 8 | 63x45 @0,0 | 1,1 2,2 2,2 | 5/3 lossless colr 18 | native, rgb |
| `synth-sycc12-420-lossless-origin-tiles.jp2` | 12 | 63x45 @1,1 tiles 32x32 | 1,1 2,2 2,2 | 5/3 lossless colr 18 | native, rgb |
| `synth-sycc10-422-lossless-odd.jp2` | 10 | 63x45 @0,0 | 1,1 2,1 2,1 | 5/3 lossless colr 18 | native, rgb |
| `synth-sycc8-422-lossless-origin.jp2` | 8 | 63x48 @1,0 | 1,1 2,1 2,1 | 5/3 lossless colr 18 | native, rgb |
| `synth-sycc16-420-lossless.jp2` | 16 | 64x48 @0,0 | 1,1 2,2 2,2 | 5/3 lossless colr 18 | native, rgb |
| `synth-sycc16-420-lossy.jp2` | 16 | 64x48 @0,0 | 1,1 2,2 2,2 | 9/7 lossy colr 18 | native, rgb |
| `synth-3comp-420-bare-lossless.j2k` | 8 | 64x48 @0,0 | 1,1 2,2 2,2 | 5/3 lossless | native, rgb |
| `real-gray16-lossless-ffmpeg.j2k` | 16 | 64x48 @0,0 | 1,1 | 5/3 lossless | native |
| `real-rgb16-lossless-ffmpeg.j2k` | 16 | 64x48 @0,0 | 1,1 1,1 1,1 | 5/3 lossless | native |
| `real-sycc8-420-lossless-odd-ffmpeg.jp2` | 8 | 63x45 @0,0 | 1,1 2,2 2,2 | 5/3 lossless colr 18 | native, rgb |
| `real-sycc8-422-lossless-ffmpeg.jp2` | 8 | 64x48 @0,0 | 1,1 2,1 2,1 | 5/3 lossless colr 18 | native, rgb |
| `real-sycc10-420-lossless-ffmpeg.jp2` | 10 | 64x48 @0,0 | 1,1 2,2 2,2 | 5/3 lossless colr 18 | native, rgb |
| `real-sycc12-420-lossless-ffmpeg.jp2` | 12 | 64x48 @0,0 | 1,1 2,2 2,2 | 5/3 lossless colr 18 | native, rgb |
| `real-sycc12-420-lossy-ffmpeg.jp2` | 12 | 64x48 @0,0 | 1,1 2,2 2,2 | 9/7 lossy colr 18 | native, rgb |

## Hashes

SHA-256 of every committed file:

```
eca10259298aa16496f2249a1cabbdcbbd93c1a314821ad93636035be259d1b6  corpus.json
44f951e3f386a57dd42bdb42dc9192d1676704c7242ae456b8f6bc9e1d8b4fb2  oracle/real-gray16-lossless-ffmpeg.native.bin
6800f41dd5fc804c2dba3b5f6236567f2fedda10c94040d3841252bfda6c5525  oracle/real-gray16-lossless-ffmpeg.native.json
e3008d275419d471f5dab1fd363752aef6d424e271bc70a7f3060ddbaae7d8d4  oracle/real-rgb16-lossless-ffmpeg.native.bin
6f4a3dd748a9aab964d3d4d9aac6d720bcd32fbc0f66b60d1ab1def34bd650c1  oracle/real-rgb16-lossless-ffmpeg.native.json
296cb1c738f68f77df13e6454d980c0636876a8fd195a48dcd3c9bc2e5eea3ab  oracle/real-sycc10-420-lossless-ffmpeg.native.bin
0a421c2500bcc2948879059f70c63b5888b4740b6f9c242091278ddb8f28d0d1  oracle/real-sycc10-420-lossless-ffmpeg.native.json
35df9427d22aef36329299ca0df2632aec3e82bd7382bb45f2b0ddff99bf7afb  oracle/real-sycc10-420-lossless-ffmpeg.rgb.rawl
9c6dee99771d6018668d1217d54653906039d0ad2d895efed6447b49d0feb47f  oracle/real-sycc12-420-lossless-ffmpeg.native.bin
9b7772c294ef619f9a868ae8a0424355ae5f3810f77880844d39e30be94717c7  oracle/real-sycc12-420-lossless-ffmpeg.native.json
d69a405ce56dec761f72487991f3c45e26d43b9059d2858f6b701316540738f3  oracle/real-sycc12-420-lossless-ffmpeg.rgb.rawl
0eccee7dc4b8fb978edfffd1b98de7d81602ab31bc51aeca3100f1ac9de2b50d  oracle/real-sycc12-420-lossy-ffmpeg.native.bin
9b7772c294ef619f9a868ae8a0424355ae5f3810f77880844d39e30be94717c7  oracle/real-sycc12-420-lossy-ffmpeg.native.json
f536ff9ec13b7f40906de2f737ab48ed345848002c6f46e690d8ff8b6562590f  oracle/real-sycc12-420-lossy-ffmpeg.rgb.rawl
690fd566b8a62c1a046cc1a327dbd82b6909ee491b86c569c641ff328e0d5456  oracle/real-sycc8-420-lossless-odd-ffmpeg.native.bin
7c2b2c98eaca400b6f4ae08102447fa9b161128747cad7f710c5c25bbf3cb149  oracle/real-sycc8-420-lossless-odd-ffmpeg.native.json
0d54f7ac16eace2dc801f61a0d3c291ad8bfa889025fb46bd6534b5e9b427ca9  oracle/real-sycc8-420-lossless-odd-ffmpeg.rgb.rawl
6e104154a4e8d902f76d975f1f5a09d04b9b8043227fd1ab7f7caed27e06eba7  oracle/real-sycc8-422-lossless-ffmpeg.native.bin
b4f28942c6110beb984ef51aada03fbf05b84822683461625747c04dfdf82bf8  oracle/real-sycc8-422-lossless-ffmpeg.native.json
5213a23cb62e9326ec5e6627ab618ecf7e4ea6240387df2c17148dbc0d34a5f8  oracle/real-sycc8-422-lossless-ffmpeg.rgb.rawl
50d97ab3a67fa59dbaedcf2c5ef273de06a4959224a0a5d7ffe26dd5f8b41915  oracle/synth-3comp-420-bare-lossless.native.bin
1b439784160fc27ae117cc3fae84ed5ce1afd774b20205f809c8672ad1017d9d  oracle/synth-3comp-420-bare-lossless.native.json
450721b892638915a6a601c40a6f2d84db33129584a140d8cefd71fb7b1187f4  oracle/synth-3comp-420-bare-lossless.rgb.rawl
75d40cdb6d5f14d1213eca3c8365539358b6b6a6cfae887818d4d3d39f3d341b  oracle/synth-gray10-lossless-odd.native.bin
aa8c831faae92ad2a54473c0b3f746e2c6f1057ab767030f912476bd1f9e5569  oracle/synth-gray10-lossless-odd.native.json
f8195d75c69c7d89cedd7bd30bdd3a8a60235005fee0e93a41cee4af946a719b  oracle/synth-gray12-lossless-coc-qcc.native.bin
4d425b332796150f606c08cdc05a8b30bcea3858fb6196218a32dfe1465385ff  oracle/synth-gray12-lossless-coc-qcc.native.json
29963d43f03e725b4105c44f20419f0679c14bb0d2ec00002650ef93361c6294  oracle/synth-gray12-lossless-tiles.native.bin
e0390ef9c01a1366f219e0363d74785b3a4180b52ba3d8584a92f776f868d6bc  oracle/synth-gray12-lossless-tiles.native.json
1cc78ea2d4166ad7d155e5b202e4251e37e406f93161126e91e9ca2b1d8caaa6  oracle/synth-gray12-sub1x3-tiles.native.bin
f1773d0d77bac6a2209ea43534a5e22c02a0828b3685754c8e400f64727a8ae9  oracle/synth-gray12-sub1x3-tiles.native.json
c8cd3fc7964afe89d9a29b6ebe1b71c71e577610ab46c9a6cedf4ed0cf2906fb  oracle/synth-gray12-sub1x3-tiles.upsample.rawl
1c7dd2bdae01e55a3f11a545771f52cbb9b7ab910e868bf4ca28e6dcb4f048f4  oracle/synth-gray12-sub2x2-odd.native.bin
f2e2c7199127dcf7d30e23a76f24e6d5f60a074105dfd85635c3b979dce11eaf  oracle/synth-gray12-sub2x2-odd.native.json
0ff0e75fb2d9ad37c6696c9596253a8c0a0aab4c3e2be7e66c95cbe0c66a885c  oracle/synth-gray12-sub2x2-odd.upsample.rawl
d3f6178ea9623a82efd40a7519d41b1c545d1a914b40bf8e936a4d1202245ee7  oracle/synth-gray16-lossless-origin-tiles.native.bin
fa0a11d871d0e70eb5ed9c67e331627b4d0c52aae5d9d6febe92b9a4b8c878c0  oracle/synth-gray16-lossless-origin-tiles.native.json
8deea2ec5c8b2a53696fed4aa6e79b1b282365b92656ecba98911895d81efc24  oracle/synth-gray16-lossless.native.bin
6800f41dd5fc804c2dba3b5f6236567f2fedda10c94040d3841252bfda6c5525  oracle/synth-gray16-lossless.native.json
045fb0fe6a6f9ddd708b3ccf8632afefe16925510863f1bdc10d5716ed11adf5  oracle/synth-gray16-lossy.native.bin
6800f41dd5fc804c2dba3b5f6236567f2fedda10c94040d3841252bfda6c5525  oracle/synth-gray16-lossy.native.json
dd6c55cade4596c581f9ab578441435c9bc7a084d2a4a46c1e0aed70c16f0030  oracle/synth-gray16-sub2x2-odd-lossless.native.bin
8b7a21581578443e5db38a8e5680acca70b304b4ba6cccc8393e3ce62c2b3646  oracle/synth-gray16-sub2x2-odd-lossless.native.json
abd121ef676502e8a60b5e1be9adc04c0008b2fa203871ca1a89fd3133a2216f  oracle/synth-gray16-sub2x2-odd-lossless.upsample.rawl
3f63c84a98eaddee971e351cdb99819ad8ab6d8b21a0130d79a5ccfba7940ac1  oracle/synth-gray16-sub2x2-odd-lossy.native.bin
8b7a21581578443e5db38a8e5680acca70b304b4ba6cccc8393e3ce62c2b3646  oracle/synth-gray16-sub2x2-odd-lossy.native.json
3146a2eb62f835b6af930e438a7e6a93ade2bd836dbd07fd2dd41e0aa3f00566  oracle/synth-gray16-sub2x2-odd-lossy.upsample.rawl
3d057e5bd8f251217c81a41aaff74c8878aabfd7fece25cb9f49af292200d52a  oracle/synth-gray8-sub2x1-origin.native.bin
f2f959ae3bb6993731fd9dea9c30860436330f427af651929e0b3838df09146e  oracle/synth-gray8-sub2x1-origin.native.json
befc10d7389d0838bf00ae60e49b4951e350cc806154a515b9b92c8588d27da3  oracle/synth-gray8-sub2x1-origin.upsample.rawl
5aa4b1960a9911570b4dd5c0f7ca08fe85e0557fc3adc321c3d578a1402056a9  oracle/synth-gray9-lossless.native.bin
0b3b5f7ff51b35dc0f15efb9e4bf31469af3939e57c8366bcf715340241e519d  oracle/synth-gray9-lossless.native.json
cdd09b4fab46a5516700667c68edf4e8c0c2d808ff8f86adef8ec3aefccb72db  oracle/synth-rgb10-sub2x2-all.native.bin
a859bb05f731df32a023d94a486918b75bb9004c82cfe035c0cdf9fdba0e2f2c  oracle/synth-rgb10-sub2x2-all.native.json
828998a8a139c6bde6cf791603173711d002922ff8e99dd4c5b4ca22006929f9  oracle/synth-rgb10-sub2x2-all.upsample.rawl
b5d05e84897ad3ba70e9966f5e6fd75df3d6332f39bf6025f083dcf14799d0c8  oracle/synth-rgb12-rct-lossless-jp2.native.bin
2ef0af5bdaba0b50d5d118b870e26497d2b83f29b09eee5c5bf39500043fad1b  oracle/synth-rgb12-rct-lossless-jp2.native.json
b5d05e84897ad3ba70e9966f5e6fd75df3d6332f39bf6025f083dcf14799d0c8  oracle/synth-rgb12-rct-lossless.native.bin
a9d6fe93770e2f39d8c664e42c22fa6f500847f923c11eb10acb9005ab9a1f5d  oracle/synth-rgb12-rct-lossless.native.json
35eac9d983436a195cc3295b80f2620c5ceb4cbbb55790692851cbe0a887d355  oracle/synth-rgb16-ict-lossy-odd.native.bin
690d964cee3bf71a7b4448eb23344679654585ef9b6da83c63a4788e2396b0e2  oracle/synth-rgb16-ict-lossy-odd.native.json
07dabb0c69babde00794c97a885dd47db11182bc83bd9dffd1bb8a1bf6e2e7c4  oracle/synth-rgb16-rct-lossless-odd.native.bin
690d964cee3bf71a7b4448eb23344679654585ef9b6da83c63a4788e2396b0e2  oracle/synth-rgb16-rct-lossless-odd.native.json
f0c4bcaae31edef9b39a509c9a4861f562a0576a039957ae75de998a6dcf8c58  oracle/synth-rgb8-sub-dy2.native.bin
ccf38e2dafe91faca2b67b53a28ad54090ad0dc74bbf6ae6d846d99be767bb9b  oracle/synth-rgb8-sub-dy2.native.json
21d314f0dd70af7bd8bacee0936803b159c2db10b5b57fdc2cd36e4242c705b6  oracle/synth-rgb8-sub-dy2.upsample.rawl
c2ca934da4324556f68a4b90d17b10d2b58b30f5f001e93aee5caa602604314a  oracle/synth-sycc10-422-lossless-odd.native.bin
819b2a50048bc39b732896ec8e6faf8ec1233bf54d7ab1c49d3d19552b828f13  oracle/synth-sycc10-422-lossless-odd.native.json
e0be250dff33d251a9169641136292e425e728d5e7ec9a2e505efc1f80291c82  oracle/synth-sycc10-422-lossless-odd.rgb.rawl
ff3f763ec23274beb81856d12b7489408d60ab680fda4b0a9f8d30ae8d11604c  oracle/synth-sycc12-420-lossless-origin-tiles.native.bin
74579feb33d718f155861e9d0d2d18adabfb95b03e30efa9c20b8fcee652ed9d  oracle/synth-sycc12-420-lossless-origin-tiles.native.json
cb7c992e379ddb72ef451473c78ca7e2609a688af5128dc1480c7199bd762ee8  oracle/synth-sycc12-420-lossless-origin-tiles.rgb.rawl
99d8ff3e034f820b5e995e69aef59470f2044554e2d13ce9e3db67dd351fc720  oracle/synth-sycc16-420-lossless.native.bin
0527868fcfe7cd263270596d7495bbcfef108189575a1f7fcfd2bd64cf67e04f  oracle/synth-sycc16-420-lossless.native.json
46c385f52aa3986aa924e34374e62402b58cc49ee6aa8af279a18dbe9167ebff  oracle/synth-sycc16-420-lossless.rgb.rawl
3070bce7a329d262312b146ba708fe533c2a427ac4ffa196b7b377b61eb040a2  oracle/synth-sycc16-420-lossy.native.bin
0527868fcfe7cd263270596d7495bbcfef108189575a1f7fcfd2bd64cf67e04f  oracle/synth-sycc16-420-lossy.native.json
511b6bf733d44b6c9092d7493ca7a5706c2b85ed287d0da0a77d976085aee71f  oracle/synth-sycc16-420-lossy.rgb.rawl
6692112ea1c28b84d7ffe5a55a1bff36a42c9c836c6550b77e48d4ecaf66fc67  oracle/synth-sycc8-420-lossless-odd.native.bin
7c2b2c98eaca400b6f4ae08102447fa9b161128747cad7f710c5c25bbf3cb149  oracle/synth-sycc8-420-lossless-odd.native.json
0680de1e33c26fb29b438fe71cc58ce97f3c57350900dc534a6f201f49ea2eb3  oracle/synth-sycc8-420-lossless-odd.rgb.rawl
2d5a18e8c337accd47ac98e1a8385f96823bc7e0988e4b32d07ae8e5367d2f49  oracle/synth-sycc8-420-lossless.native.bin
54c1f0fdf5d6d79f4c9cb55ba1faa2665add86bb87de7b6f173b8f2794d3b51e  oracle/synth-sycc8-420-lossless.native.json
1766022552eab96fb302af8521e1a826d3c3d8905b78eccc3190059897c48aea  oracle/synth-sycc8-420-lossless.rgb.rawl
071c1bae1e551b26df4f4d4b441cab6097f5cd4aee5502c45172903fabcca0c2  oracle/synth-sycc8-422-lossless-origin.native.bin
ce2bfefcf2359c1aa266d8c0572b33f23ddeaaefb1d3a8b716ce6bacb0eac130  oracle/synth-sycc8-422-lossless-origin.native.json
794788d64313a8e2d3055074ff884c2c3b684a4c3706fafe13d6b86e7e1361cc  oracle/synth-sycc8-422-lossless-origin.rgb.rawl
a65695904757b2a027b2dced16cb90ff499af0f5968fd7c4656e807dfed20a82  oracle/synth-sycc8-444-lossless.native.bin
d3e0bf48d3b3a29466ce11b0ed80a0cbc89c6944ca42566263c7850ee6a2f80f  oracle/synth-sycc8-444-lossless.native.json
23eaf4c2150857f887092d8697c51b6790b9616767b0d00eb42622cc6cec751a  oracle/synth-sycc8-444-lossless.rgb.rawl
21ec8eed2a0e52d7c1e8b0612cd69550bd945fe661d7c03f701e05d0749d1de7  real-gray16-lossless-ffmpeg.j2k
faa3547da201e468a2e2219917991c4e62c25db3198b1638c7bc1a5334de8603  real-rgb16-lossless-ffmpeg.j2k
77cb6db28d864a37a346870407d26da6efe109a06d9d26ac62cd647123dd6be3  real-sycc10-420-lossless-ffmpeg.jp2
85a55bbe9c48275ddfdc5abe86728e95725753ae5038fb7328e7d07e27e58a34  real-sycc12-420-lossless-ffmpeg.jp2
cf87ab01f64e0eef70fe671bc8adc2671f91b09b201911ed3bb550ec3aeceb88  real-sycc12-420-lossy-ffmpeg.jp2
1480612b0b20294daa3e479ffd236738b16c7f0991e32ed52b2b14fb38f248ec  real-sycc8-420-lossless-odd-ffmpeg.jp2
a9974c784576d243591e38e01149fb4ff3d9632f90d0eb4dfd086c5438ae1602  real-sycc8-422-lossless-ffmpeg.jp2
9b1ba6adcefdd7c7a13ade8a4682d8c8c4b84e13ab397e0a2177610db240ecaf  synth-3comp-420-bare-lossless.j2k
833c7841a882f2e9f2fe77b60aa8a1c7075d40cdb77ebf3666af0faf2123f250  synth-gray10-lossless-odd.j2k
8360008e2b5d0429423336a9440a4721b7fc7b9c0d9620052d9318a844986524  synth-gray12-lossless-coc-qcc.j2k
84dbca348f4e0f657fd7ac16e7ad7906b816a016ae8ec00b8ea9cc9cb44f0266  synth-gray12-lossless-tiles.j2k
3f5ea4e6420ed1db49325e65672689e5a218839c200dddbbcf42bc1162d9104a  synth-gray12-sub1x3-tiles.j2k
b5f233059b1e4fb80563cf9e5297d4caf42243032732a561b276a6f46b5dc63e  synth-gray12-sub2x2-odd.j2k
e97fc3e14bc80afa1bfdbcba2b5fa9c841ef14d9d887ec92c2b198283d34d4c9  synth-gray16-lossless-origin-tiles.j2k
8a37fbedf5ce208c438d1604071c8cef76ecb1c70307aa32b55cde6f0ce349e5  synth-gray16-lossless.j2k
05f94ce5105cf3d0030dd1d72c3a3e577f296c7395917c0657efbe659a773f4d  synth-gray16-lossy.j2k
1b7c2d82ed74c88f8e0caf010764be7cc071fe1f34463f3c5ce6fb42e5b723af  synth-gray16-sub2x2-odd-lossless.j2k
5de11464a0433b1abc3ff28bb102b0db478104db7e3057f896ce8466568a3592  synth-gray16-sub2x2-odd-lossy.j2k
4ce29ec025a6c0f50ddcd61ed8d776d83bfd270b8a37e1706bc6afced942b4eb  synth-gray8-sub2x1-origin.j2k
572371ce81c65dfc10b4e49674d3e7ddec08605807d70014bfbaa8a2db94e1ee  synth-gray9-lossless.j2k
1d3fb5d94654b02b6ea9a38085eeab7493cddf19409d3d57ee01907af279caaf  synth-rgb10-sub2x2-all.j2k
892a6ae33c1b9ee67d55217d8338e738be74a920287767d0f6a065b6c90b01cf  synth-rgb12-rct-lossless-jp2.jp2
35f300f4168866992c9bf238cbfe7edc1119b5aeb7ca8afc26d13a8bb5929198  synth-rgb12-rct-lossless.j2k
382031545cfc5a2705faf8d58284defb8beb2bdcaf44e729247186b0250689b9  synth-rgb16-ict-lossy-odd.j2k
45bf0f30079eb8b13145c11bd771d276935ec556ad81258afcea2b863b024bc3  synth-rgb16-rct-lossless-odd.j2k
191c2af6afeb570244c85a777b4ff652d52996bc877d155a8fc82f762a1a554a  synth-rgb8-sub-dy2.j2k
d5118b6630a237a7b7b57fc9a58cefd1892868e97053a5e05d4d0042fc95f2e8  synth-sycc10-422-lossless-odd.jp2
cb109a70f22f9c48dd1fbf31c2bcc2e7f85e954601ab249814cd95d15c19e13c  synth-sycc12-420-lossless-origin-tiles.jp2
da8fad276b02e1150efde46cc43e710d1c08df69db6015cebaf309bdb6762c8d  synth-sycc16-420-lossless.jp2
58dfea50ed58721405fa36c7b88a5e2e894c09e8308b05ea28fd3fcba7851fff  synth-sycc16-420-lossy.jp2
483330c3e7b9f2c78bc08e164ddff22014bf5c8051dcf7e3934a0206262607bf  synth-sycc8-420-lossless-odd.jp2
5ce6309752e9776f52eaa5518419fb035aea7a982596b599139785488978c763  synth-sycc8-420-lossless.jp2
c37305cfc9f35b3686d7028db7adf8d1495fa88d922141be7d0c660d4decdc45  synth-sycc8-422-lossless-origin.jp2
c2602ebe656ac1780ed053844a200e56b4f96d871699f9a97dcbd62bf77e0125  synth-sycc8-444-lossless.jp2
4ff43df4c85a7240f4ef704b844f3e20e11f985b08f58a255877266af189ffa6  tolerances.json
```
