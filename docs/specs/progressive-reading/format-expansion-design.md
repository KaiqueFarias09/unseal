# Desenho congelado — expansão de sessões progressivas para PDF e CBR

Data: 2026-09-28. Status: **congelado antes da implementação** (mesmo ritual da
campanha EPUB/CBZ de 2026-09-26). Este documento é o contrato de coordenação
para os agentes de implementação. Mudanças de contrato precisam passar por aqui
primeiro.

## 1. Objetivo e critérios de sucesso

Expandir `BookSession` (hoje EPUB + CBZ) para **PDF** e **CBR**, mantendo o
ritual congelado da campanha anterior (design.md §6):

- **≥25% menos pico de memória OU ≥20% menos tempo até a primeira página**
  em ≥2 livros grandes, sem regressão funcional e sem piora material (>10%)
  na outra métrica; livros pequenos não podem piorar >10%.
- Casos que **pioraram** são medidos e reportados (o objetivo explicitamente
  os exige; não escondê-los).
- Métricas: tempo até página visível, p50/p95, **série e pico de RSS**,
  A/B alternado no mesmo Mac. Emuladores/simuladores validam **comportamento**,
  nunca ganho em celular físico.
- Corpus licenciado (biblioteca Calibre privada, 8 PDFs, 1,7–244 MB) medido
  **antes** da implementação. CBR não existe na biblioteca: fixtures
  determinísticos gerados (mesma postura do corpus público).

## 2. Estado atual (levantado em 2026-09-28)

- `SessionEngine` (lib/src/features/progressive/session_engine.dart) é
  zip-centrado: `ZipRandomAccess _source` + LRU por bytes
  (`SessionPolicy.cacheBytes`). Formatos não-zip são rejeitados com
  `SessionUnsupportedFormatException`.
- `BookSession` (lib/src/features/progressive/book_session.dart) delega a um
  `SessionTransport` (isolate no VM, worker no web, inline como fallback).
  Ops: resource(s)/text/source/search/progression/statistics/cfiResolve/
  cfiBuild + cancelPending/dispose.
- Header EPUB: `buildEpubSessionHeader`; header CBZ:
  `buildComicSessionHeader(ZipRandomAccess)` — páginas como placeholders de
  0 byte, capa materializada com teto `coverMaxBytes`, `ComicInfo.xml` lido.
- PDF eager (`parsePdfBook`): `PdfDocument.parse` (só xref; objetos lazily),
  `PdfPageTree.parse`, `PdfMetadataReader`, `PdfOutlineReader`, e um passe
  global `_extractPageContent` (texto de TODAS as páginas + até 128 imagens
  dedupadas globalmente) + `PdfReflow.apply` global.
- `PdfReflow.apply` é **global**: `_HeaderFooterScanner` amostra as primeiras
  `_pageScanCount = 20` páginas para decidir pular cabeçalho/rodapé; o texto
  canônico de cada página depende desse plano. Qualquer extração preguiçosa
  por página precisa do **mesmo plano** para manter paridade.
- `PdfBook.readingOrder` = um item por página (`page_<i+1>.html`); seção i é
  página i; `PdfBook.bytes` (obrigatório) carrega o documento inteiro para o
  modo fac-símile.
- CBR eager: `_readRarEntries` (parse_comic_book.dart) varre cabeçalhos RAR4
  (assinatura `Rar!\x1a\x07\x00`) e RAR5 (`...\x07\x01\x00`)
  sequencialmente e decodifica toda entrada na hora. Suporte: stored +
  method-29 v29 não-sólido (RAR4); apenas stored (RAR5). Entradas com
  compressão não suportada voltam com dados vazios + flag `isCompressed`.
- Wire web: `session_header_wire.dart` não conhece `PdfBook`; comics já
  viajam como placeholders (formato no metadata).
- Grimoire já é session-generic (`ViewerController.session`, `BookServer`
  com resolver). Lacunas: `/__pdfdoc__` serve `pdf.bytes` direto;
  `goToPdfPage` é limitado a `book is PdfBook`; camada de texto do fac-símile
  lê `pdf.pageTexts[i]` sincronamente.

## 3. Contratos novos (congelados)

### 3.1 Fundação: `ArchiveRandomAccess`

Novo arquivo `lib/src/foundation/archive/archive_random_access.dart`:

