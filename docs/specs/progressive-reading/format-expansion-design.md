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
  de API publicada). (implementado: parâmetros de payload viram
  `covariant final` para conformar com a interface sem alargar assinaturas;
  o nome `ArchiveEntry` colide com a entidade de inventário já existente em
  `foundation/entities` — o `comic_session_header` esconde-a localmente.)
- `SessionEngine._source` vira `ArchiveRandomAccess`. `resourceLength` lê
  `ArchiveEntry.uncompressedSize`. (implementado: o engine também retém o
  `ZipByteSource` bruto para `bytesRange`.)
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
  `BoundedOutputStream` como o zip. (implementado: no method-29 o teto é o
  próprio alvo declarado do decodificador, que recusa matches além dele.)
- CRC: o eager RAR **não** verifica CRC. A sessão verifica quando
  `crc32 != 0` (rejeição tipada a dados corrompidos); delta documentado —
  entradas com CRC 0 nunca rejeitam. (implementado: verificação em stored
  RAR4/RAR5 e method-29; o fixture real method-29 abre com CRCs
  declarados.)
- Comportamento de book inteiro: se o eager `parseComicBook` falha tipada
  para um CBR (ex.: entrada de página não decodificável mata o parse —
  verificar no código e espelhar), a sessão falha no OPEN com o mesmo tipo.
  A paridade é decidida por teste, não por suposição. (implementado e
  pinado por teste: o eager lança `ComicException` para QUALQUER entrada
  comprimida indecodificável — solid/split/senha, métodos fora de
  0x31–0x35, versão ≠ 29, RAR5 comprimido, decode falho — logo a sessão
  falha no OPEN nomeando a entrada; "indexadas" vale no nível
  `RarRandomAccess`, mas o build do header toca toda entrada ao sniffar e
  a falha tipada surfaced no OPEN. Entradas stored truncadas/mismatched o
  eager descarta em silêncio — a sessão idem, via `head()` vazio. Nota de
  custo: `head()` de method-29 decodifica o payload inteiro para sniffar —
  mesmo custo do eager, uma vez, na abertura.)

### 3.3 PDF: `PdfByteSource` + documento sem bytes residentes

- `lib/src/features/pdf/reader/pdf_byte_source.dart`:
  `abstract interface class PdfByteSource { int get length; Uint8List
  read(int offset, int count); void close(); }` + `MemoryPdfByteSource`
  (views, zero cópia). Implementação de arquivo em
  `lib/src/platform/io/pdf_byte_source_io.dart` (`FilePdfByteSource`),
  importada condicionalmente (padrão `zip_byte_source_io.dart`) — `lib/`
  continua sem depender de Flutter e sem io fora da plataforma.
  (implementado: interface e `MemoryPdfByteSource` espelham
  `MemoryZipByteSource` — inclusive o fast path `read(0, length)` que
  devolve a lista original; `FilePdfByteSource` segue o padrão
  `FileZipByteSource` (seek+read, `close` idempotente) como arquivo NOVO
  em `platform/io/` — ainda sem fachada de import condicional, pois nada
  fora de `platform/io` a consome nesta onda; a onda de engine (§3.6)
  liga `openFile`.)
