// Raster goldens of the planar/palette TIFF corpus, pinned after
// tool/tiff_planar_palette_compare.dart matched every page against
// libtiff 4.7.2 (see doc/tiff-planar-palette.md). Shared by the VM
// and browser suites so both platforms are held to the same pixels.

/// SHA-256 of every page image (BMP) per fixture, in page order.
const Map<String, List<String>> planarPaletteTiffGoldens = <String, List<String>>{
  // Lives in the strip corpus (test/resources/tiff/), verified through
  // the same libtiff comparison.
  'palette-1c-8b.tiff': ['31f1c7694cc72cef2a7b95e610926cc30b849a836ab6132abc0de71c68f271e4'],
  'flower-palette-02.tif': ['f46c1ad1c8dc3bf397ebabf517ed52a878a9aa9cd10e06d6fab38b713d55b610'],
  'flower-palette-04.tif': ['1e251eedd44c0d7878acf597adb9fee3129a9f81e36326c3bf0405f18dfca8a6'],
  'flower-palette-08.tif': ['5d11eee95fb296bb07d8078dc6eac0cff2cc924a2cfb7c06a9b3f2fb04ffba1a'],
  'flower-planar-none-t32-be.tif': [
    '09860d76074c3f8defe29b08b12ad080cce07c1c8f1360c671d01c0841f749a6',
  ],
  'flower-planar16-zip2-t16.tif': [
    '37889914e81a1304a54204377e54082ac59a072eb698073894e4d458a2942ce7',
  ],
  'flower-rgb-planar-08.tif': ['09860d76074c3f8defe29b08b12ad080cce07c1c8f1360c671d01c0841f749a6'],
  'flower-rgb-planar-16.tif': ['19d6ba6fd9ff475f543f454f75b04cd375985777bad60a3f1adba4e65beae6fa'],
  'jello-zip-t32-be.tif': ['9c24f73d88c18c2098b33730c13c536c56720f3babba0aeef973bc35f0e5e139'],
  'jello.tif': ['9c24f73d88c18c2098b33730c13c536c56720f3babba0aeef973bc35f0e5e139'],
  'mixed-planar-big-be-2page.tif': [
    'e4b911723d8eda325e6a687e1b6de4a0e79bfee2f5525d8fa9ffc3cc58a33b62',
    '31f1c7694cc72cef2a7b95e610926cc30b849a836ab6132abc0de71c68f271e4',
  ],
  'mixed-planar-palette-3page.tif': [
    '2fd30770f6c2eca0e5bd5449c737803eb00ce89484411d87b853a414a2313357',
    '806ddc86d5760ab55b5c750d7b4477b8926068a3cf7c35f918809af18c13fcfb',
    '31f1c7694cc72cef2a7b95e610926cc30b849a836ab6132abc0de71c68f271e4',
  ],
  'palette1-none-strips-be.tif': [
    '14d57fd863118d1abb75bc6bd07bdb725a989e2a4f0d6d18872bfbba4fc84ecf',
  ],
  'palette2-enc-strips-be.tif': [
    'c13a66611b9c8158e529df876c5a2fc78b8a6b343fc1d8ca50ee283af0b0638b',
  ],
  'palette2-packbits-strips.tif': [
    'f46c1ad1c8dc3bf397ebabf517ed52a878a9aa9cd10e06d6fab38b713d55b610',
  ],
  'palette4-enc-strips.tif': ['c27619eed83a79f0e117eb72f9c101577ec18e28cea508d0313055b942de09df'],
  'palette4-t16.tif': ['1e251eedd44c0d7878acf597adb9fee3129a9f81e36326c3bf0405f18dfca8a6'],
  'palette8-enc-strips.tif': ['752c1a7340aff7c7d2852670b25119e2126fe898b1293a8805173dbe84b3d9d1'],
  'palette8-legacy8bit.tif': ['752c1a7340aff7c7d2852670b25119e2126fe898b1293a8805173dbe84b3d9d1'],
  'palette8-none-t16-le.tif': ['31f1c7694cc72cef2a7b95e610926cc30b849a836ab6132abc0de71c68f271e4'],
  'palette8-o4-t32.tif': ['ab58085e5e05aa8dac6a2404d4ddf9dff476ea23712763796f7678636f7ccfbe'],
  'palette8-packbits-strips-be.tif': [
    '31f1c7694cc72cef2a7b95e610926cc30b849a836ab6132abc0de71c68f271e4',
  ],
  'palette8-zip-t16-big.tif': ['31f1c7694cc72cef2a7b95e610926cc30b849a836ab6132abc0de71c68f271e4'],
  'planar16-lzw-t32-be.tif': ['e4b911723d8eda325e6a687e1b6de4a0e79bfee2f5525d8fa9ffc3cc58a33b62'],
  'planar16-none-strips.tif': ['e4b911723d8eda325e6a687e1b6de4a0e79bfee2f5525d8fa9ffc3cc58a33b62'],
  'planar16-o3-strips-big-be.tif': [
    'a6e50e89bd15222fcc4ed305185696a2a44614a6b5ba518726fe3eebe487b785',
  ],
  'planar16-zip2-t16.tif': ['e4b911723d8eda325e6a687e1b6de4a0e79bfee2f5525d8fa9ffc3cc58a33b62'],
  'planar8-lzw2-strips.tif': ['2fd30770f6c2eca0e5bd5449c737803eb00ce89484411d87b853a414a2313357'],
  'planar8-none-strips.tif': ['806ddc86d5760ab55b5c750d7b4477b8926068a3cf7c35f918809af18c13fcfb'],
  'planar8-none-t16-le.tif': ['55b3cdfdee78ed595b46fe1e4122f1b8430e6d7cad91fec4fdf4dbe8412dc95c'],
  'planar8-o2-t16.tif': ['eccaaf454884cc9adbff3a879fccbe3b24efc5a20ecbc31e8aea4f1b0f46a7f0'],
  'planar8-packbits-t32-be.tif': [
    '55b3cdfdee78ed595b46fe1e4122f1b8430e6d7cad91fec4fdf4dbe8412dc95c',
  ],
  'planar8-rows8.tif': ['806ddc86d5760ab55b5c750d7b4477b8926068a3cf7c35f918809af18c13fcfb'],
  'planar8-zip2-t16-big.tif': ['55b3cdfdee78ed595b46fe1e4122f1b8430e6d7cad91fec4fdf4dbe8412dc95c'],
  'quad-planar-zip2-t64-big-be.tif': [
    '87a17cb926cfdaecb43f778d72e883c4963d2d407aaf39fbeb47faa884ba26f8',
  ],
};