```dart
abstract interface class ArchiveEntry {
  String get name;      // caminho no container
  bool get isFile;
  int get uncompressedSize;
}

abstract interface class ArchiveRandomAccess implements AutoCloseable-like {
  List<ArchiveEntry> get entries;            // diretórios incluídos
  ArchiveEntry? find(String path);           // exato → normalizado → case-insensitive
  Uint8List inflate(ArchiveEntry entry, {int? maxBytes});
  Uint8List head(ArchiveEntry entry, int byteCount); // prefixo p/ sniff
  void close();
}
```

- `ZipRandomAccess`/`ZipEntryRecord` passam a implementar essas interfaces
  (cláusula `implements`; campos públicos intactos — tipo interno, sem quebra
  de API publicada).
- `SessionEngine._source` vira `ArchiveRandomAccess`. `resourceLength` lê
  `ArchiveEntry.uncompressedSize`.
- `buildComicSessionHeader(ArchiveRandomAccess source, {required BookFormat
  format, policy})` — corpo quase intacto; zip → `BookFormat.cbz`, rar →
  `BookFormat.cbr`.

### 3.2 CBR: `RarRandomAccess`

Novo arquivo `lib/src/features/comic/archive/rar_random_access.dart`:

- `RarRandomAccess implements ArchiveRandomAccess` sobre um `ZipByteSource`
  (memória ou arquivo — reusa `MemoryZipByteSource`/`FileZipByteSource`).
- Abertura: uma varredura de cabeçalhos (mesma gramática do leitor eager:
  RAR4 a partir do offset 7, RAR5 a partir do 8), construindo registros
  `{name, isFile, dataStart, packedSize, unpackedSize, method, version,
  flags, crc32}` **sem decodificar dados** (skip por `packedSize`).
- Matriz de suporte idêntica ao eager: RAR4 stored (0x30) e method-29 v29
  não-sólido via `_decodeRar4Method29` (o decodificador existente é
  promovido/reusado — sem duplicar lógica); RAR5 apenas stored. Entradas
  comprimidas sem suporte ficam indexadas; `inflate` lança `ComicException`
  tipada nomeando a entrada.
- Guardas espelhando zip (`archive_access.dart`): rejeitar no OPEN quando
  soma declarada > `maxZipTotalUncompressedBytes` (1 GiB), maior entrada >
  `maxZipEntryUncompressedBytes` (512 MiB), ou razão > `maxZipExpansionRatio`
  (200×, só acima de 32 MiB). Saída de `inflate` limitada por
  `BoundedOutputStream` como o zip.
- CRC: o eager RAR **não** verifica CRC. A sessão verifica quando
  `crc32 != 0` (rejeição tipada a dados corrompidos); delta documentado —
  entradas com CRC 0 nunca rejeitam.
- Comportamento de book inteiro: se o eager `parseComicBook` falha tipada
  para um CBR (ex.: entrada de página não decodificável mata o parse —
  verificar no código e espelhar), a sessão falha no OPEN com o mesmo tipo.
  A paridade é decidida por teste, não por suposição.

### 3.3 PDF: `PdfByteSource` + documento sem bytes residentes

- `lib/src/features/pdf/reader/pdf_byte_source.dart`:
  `abstract interface class PdfByteSource { int get length; Uint8List
  read(int offset, int count); void close(); }` + `MemoryPdfByteSource`
  (views, zero cópia). Implementação de arquivo em
  `lib/src/platform/io/pdf_byte_source_io.dart` (`FilePdfByteSource`),
  importada condicionalmente (padrão `zip_byte_source_io.dart`) — `lib/`
  continua sem depender de Flutter e sem io fora da plataforma.
- Refactor mecânico: `PdfObjectParser(bytes)` → `PdfObjectParser(PdfByteSource)`;
  `PdfDocument.bytes` → `PdfDocument.source`; todo consumidor de
  `document.bytes` no feature pdf se adapta. Parser ganha janelas de leitura
  (sem leitura byte-a-byte no arquivo); parse de memória mantém views.
  **Invariante**: parse eager de memória com saída idêntica (testes de
  paridade PDF existentes continuam verdes sem mudanças).
- `PdfReflow` ganha plano explícito mantendo `apply` intacto como fachada:
  `PdfReflowPlan.scan(pageTexts, pages)` (amostra ≤ 20 páginas) e
  `PdfReflow.applyWithPlan(pageTexts, pages, plan)`; saída byte-idêntica à
  de hoje para o eager (paridade por teste com fixture atual).

### 3.4 Header da sessão PDF

Novo `lib/src/features/progressive/pdf_session_header.dart`:
`buildPdfSessionHeader(PdfByteSource source, {password, policy})` →