- Refactor mecânico: `PdfObjectParser(bytes)` → `PdfObjectParser(PdfByteSource)`;
  `PdfDocument.bytes` → `PdfDocument.source`; todo consumidor de
  `document.bytes` no feature pdf se adapta. Parser ganha janelas de
  leitura (sem leitura byte-a-byte no arquivo); parse de memória mantém
  views. **Invariante**: parse eager de memória com saída idêntica (testes
  de paridade PDF existentes continuam verdes sem mudanças).
  (implementado: janela deslizante de 64 KiB no parser; fast path de
  memória = UMA view do arquivo inteiro na construção — zero refills,
  indexação direta, comportamento idêntico ao antigo; corpos de stream =
  um `source.read` limitado (view na memória, uma fatia no arquivo);
  `_scanObjects`/`_scanHeader`/`_scanForTrailer` viraram varreduras
  sequenciais pela janela; `_startXrefOffset` lê só a cauda ≤ 2048 bytes e
  `_pdfHeaderOffset` só o preâmbulo ≤ 1028; `PdfDocument` ganhou
  `int get byteLength => source.length`. Desvio de superfície: a troca de
  assinatura de `PdfDocument.parse` é breaking para quem importa `src/` —
  call sites dos testes adaptados (wrapper `MemoryPdfByteSource`,
  asserções intactas) e `tool/pdf_parity.dart:1233` fica devendo UMA linha
  do mesmo wrap (`tool/` era no-touch nesta onda); `parsePdfBook`/
  `readPdfMetadata` mantêm assinatura pública `Uint8List` — zero quebra
  na API publicada. Paridade memória×arquivo pinada por teste (dickens +
  pg11: cada objeto 1..Size, page tree, metadata, outline).)
- `PdfReflow` ganha plano explícito mantendo `apply` intacto como fachada:
  `PdfReflowPlan.scan(pageTexts, pages)` (amostra ≤ 20 páginas) e
  `PdfReflow.applyWithPlan(pageTexts, pages, plan)`; saída byte-idêntica à
  de hoje para o eager (paridade por teste com fixture atual).
  (implementado, com desvio de contrato consciente: o plano carrega TUDO
  que `_Document` precomputa globalmente — skip de cabeçalho/rodapé,
  `dominantFontSize` (voto sobre TODAS as linhas), as estatísticas de
  documento (`PdfReflowStats`: top, bottom, right, lineSpace, paraSpace,
  margens/indentações odd/even — estas mudam o texto canônico via
  coalescing) e as flags de continuação entre páginas — porque
  `render`/`canonicalText` da página i depende de tudo isso, não só dos
  skips. `applyWithPlan` ganhou `{firstPageNumber}`: paridade odd/even,
  âncoras `page_N` e flags de continuação são indexadas pelo número
  absoluto da página. `apply` segue um único passe (sem custo duplo no
  eager); a equivalência `scan` + `applyWithPlan` por página e por fatia
  é pinada byte-a-byte por teste. Consequência precisa para a onda de
  engine: o corte de cabeçalho/rodapé É amostrável em ≤ 20 páginas
  (pinado: plano da amostra == plano completo nos skips), mas o plano
  COMPLETO não é computável de uma amostra — `dominantFontSize`,
  estatísticas e continuações exigem o texto de todas as páginas. Um
  plano de amostra ≤ 20 só é byte-idêntico ao eager para documentos com
  ≤ 20 páginas (ou coincidência). Para valer "canônico idêntico ao eager"
  (§3.5) em livros maiores, a sessão precisa calcular o plano sobre o
  conjunto completo de textos (ex.: preguiçoso no primeiro uso após todas
  as páginas materializarem) ou aceitar delta documentado no canônico.)

### 3.4 Header da sessão PDF

Novo `lib/src/features/progressive/pdf_session_header.dart`:
`buildPdfSessionHeader(PdfByteSource source, {password, policy})` →

- `PdfDocument.parse(source, password:)` + `PdfPageTree.parse` +
  `PdfMetadataReader.read` + `PdfOutlineReader.read` (estrutura completa).
- Amostra de reflow: extrai texto das primeiras ≤20 páginas e calcula o
  plano (skip de cabeçalho/rodapé) — custo limitado na abertura.
- Header: `PdfBook(bytes: Uint8List(0), pages, navigation, metadata,
  pageTexts: [], pageFiles: [])` — estrutura completa, conteúdo vazio.

**Decisão congelada (2026-09-28, pós-onda B1)** — o plano completo do
`PdfReflow` carrega estatísticas globais (fonte dominante, histogramas de
margem/indentação, flags de continuação entre páginas) que uma amostra de
20 páginas não reproduz para livros maiores (ver §3.3, nota implementado).
Postura da sessão:

