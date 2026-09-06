#!/usr/bin/env node
// Reference oracle: decodes one image XObject from a PDF with
// pdf.js v3.11.174 internals and prints the bitmap as PGM (P5,
// 0 = black, 255 = white) on stdout.
//
//   node tool/reference/pdfjs_image.mjs <pdf> <objectNumber> [--pbm]
//
// Wiring: `npm install --prefix tool/reference` brings in
// pdfjs-dist@3.11.174 (see package.json); the main bundle is a
// webpack build, so we load it in a vm context and capture
// `__w_pdfjs_require__` to reach the internal module map
// (151 = core/primitives, 155 = core/stream, 153 = core/document,
// 172 = core/ccitt, 175 = core/jbig2, 216 = core/image). Exit code 3
// means pdfjs-dist is not installed — the parity harness treats that
// as "skip", not "fail".
import { readFileSync } from "node:fs";
import vm from "node:vm";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

let pdfjs;
try {
  pdfjs = require(path.join(here, "node_modules/pdfjs-dist/legacy/build/pdf.worker.js"));
} catch {
  console.error("pdfjs-dist is not installed; run: npm install --prefix tool/reference");
  process.exit(3);
}

const argsRest = process.argv.slice(2);
const [pdfPath, objectNumberArg, flag] = argsRest;
const outputPath = argsRest.find((a, i) => i >= 2 && !a.startsWith('--'));
if (!pdfPath || !objectNumberArg) {
  console.error("usage: node tool/reference/pdfjs_image.mjs <pdf> <objectNumber> [--pbm]");
  process.exit(2);
}
const objectNumber = Number(objectNumberArg);
const asPbm = flag === "--pbm";
const emit = (chunk) => {
  if (outputPath) {
    fsAppend(outputPath, chunk);
  } else {
    process.stdout.write(chunk);
  }
};
import { appendFileSync as fsAppend, rmSync as fsRm } from "node:fs";

// The webpack bundle hides its module map behind `__w_pdfjs_require__`
// inside the factory closure; patch the bundle tail to expose it.
// The core classes (CCITTFaxDecoder, Jbig2Image, PDFImage, ...) live in
// the worker bundle; the main pdf.js bundle only carries the API layer.
const bundlePath = path.join(here, "node_modules/pdfjs-dist/legacy/build/pdf.worker.js");
const src = readFileSync(bundlePath, "utf8");
const marker = "return __webpack_exports__;";
if (!src.includes(marker)) {
  console.error("pdf.js bundle layout changed; capture hook not found.");
  process.exit(4);
}
const patched = src.replace(
  marker,
  "globalThis.__pdfjsRequireCapture && globalThis.__pdfjsRequireCapture(__w_pdfjs_require__);\nreturn __webpack_exports__;"
);

const contextGlobal = {
  console,
  process,
  setTimeout,
  clearTimeout,
  setInterval,
  clearInterval,
  queueMicrotask,
  URL,
  URLSearchParams,
  Blob,
  File,
  FormData,
  Headers,
  Request,
  Response,
  fetch,
  AbortController,
  AbortSignal,
  DOMException,
  structuredClone,
  TextEncoder,
  TextDecoder,
  Atomics,
  SharedArrayBuffer,
  WebAssembly,
  MessageChannel,
  MessagePort,
  MessageEvent,
  EventTarget,
  Event,
  CustomEvent,
  path,
  require,
  exports: {},
};
const context = vm.createContext(contextGlobal);
let req;
contextGlobal.globalThis = contextGlobal;
contextGlobal.__pdfjsRequireCapture = (capture) => {
  req = capture;
};
new vm.Script(patched, { filename: "pdf.js" }).runInContext(context);
if (!req) {
  console.error("module require capture failed.");
  process.exit(4);
}

const Ref = req(151).Ref; // core/primitives
const Dict = req(151).Dict;
const { PDFDocument } = req(156); // core/document
const { PDFImage } = req(216); // core/image
const { PDFFunctionFactory } = req(208);

const data = readFileSync(pdfPath);
const arrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);

const manager = new (req(153).LocalPdfManager)({
  docId: "oracle",
  docBaseUrl: null,
  password: "",
  enableXfa: false,
  evaluatorOptions: {
    isEvalSupported: false,
    disableFontFace: true,
    fontExtraProperties: false,
    useSystemFonts: true,
    isOffscreenCanvasSupported: false,
  },
  source: arrayBuffer,
});

const doc = manager.pdfDocument;
doc.xref.setStartXRef(doc.startXRef);
await doc.parse();

const imageRef = Ref.get(objectNumber, 0);
const imageDict = doc.xref.fetch(imageRef);
const imageObj = await PDFImage.buildImage({
  xref: doc.xref,
  res: Dict.empty,
  image: imageDict,
  isInline: false,
  pdfFunctionFactory: new PDFFunctionFactory({ xref: doc.xref, isEvalSupported: false }),
  localColorSpaceCache: new (req(210).LocalColorSpaceCache)(),
});
const isMask = imageObj.imageMask === true;
// Image masks have no color space; their decoded bytes come from the
// CCITT/JBIG2 stream directly (packed rows, MSB first, 1 = black
// before /Decode inversion).
let width, height, raster;
if (isMask) {
  width = imageObj.width;
  height = imageObj.height;
  raster = imageObj.getImageBytes(height * ((width + 7) >> 3), {
    drawWidth: width,
    drawHeight: height,
    internal: true,
  });
  const decode = imageObj.decode || [];
  const inverseDecode = decode.length === 2 && decode[0] === 1 && decode[1] === 0;
  if (inverseDecode) {
    const flipped = new Uint8Array(raster.length);
    for (let i = 0; i < raster.length; i++) {
      flipped[i] = ~raster[i];
    }
    raster = flipped;
  }
} else {
  // kind: 1 = GRAYSCALE_1BPP — packed rows, MSB first, 1 = white.
  const decoded = await imageObj.createImageData(false, false);
  const { kind } = decoded;
  if (kind !== 1) {
    console.error(`unexpected image kind ${kind}; oracle only handles 1-bit masks.`);
    process.exit(5);
  }
  ({ width, height } = decoded);
  raster = decoded.data;
}

const stride = (width + 7) >> 3;
if (outputPath) fsRm(outputPath, { force: true });
emit(`P5\n${width} ${height}\n255\n`);
for (let y = 0; y < height; y++) {
  const row = Buffer.alloc(width);
  for (let x = 0; x < width; x++) {
    const bit = (raster[y * stride + (x >> 3)] >> (7 - (x & 7))) & 1;
    // GRAYSCALE_1BPP and raw mask bytes both carry 1 = white once the
    // /Decode inversion above has been applied.
    row[x] = bit === 1 ? 255 : 0;
  }
  emit(row);
}
if (asPbm) {
  // PBM (P4) form: 1 = black, packed rows — pdf.js's raw raster with
  // the bits as-is.
  process.stdout.write(`P4\n${width} ${height}\n`);
  process.stdout.write(Buffer.from(raster.buffer, raster.byteOffset, raster.byteLength));
}