- `PdfDocument.parse(source, password:)` + `PdfPageTree.parse` +
  `PdfMetadataReader.read` + `PdfOutlineReader.read` (estrutura completa).
- Amostra de reflow: extrai texto das primeiras ≤20 páginas e calcula o
  plano (skip de cabeçalho/rodapé) — custo limitado na abertura.
- Header: `PdfBook(bytes: Uint8List(0), pages, navigation, metadata,
  pageTexts: [], pageFiles: [])` — estrutura completa, conteúdo vazio.

**Deltas documentados vs eager** (mesma seção de deltas do EPUB no
design.md):

1. `bytes` vazio no header; fac-símile via `loadBytesRange`.
2. `pageTexts`/`files.html` vazios; páginas materializam sob demanda.
3. `hasTextLayer` é `false` no header ( consumers session-aware no Grimoire).
4. Imagens: coletadas como efeito da materialização da página dona, com
   dedup global e teto de 128 reproduzidos por estado residente do engine
   (paridade com `_extractPageContent`).

### 3.5 Engine: ramo PDF

`SessionEngine` ganha `PdfSessionContent? _pdf` (nulo nos ramos zip/rar):

- Espaço de paths do PDF = os mesmos do eager: `page_<i>.html` (reflow,
  1-based), texto canônico via `documentText('page_<i>.html')`,
  imagens `images/pdf-image-<obj>.<ext>`.
- `textFile(path)`: extrai a página (PdfTextExtractor) + reflow com o plano
  → `TextFile(content: htmlReflow, name: 'page_<i>.html', type: 'html',
  path: ...)`, cache LRU (peso = 2 × code units, como texto EPUB).
  `documentText` = canônico pós-plano (idêntico ao eager, mesma invariante
  do PdfReflow).
- `resource('images/...')`: decodifica a imagem sob demanda via página dona
  (mapa residente obj→página); respeita o teto global de 128.
- `search`/`computeProgression`/`computeStatistics`: **sem mudança de código**
  — os loops atuais percorrem `book.readingOrder` e chamam
  `documentText(section.name)`; páginas materializam uma a uma.
- CFI: `resolveCfi`/`buildCfi` continuam EPUB-only (PDF/CBR endereçam por
  `PageLocator(pageIndex)`/offset de seção; contrato Grimoire inalterado).
- Novo: `bytesRange(offset, count)` — fatia bruta do `PdfByteSource`,
  limitada por `SessionPolicy.rangeMaxBytes` (novo campo, default 8 MiB,
  clamp ≥ 64 KiB). `byteLength` = `source.length` (exposto no header).
- Novo: `loadPdfPageLines(int pageIndex) → Future<PdfPageText?>` — devolve o
  `PdfPageText` extraído da página **com geometria de linhas** (`PdfTextLine`
  com x/y/width/height/fontSize), insumo da camada de texto do fac-símile do
  Grimoire (`syntheticPdfPageHtml`). O materialização da página no engine é
  única: extrair (`PdfTextExtractor`) + reflow com o plano + canônico,
  cacheando `PdfPageText` e `TextFile` juntos numa entrada do LRU (peso =
  soma). O transporte io envia o objeto direto (isolate-safe); o wire web
  ganha codec de linhas (JSON por página, limitado à página pedida).
  Motivação: `loadDocumentText` dá só o texto canônico, sem geometria —
  sem isto o fac-símile em sessão perdiria seleção/destaque (decisão
  registrada em 2026-09-28 após o mapa do Grimoire).
- Cancelamento: mesma mecânica do EPUB (`cancelPending` derruba ops em
  voo no transporte; `dispose` fecha). Ops por página são limitadas;
  varreduras inteiras (search/progression) pagam o custo por página sob
  demanda — sem novo mecanismo, paridade com EPUB documentada.

### 3.6 Gate de detecção e abertura

- `SessionEngine.openBytes/openSource`: admitir `DetectedFormat.epub`
  (caminho zip: EPUB ou CBZ por inventário), `DetectedFormat.pdf` (ramo PDF)
  e `DetectedFormat.comic` quando a assinatura é RAR (ramo `RarRandomAccess`;
  o despacho zip→CBZ por inventário fica como está).
- `openFile` (VM): PDF → `FilePdfByteSource(path)`; RAR →
  `FileZipByteSource(path)` + `RarRandomAccess`. Nenhum dos lados mantém o
  arquivo comprimido inteiro em memória.