1. Skips de cabeçalho/rodapé: do plano amostrado — **idênticos ao eager**
   (o scanner eager também só amostra as primeiras 20 páginas; pinado por
   teste em `pdf_reflow_plan_test.dart`).
2. Flags de continuação: computadas **sob demanda**, materializando a
   página i com a geometria da página i−1 (extração extra sob demanda,
   cacheada) — exata quando a página anterior existe.
3. Fonte dominante + estatísticas de documento: do plano amostrado →
   **delta documentado** para livros >20 páginas (o texto canônico pode
   diferir do eager em detalhes de coalescência/espaçamento). Para livros
   ≤20 páginas, sessão e eager são byte-idênticos (o plano amostral É o
   plano completo).
4. A invariante **intra-sessão** é a que vincula: o texto visível do reflow
   HTML materializado == `documentText` da página == os textos das linhas
   de `loadPdfPageLines` — busca, seleção e destaques compartilham o mesmo
   espaço de offsets dentro da sessão. Paridade com eager vira
   **equivalência** (mesmas consultas casam; contagens iguais para
   consultas robustas), não byte-paridade, e os testes da seção §6 são
   escritos nessa chave.

**Deltas documentados vs eager** (mesma seção de deltas do EPUB no
design.md):

1. `bytes` vazio no header; fac-símile via `loadBytesRange`.
2. `pageTexts`/`files.html` vazios; páginas materializam sob demanda.
3. `hasTextLayer` é `false` no header ( consumers session-aware no Grimoire).
4. Imagens: coletadas como efeito da materialização da página dona, com
   dedup global e teto de 128 reproduzidos por estado residente do engine
   (paridade com `_extractPageContent`).

(implementado, onda B: o delta 2 ganhou uma exceção consciente — o header
carrega `pageFiles` como PLACEHOLDERS de conteúdo vazio, um `TextFile` por
página chamado `page_<i>.html`, porque `PdfBook.readingOrder` se constrói de
`files.html`: sem os placeholders, search/progression/statistics e a
navegação CFI-free não vêem as páginas. `pageTexts` segue vazio e
`hasTextLayer` segue `false`; consumidores leem conteúdo só pelos ops. O
delta 4 mudou de posto: NÃO há teto de 128 nem mapa obj→página residente —
`resource('images/pdf-image-<n>.<ext>')` decodifica por número de objeto
direto do documento (§4.5 manda), via `decodePdfImageObject`
(`pdf_content_stream.dart`), o mesmo caminho de decodificação que o
`onImage` do extractor usa. A invariante intra-sessão §3.4.4 está pinada
por teste: `documentText('page_<i>.html')` == o texto canônico do eager
(≤20 páginas, byte a byte) == as linhas de `loadPdfPageLines` unidas por
`\n` — o HTML do reflow é construído para que o scanner canônico o
reproduza. As flags de continuação sob demanda usam um
`PdfReflow.applyWithPlan(computeContinuations: true)` renderizando o PAR
[página i−1, página i] sob o plano amostrado: a decisão é a mesma passada
do pipeline completo (todos os insumos são do par, exceto as estatísticas
do plano), e o canônico da página i−1 já materializada serve de insumo do
par sem quebrar a byte-paridade — pinado materializando as páginas em
ordem reversa. O peso LRU da entrada de página = 2 × code units do texto +
64 bytes por linha canônica; entradas só-extração pesam linhas × 64.)

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

  (implementado, onda B, com três notas de superfície: `resourceLength`
  devolve null para TODO path pdf — páginas não materializam só para um
  tamanho e imagens só têm tamanho conhecido pós-decodificação (o serving
  de páginas é HTML reescrito sem byte-ranges); `loadPdfPageLines` é
  RangeError tipado fora da faixa (sessões não-pdf: `pageCount` 0 → sempre
  RangeError) e devolve o canônico PÓS-plano — o §3.4.4 obriga; o wire das
  linhas carrega linhas (x/y/width/height/fontSize/text/rotated), image
  placements e contadores de stream, mais pageWidth/pageHeight da
  `PdfPage` — as placements viajam junto porque o reader precisa serví-las.)

