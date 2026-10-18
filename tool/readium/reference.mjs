// D01 reference runner: executes the official @readium/shared Locator model
// over the fixed corpus and records the results as comparison evidence.
//
// The expected outputs are derived here, by running the toolkit — never
// stored in the corpus. Writes <evidence-dir>/reference.json.
//
// Usage: node tool/readium/reference.mjs <evidence-dir> [corpus-json]
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const toolDir = dirname(fileURLToPath(import.meta.url));
const evidenceDir = process.argv[2];
const corpusArg = process.argv[3];
if (!evidenceDir) {
  console.error('usage: node tool/readium/reference.mjs <evidence-dir> [corpus-json]');
  process.exit(2);
}
const corpusPath = corpusArg ?? join(toolDir, 'corpus', 'locator-cases.json');

const require_ = createRequire(join(toolDir, 'package.json'));
// @readium/shared does not export ./package.json; read the installed file by path.
const sharedPkg = JSON.parse(
  readFileSync(join(toolDir, 'node_modules', '@readium', 'shared', 'package.json'), 'utf8'),
);
const { Locator } = await import('@readium/shared');

const sha256 = (path) =>
  createHash('sha256').update(readFileSync(path)).digest('hex');

const corpus = JSON.parse(readFileSync(corpusPath, 'utf8'));
const cases = [];
for (const entry of corpus.cases) {
  const record = { id: entry.id, kind: entry.kind, expectRejected: entry.expectRejected === true };
  if (entry.kind === 'locator') {
    const parsed = Locator.deserialize(entry.input);
    if (parsed === undefined) {
      record.rejected = true;
      if (!record.expectRejected) {
        throw new Error(`official toolkit rejected corpus case ${entry.id} declared acceptable`);
      }
    } else {
      record.rejected = false;
      record.output = parsed.serialize();
      const round = Locator.deserialize(record.output);
      if (round === undefined) throw new Error(`toolkit cannot re-read its own output for ${entry.id}`);
      record.roundtrip = round.serialize();
    }
  } else if (entry.kind === 'positionList') {
    // The service shape {total, positions} is the positions-spec contract.
    // The official LocatorCollection model does not read this shape, so the
    // reference checks each entry through the official Locator model and
    // records the service-level fields verbatim.
    if (typeof entry.input.total !== 'number' || !Array.isArray(entry.input.positions)) {
      throw new Error(`position list case ${entry.id} lost its service shape`);
    }
    record.total = entry.input.total;
    record.entries = entry.input.positions.map((position, index) => {
      const parsed = Locator.deserialize(position);
      if (parsed === undefined) {
        throw new Error(`official toolkit refused position entry ${index} of ${entry.id}`);
      }
      return parsed.serialize();
    });
  } else {
    throw new Error(`unknown corpus case kind: ${entry.kind}`);
  }
  cases.push(record);
}

const reference = {
  schemaVersion: 1,
  producer: `@readium/shared ${sharedPkg.version}`,
  producerVersion: sharedPkg.version,
  nodeVersion: process.version,
  corpusPath,
  corpusSha256: sha256(corpusPath),
  sources: {
    locatorSchemaRawSha256: corpus.sources.locatorSchema.rawSha256,
    locatorSchemaDerivedSha256: corpus.sources.locatorSchema.derivedSha256,
    positionsSpecSha256: corpus.sources.positionsSpec.sha256,
    locatorSpecSha256: corpus.sources.locatorSpec.sha256,
  },
  cases,
};
const outPath = join(evidenceDir, 'reference.json');
writeFileSync(outPath, `${JSON.stringify(reference, null, 2)}\n`);
console.log(`readium reference: ${sharedPkg.version} on ${process.version}, ${cases.length} cases -> ${outPath}`);