- Erros tipados: `PdfException`/`PdfEncryptedException`/`ComicException`
  atravessam o transporte e são reconstruídos tipados (estender
  `rebuildSessionError`). Senha errada em PDF → `PdfEncryptedException` na
  abertura, igual ao eager.

### 3.7 API pública `BookSession` (adições mínimas)

```dart
int get byteLength;                                  // tamanho do fonte bruto
Future<Uint8List?> loadBytesRange(int offset, int count); // fatia do fonte
```

- `byteLength` é sincrono e vem do header (comics: tamanho do arquivo;
  zip: idem; PDF: `source.length`; EPUB/CBZ: tamanho do container — útil
  pro Grimoire hoje via `resourceLength`).
- `loadBytesRange`: `RangeError` tipado para offset/count inválidos; devolve
  ≤ count bytes no fim do arquivo. Ops novas no transporte (`range`) e no
  worker (`workerOpSessionRange`, blobs).
- `isProgressive` continua sempre true; README/design atualizados: formatos
  suportados = EPUB, CBZ, **CBR**, **PDF**.

### 3.8 Wire (web)

- `session_header_wire.dart`: ramo `PdfBook` (pages: width/height/rotação/
  label na ordem; navigation + metadata reusando codecs existentes;
  pageTexts/files omitidos; sem bytes). Comic: garantir `BookFormat.cbr`
  íntegro no roundtrip.
- `worker_ops.dart`: `_sessionOpen` já chama `SessionEngine.openBytes` —
  passa a funcionar p/ pdf/rar; nova op `workerOpSessionRange`.
- `session_transport_web.dart`: `_WorkerSessionTransport.range`.
- Testes Chrome: abrir sessão PDF e CBR no worker, loadResource/text,
  search, range, dispose — mais isolamento de sessões simultâneas.

## 4. Grimoire (contrato do adendo §8 estendido)

Mapa de mudanças verificado por leitura profunda em 2026-09-28 (arquivos e
linhas no relatório da sessão; resumo do contrato):

1. `/__pdfdoc__` (BookServer io + web): com sessão anexada e `book is
   PdfBook`, servir o documento via `session.loadBytesRange` respeitando
   `Range` (total via `session.byteLength`). Io: `_servePdfDocument` vira
   async mapeando cada range pedido a uma chamada; web: blob montado por
   fatias na primeira página de fac-símile (o worker já segura os bytes;
   memória no main thread ≈ eager — documentado).
2. Camada de texto do fac-símile: hidratar por página via
   `session.loadPdfPageLines(i)` (geometria preservada; sem degradação).
   A leitura síncrona de `pdf.pageTexts[i]` permanece só para o caminho
   eager.
3. Seleção de modo PDF session-aware: em `start()`, com sessão anexada,
   sondar `session.loadDocumentText('page_1.html')` (bounded) para decidir
   reflow × fac-símile no lugar de `hasTextLayer` (header tem pageTexts
   vazio). Nota: o exemplo força fac-símile na abertura
   (reader_controller.dart ~228) — ajustar para respeitar a decisão.
4. `goToPdfPage`/`positionPageLocator` → generalize para qualquer livro
   paginado (`PdfBook` e `ComicBook`; seção i = página i; header comic já
   traz `pages` completo).
5. Imagens embutidas `images/pdf-image-<n>.<ext>`: **verificado** — o reflow
   HTML as referencia (`pdf_reflow.dart` renderiza `<div class="elv-pdf-image">
   <img src="images/...">`), logo o BookServer em modo resolver precisa passar
   caminhos desconhecidos ao resolver com 404 só em null (io `_lookup` +
   web `urlForPathAsync`/`_withResolvedResources`). No unseal,
   `session.loadResource('images/pdf-image-<n>.<ext>')` decodifica sob
   demanda pelo número de objeto embutido no nome (sem página dona
   materializada); delta de paridade: sem o teto global de 128 do eager
   (o header nunca lista imagens; serving é por demanda).
6. Exemplo: fixtures grandes gerados localmente (gitignored:
   `/assets/books/large-pdf.pdf`, `/assets/books/large-cbr.cbr`);
   `_renderPdfCovers` faz full-parse para capa — tornar session-aware ou
   não cachear `entry.book` para PDF, senão a abertura por sessão é
   mascarada na prateleira.