### 3.6 Gate de detecção e abertura

- `SessionEngine.openBytes/openSource`: admitir `DetectedFormat.epub`
  (caminho zip: EPUB ou CBZ por inventário), `DetectedFormat.pdf` (ramo PDF)
  e `DetectedFormat.comic` quando a assinatura é RAR (ramo `RarRandomAccess`;
  o despacho zip→CBZ por inventário fica como está). (implementado, onda A2:
  os ramos epub e comic. Nota: bytes imprimíveis
  não-RAR detectam como txt e o gate recusa com
  `SessionUnsupportedFormatException` — o leitor RAR só vê o que a
  detecção marca como comic. implementado, onda B: o ramo PDF —
  `openBytes` constrói `MemoryPdfByteSource` sobre os bytes;
  `openSource` constrói um `PdfByteSource` VISÃO sobre o `ZipByteSource`
  existente (ver abaixo) e ambos despacham para `buildPdfSessionHeader`,
  cuja falha tipada (`PdfException`/`PdfEncryptedException`) encerra a
  abertura. Parâmetro `password` nomeado e aditivo em
  `openBytes`/`openSource`, encaminhado pelo transporte io
  (`openSessionTransport`/bootstrap do isolate) e pelo worker
  (`wireKeyPassword` no payload do `sessionOpen`) — necessário para que a
  senha certa abra de fato, não só a errada falhe tipada.)
- `openFile` (VM): PDF → `FilePdfByteSource(path)`; RAR →
  `FileZipByteSource(path)` + `RarRandomAccess`. Nenhum dos lados mantém o
  arquivo comprimido inteiro em memória. (implementado, onda B, com desvio
  de superfície: o caminho por arquivo abre UM descritor só — o
  `PdfByteSource` do parser é uma view sobre o MESMO `ZipByteSource` que
  serve `bytesRange` (`_PdfSourceOverZip`), em vez de um segundo handle
  `FilePdfByteSource`; semântica idêntica (seek+read em janelas), um
  recurso a menos para fechar. `close` do engine fecha o
  `ZipByteSource` direto no ramo pdf.)
- Erros tipados: `PdfException`/`PdfEncryptedException`/`ComicException`
  atravessam o transporte e são reconstruídos tipados (estender
  `rebuildSessionError`). Senha errada em PDF → `PdfEncryptedException` na
  abertura, igual ao eager. (implementado, onda B: os dois tipos pdf no
  `rebuildSessionError` do isolate — mesmo degrade do wire web, campos
  `requiresNonEmptyPassword`/`permissions` não cruzam; pinado por teste no
  isolate e no worker op.)

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
  worker (`workerOpSessionRange`, blobs). (implementado, onda A2:
  `byteLength` cruza o handshake — 4º elemento da mensagem `ready` do
  isolate e chave `byteLength` no JSON do `sessionOpen` do worker;
  `rangeMaxBytes` cruza o payload do open; `ComicException` agora também
  reconstrói tipada no `rebuildSessionError` do isolate — o wire web já a
  conhecia.)
- `isProgressive` continua sempre true; README/design atualizados: formatos
  suportados = EPUB, CBZ, **CBR**, **PDF**. (implementado, onda B: a doc
  comment de `isProgressive` e do header do `BookSession` acompanha os
  quatro formatos; o README é contrato de produto da onda F de docs.)

### 3.8 Wire (web)

