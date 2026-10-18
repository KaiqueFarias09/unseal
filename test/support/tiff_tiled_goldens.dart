// Raster goldens of the tiled TIFF corpus, pinned after
// tool/tiff_tiles_compare.dart matched every page against libtiff 4.7.2
// (see doc/tiff-tiles.md). Shared by the VM and browser suites so both
// platforms are held to the same pixels.

/// SHA-256 of every page image (BMP) per fixture, in page order.
const Map<String, List<String>> tiledTiffGoldens = <String, List<String>>{
  'bilevel-g3-2d-fill-t32x16.tif': [
    'cc92122824b4596f61f2e4a3bca0dfb345fe445665aec0c07c1a573285be34e3',
  ],
  'bilevel-g3-t32x16-be.tif': ['cc92122824b4596f61f2e4a3bca0dfb345fe445665aec0c07c1a573285be34e3'],
  'bilevel-g4-o2-t32x16.tif': ['ce800f8663b4547583f278c4ae894a116291ef36a3331805c491bca5f2d33900'],
  'bilevel-g4-t16-edge-be.tif': [
    'e90c21e9b6ba6bc97671539db74e5cf601c6e44f8e66b540b1a1dc31e0ca3915',
  ],
  'bilevel-g4-t32x16.tif': ['cc92122824b4596f61f2e4a3bca0dfb345fe445665aec0c07c1a573285be34e3'],
  'bilevel-lzw-t64-be.tif': ['e90c21e9b6ba6bc97671539db74e5cf601c6e44f8e66b540b1a1dc31e0ca3915'],
  'bilevel-mh-strips.tif': ['cc92122824b4596f61f2e4a3bca0dfb345fe445665aec0c07c1a573285be34e3'],
  'bilevel-mh-t16-edge.tif': ['e90c21e9b6ba6bc97671539db74e5cf601c6e44f8e66b540b1a1dc31e0ca3915'],
  'bilevel-mh-t32x16.tif': ['cc92122824b4596f61f2e4a3bca0dfb345fe445665aec0c07c1a573285be34e3'],
  'bilevel-none-t32.tif': ['cc92122824b4596f61f2e4a3bca0dfb345fe445665aec0c07c1a573285be34e3'],
  'bilevel-packbits-t16.tif': ['e90c21e9b6ba6bc97671539db74e5cf601c6e44f8e66b540b1a1dc31e0ca3915'],
  'cramps-lzw2-t64.tif': ['e5c99cad413159c83ed999c622b2fad87c8d92e10eb5302a2fa57d775ac31606'],
  'cramps-tile.tif': ['e5c99cad413159c83ed999c622b2fad87c8d92e10eb5302a2fa57d775ac31606'],
  'cramps.tif': ['e5c99cad413159c83ed999c622b2fad87c8d92e10eb5302a2fa57d775ac31606'],
  'fax2d-g3-2d-t64.tif': ['53d9b85e17c318a9270b9e7b05e99658993ca0fdac0cc3f452d984012c2f91ca'],
  'fax2d-g4-t64.tif': ['53d9b85e17c318a9270b9e7b05e99658993ca0fdac0cc3f452d984012c2f91ca'],
  'fax2d-mh-t128x64-be.tif': ['53d9b85e17c318a9270b9e7b05e99658993ca0fdac0cc3f452d984012c2f91ca'],
  'gray16-lzw2-t16-le.tif': ['8e8f5a904fa343524f9b92c8e891ca5b695b1f8449e8d8d0a9acf11683191a59'],
  'gray16-none-t16-be.tif': ['8e8f5a904fa343524f9b92c8e891ca5b695b1f8449e8d8d0a9acf11683191a59'],
  'gray16-zip2-t16-big-be.tif': [
    '8e8f5a904fa343524f9b92c8e891ca5b695b1f8449e8d8d0a9acf11683191a59',
  ],
  'gray2-lzw-t16-be.tif': ['29e2a636f61992bcb18b15dadd044312b87d0a76055cc07c232fc6e75bef4473'],
  'gray4-none-t16.tif': ['0af0308184ae3fdb7787b65f7b131a27e2dadbd27f2087ee2e24b9d858547ce3'],
  'gray8-1x1-t16-big.tif': ['16e6c4f8d43518c39f7f6ebe8b370ee33df3a8274de97456507c76b9cd608cef'],
  'gray8-lzw-t32.tif': ['20eae2565ed0d1cbd917190c541f2bdb8cb5140ab71edbbfc5b8e6144b7f467e'],
  'gray8-lzw2-t32-be.tif': ['20eae2565ed0d1cbd917190c541f2bdb8cb5140ab71edbbfc5b8e6144b7f467e'],
  'gray8-none-t16-le.tif': ['20eae2565ed0d1cbd917190c541f2bdb8cb5140ab71edbbfc5b8e6144b7f467e'],
  'gray8-o2-t16.tif': ['8790db8e304e6dca3646bb8401d4099a0ca2fb64ef2c7cbbf721d1be60d46e0f'],
  'gray8-o3-t16.tif': ['bf8b45bbc0d3e39f97b5999930e4dabdbf056855ef21202662996f5e2a080443'],
  'gray8-o4-t16-be.tif': ['fd025e434280294637c82c1f3a33d8eee9602b9bbfcf68c8c7e8efd17b2ad0cc'],
  'gray8-packbits-t16-be.tif': ['20eae2565ed0d1cbd917190c541f2bdb8cb5140ab71edbbfc5b8e6144b7f467e'],
  'gray8-t16x64.tif': ['20eae2565ed0d1cbd917190c541f2bdb8cb5140ab71edbbfc5b8e6144b7f467e'],
  'gray8-tiny-7x5-t16.tif': ['031be82b193290ce9fdc3e404dadd09673624549ba1793e384779a68e278c332'],
  'gray8-zip-t16.tif': ['20eae2565ed0d1cbd917190c541f2bdb8cb5140ab71edbbfc5b8e6144b7f467e'],
  'gray8-zip2-t16-big.tif': ['20eae2565ed0d1cbd917190c541f2bdb8cb5140ab71edbbfc5b8e6144b7f467e'],
  'ladoga-lzw2-t32-be.tif': ['c3da28cb3fd316e69ff06bd8e16d710b86f0d723e55fa16457b89b1a276a08a8'],
  'ladoga-zip2-t16.tif': ['c3da28cb3fd316e69ff06bd8e16d710b86f0d723e55fa16457b89b1a276a08a8'],
  'ladoga.tif': ['c3da28cb3fd316e69ff06bd8e16d710b86f0d723e55fa16457b89b1a276a08a8'],
  'mixed-big-be-2page.tif': [
    '8e8f5a904fa343524f9b92c8e891ca5b695b1f8449e8d8d0a9acf11683191a59',
    '55b3cdfdee78ed595b46fe1e4122f1b8430e6d7cad91fec4fdf4dbe8412dc95c',
  ],
  'mixed-strip-tile-3page.tif': [
    'cd042d93d8f190658420e7c3f94f734ed1e9de31a375560aa0d65893de49e7b1',
    '55b3cdfdee78ed595b46fe1e4122f1b8430e6d7cad91fec4fdf4dbe8412dc95c',
    'cc92122824b4596f61f2e4a3bca0dfb345fe445665aec0c07c1a573285be34e3',
  ],
  'quad-tile.tif': ['87a17cb926cfdaecb43f778d72e883c4963d2d407aaf39fbeb47faa884ba26f8'],
  'quad-zip2-t32-big.tif': ['87a17cb926cfdaecb43f778d72e883c4963d2d407aaf39fbeb47faa884ba26f8'],
  'rgb16-zip2-t16.tif': ['e4b911723d8eda325e6a687e1b6de4a0e79bfee2f5525d8fa9ffc3cc58a33b62'],
  'rgb8-exact-32x32-t32.tif': ['e81fdbbf9b75b290e10d467cefdb8ee847a31474f30a8d2d71e64b6d2d5e2864'],
  'rgb8-lzw2-t16.tif': ['55b3cdfdee78ed595b46fe1e4122f1b8430e6d7cad91fec4fdf4dbe8412dc95c'],
  'rgb8-none-t16.tif': ['55b3cdfdee78ed595b46fe1e4122f1b8430e6d7cad91fec4fdf4dbe8412dc95c'],
  'rgb8-o3-t32.tif': ['eddee9282271ae479a2655d268091a2e4f5e124c4aebf642c6ed958ab6045b40'],
  'rgb8-packbits-t32-be.tif': ['55b3cdfdee78ed595b46fe1e4122f1b8430e6d7cad91fec4fdf4dbe8412dc95c'],
  'rgb8-zip2-t32-big-be.tif': ['55b3cdfdee78ed595b46fe1e4122f1b8430e6d7cad91fec4fdf4dbe8412dc95c'],
};