7. Testes: estender `book_server_session_test` (PDF com ranges via
   `loadBytesRange`), `viewer_controller_session_test` (PDF: sonda de modo,
   reflow `/book/page_1.html`, fac-símile `/__pdfpage__/0`, paridade de
   busca; CBR: salto de página, páginas via resolver) e um twin de
   `real_pdf_integration_test` na sessão.

## 5. Instrumentação de medida (congelada)

- `tool/progressive_bench.dart`: manter modos; garantir que funcionem para
  pdf/cbr (readFile genérico); `session-first-content` para PDF = header +
  primeira página (`loadDocumentSource('page_1.html')`); para CBR = header +
  primeira página (`loadResource(página 1)`).
- `tool/progressive_bench_sweep.dart`: adicionar **série de RSS** — amostrar
  o RSS do processo filho a cada ~10 ms (`ps -o rss= -p pid`) e registrar
  `rss_series_mb` + `rss_peak_mb` por run; p50/p95 por (livro, modo).
  (implementado 2026-09-28: a amostragem roda num isolate dedicado DENTRO do
  probe — `parse-sync` bloqueia o event loop principal, e um timer ali só veria
  os dois extremos; o sweep, que já isola um processo filho por medida, herda a
  série via JSON do filho e agrega `rss_peak_mb`/`t_first_content_ms` com
  min/median/p90/p95/max. `t_first_content_ms` nos modos eager = primeiro acesso
  ao conteúdo já residente, por tipo de livro (~0: o custo mora no `t_open_ms`);
  modos de sessão sobre pdf/cbr emitem `status: "unsupported"` tipado até as
  ondas B/C.)
- Ordem de modos **alternada por repetição** (já existe); campanha no mesmo
  Mac, seriada; repetições ≥ 5.
- Corpus licenciado: os 8 PDFs da biblioteca Calibre (ids = sha256 do path,
  12 hex; caminhos nunca saem do artefato local). CBR: fixtures gerados
  (stored + method-29 pequeno real se disponível) + `sample.cbz` +
  `dickens-sample.pdf` como casos pequenos de regressão.

## 6. Matriz de testes (congelada)

Unseal VM:

- Paridade header/por-página PDF sessão × eager (texto canônico, busca,
  progressão, estatísticas, ordem de leitura, outline) em ≥2 fixtures.
- Paridade CBR sessão × eager (inventário, capa, bytes por página, ordem
  natural, ComicInfo).
- LRU: `cacheBytes` mínimo evita PDF/CBR acima do orçamento; `rangeMaxBytes`
  limita fatias; `coverMaxBytes` no CBR.
- Cancelamento: `cancelPending` sob ops em voo; `dispose` →
  `SessionClosedException`; sessões simultâneas (2× PDF + 1× CBR) isoladas.
- Adversários: RAR truncado, cabeçalho malformado (loops), bomba RAR
  (unpSize declarado gigante), entrada sólida/criptografada/RAR5 comprimida
  → tipado; PDF xref quebrado (recuperação), stream bomba, senha errada;
  fuzz seeds CBR/PDF no harness existente.
- Formatos ainda não suportados continuam tipados (teste `.txt` etc.).

Chrome: wire roundtrip PDF/CBR, worker session, ranges, isolamento.

Grimoire: citados em §4.5.

## 7. Ordem de execução

1. **Onda A** (paralela): A1 instrumenta o bench (§5); A2 implementa a
   fundação + CBR (§3.1, §3.2, §3.4 zip→rar, §3.5 gate RAR, §3.6, §3.7
   byteLength/range no transporte io, testes VM de CBR).
2. **Onda B** (após A2, mesma pessoa ou agente novo): PDF (§3.3, §3.4, §3.5,
   wire de PDF entra na onda C).
3. **Onda C**: wire/worker web p/ PDF+CBR + testes Chrome.
4. **Onda D** (paralela a C, após A2): Grimoire (§4) — compila contra a
   API de A2 (byteLength/loadBytesRange já existem p/ CBR).
5. **Onda E**: fuzz/adversários completos + varredura de testes.
6. **Onda F**: baseline já medido na onda A; campanha A/B alternada +
   relatório + decisão MOBI/AZW3/CHM + docs (README, adendo) + memória.

## 8. Higiene

- Commits atômicos Conventional+gitmoji, paths explícitos, worktree limpo.
- Nada de push/publicação/tag. Trabalho existente intocado (irmãos limpos
  verificados: grimoire @a56674b, grimoire_narration @e62323e8→e623be8).
- Fixture binário é dado-fonte: não reescrever para teste passar; mudança de
  fixture atualiza manifesto/proveniência no mesmo commit.