- `session_header_wire.dart`: ramo `PdfBook` (pages: width/height/rotação/
  label na ordem; navigation + metadata reusando codecs existentes;
  pageTexts/files omitidos; sem bytes). Comic: garantir `BookFormat.cbr`
  íntegro no roundtrip. (implementado, onda B: o ramo `PdfBook` já saiu —
  pages como objectNumber/width/height/rotate (a entidade não tem label),
  navigation + metadata pelos codecs existentes, placeholders de
  `page_<i>.html` reconstruídos na decodificação, sem bytes/pageTexts;
  `BookFormat.cbr` segue íntegro. Roundtrip VM pinado em
  `session_header_wire_test.dart`.)
- `worker_ops.dart`: `_sessionOpen` já chama `SessionEngine.openBytes` —
  passa a funcionar p/ pdf/rar; nova op `workerOpSessionRange`.
  (implementado, onda A2/B: range na A2; `workerOpSessionPdfLines` + senha
  no payload do `sessionOpen` na onda B, com decode no `WorkerClient` e
  op `pdfLines` no transporte do isolate. Os testes Chrome de sessão PDF
  ficam para a onda C — os codecs e o op já são cobertos VM-side.)
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
   memória no main thread ≈ eager — documentado). (implementado no
   Grimoire, 2026-09-28: `BookServer` (io + web) ganha `byteRangeLoader` +
   `pdfDocumentByteLength`; io — 1 chamada por Range, montagem chunked
   256 KiB sem Range, 416/Content-Range pelo total do handshake, caminho
   eager preservado sem loader; web — blob lazy por fatias de 1 MiB na
   primeira página de fac-símile, cacheado; `start()` liga o loader
   quando há sessão e `book is PdfBook`.)
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
   traz `pages` completo). (implementado no Grimoire, 2026-09-28: helper
   `_flatPageCount` cobre `PdfBook` e `ComicBook`; nomes públicos
   mantidos; livros sem páginas planas continuam ignorando o salto.)
5. Imagens embutidas `images/pdf-image-<n>.<ext>`: **verificado** — o reflow
   HTML as referencia (`pdf_reflow.dart` renderiza `<div class="elv-pdf-image">
   <img src="images/...">`), logo o BookServer em modo resolver precisa passar
   caminhos desconhecidos ao resolver com 404 só em null (io `_lookup` +
   web `urlForPathAsync`/`_withResolvedResources`). No unseal,
   `session.loadResource('images/pdf-image-<n>.<ext>')` decodifica sob
   demanda pelo número de objeto embutido no nome (sem página dona
   materializada); delta de paridade: sem o teto global de 128 do eager
   (o header nunca lista imagens; serving é por demanda).
   (implementado no Grimoire, 2026-09-28: io `_serveBookFile` e web
   `urlForPathAsync`/`_withResolvedResources`/`_preparedResolve` passam
   caminhos fora do inventário ao resolver exatamente como referenciados
   — sem fuzzy matching no pass-through; 404 só em null.)
6. Exemplo: fixtures grandes gerados localmente (gitignored:
   `/assets/books/large-pdf.pdf`, `/assets/books/large-cbr.cbr`);
   `_renderPdfCovers` faz full-parse para capa — tornar session-aware ou
   não cachear `entry.book` para PDF, senão a abertura por sessão é
   mascarada na prateleira. (implementado no Grimoire, 2026-09-28:
   fixtures locais gitignored `synthetic-400p.pdf`, `medium-cbr.cbr`,
   `large-cbr.cbr` + entradas de prateleira; `_renderPdfCovers` não
   cacheia mais `entry.book` — capa renderiza de um parse local, então
   o leitor pega o caminho de sessão; livros sem sessão continuam
   reaproveitando `entry.book` quando já presente.)
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
  ondas B/C. implementado na onda B: `session-first-content` resolve o
  primeiro conteúdo POR FORMATO — EPUB = primeiro HTML do spine + CSS; PDF =
  `loadDocumentSource('page_1.html')`; comics = `loadResource` da primeira
  página — e os modos de sessão abrem pdf/cbr com `status: "ok"`.)
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
