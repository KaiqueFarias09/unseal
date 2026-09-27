---
feature: Progressive reading sessions for large books
slug: progressive-session-design
version: 1.0
status: draft
created: 2026-09-26
upstream: ../ai-intensive-roadmap/baseline-2026-09-25.md
---

# Design: sessão de leitura progressiva (Unseal → Grimoire)

Arquitetura de abertura progressiva: a fonte comprimida e o livro
parseado ficam residentes num worker (isolate na VM, Web Worker na web);
o cliente recebe um **header pequeno** imediatamente e carrega
capítulos/recursos **sob demanda**, com cache LRU limitado. Este é o
desenho que a seção 6.2 do baseline apontou como viável depois de três
alternativas rejeitadas (leitura do arquivo no isolate, `TransferableTypedData`,
worker persistente devolvendo o `Book` inteiro por `SendPort.send`).

## Evidência que sustenta o desenho (probe 2026-09-26, mahabharata.epub
10,8 MB comprimido / 35,2 MB descomprimido / 2020 entradas)

| Operação | Tempo | Δ RSS |
| --- | ---: | ---: |
| `ZipDecoder.decodeBytes` lazy (sem inflar) | 12 ms | +0,6 MB |
| Inflar 1 entrada (447 KiB, CRC ok) | 5 ms | +0,8 MB |
| `decodeBookZip` completo (caminho atual) | 296 ms | +83 MB |

O pacote `archive` 4.3 decodifica lazy: `ArchiveFile.rawContent` mantém os
bytes comprimidos e `Inflate.stream` sobre `getStream(decompress: false)`
infla uma entrada com os mesmos guards de zip-bomb já usados por
`decodeBookZip`.

## Decisões de API (congeladas)

### 1. Contrato público novo — `BookSession`

```dart
// exportado por package:unseal/unseal.dart
final class BookSession {
  static Future<BookSession> open(Uint8List bytes, {String password = '', SessionPolicy policy});
  static Future<BookSession> openFile(String path, {String password = '', SessionPolicy policy});

  /// Estrutura completa, conteúdo vazio: metadata (com cover sujeita a
  /// SessionPolicy.coverMaxBytes), navigation, readingOrder, spine/manifest,
  /// archiveEntries. É um `EpubBook`/`ComicBook` real com `files` vazio, para
  /// FXL e inventários funcionarem sem mudança.
  Book get book;

  /// false quando o formato não tem acesso aleatório (CBR, MOBI…): o worker
  /// materializa tudo, o cliente ainda recebe só o header.
  bool get isProgressive;

  Future<Uint8List?> loadResource(String path);              // null = entrada inexistente
  Future<Map<String, Uint8List>> loadResources(Iterable<String> paths);
  Future<String?> loadDocumentText(String path);             // texto canônico de um documento
  Future<BookProgression> computeProgression();              // varre tudo no worker
  Future<SearchResults> search(String query, {/* parâmetros de BookSearch */});
  Future<EpubCfiLocation?> resolveCfi(String cfi);
  Future<String?> buildCfi({required int contentIndex, required int offsetInText});

  void cancelPending();  // ops em voo completam com SessionCancelledException
  void dispose();        // mata o worker; ops completam com SessionClosedException
}

final class SessionPolicy {
  final int cacheBytes;      // orçamento LRU no worker; default 64 MiB
  final int coverMaxBytes;   // cover entra no header só até este tamanho; default 8 MiB
  const SessionPolicy({this.cacheBytes = 64 << 20, this.coverMaxBytes = 8 << 20});
}
```

Regras:

- `Unseal.read/parse/readFile/readMetadata*` e `UnsealWorker` **não mudam**.
  A sessão é aditiva.
- Falhas tipadas: parse na abertura usa a hierarquia `UnsealException` atual;
  `dispose` → `SessionClosedException`; `cancelPending` →
  `SessionCancelledException`; recurso inexistente → `null` (não é estado de
  erro — livros reais referenciam recursos ausentes).
- Formatos na fatia 1: **EPUB** (progressivo) e **CBZ** (progressivo).
  Demais formatos abrem em modo *eager-in-worker* (mesmo contrato de
  cliente; memória fica no worker, que materializa como hoje).
- Formato sem worker disponível (fallback inline): a sessão abre igual, com
  o engine embutido no chamador — o contrato de cliente é idêntico.

### 2. Onde vive cada coisa

```
lib/src/foundation/archive/zip_source.dart    inventário lazy + inflar 1 entrada
                                              com CRC + guards por entrada
lib/src/features/progressive/
  book_session.dart                           fachada pública + policy + erros
  session_engine.dart                         engine puro: header, recursos, busca,
                                              CFI, progressão — sem plataforma
  epub_session_header.dart / comic_session_header.dart
lib/src/platform/io/session_worker.dart       isolate de longa duração (SendPort,
                                              mensagens pequenas)
lib/src/platform/web/session_worker.dart      ops novos no protocolo do worker
                                              existente (mesmos nomes de op)
web/unseal_worker.dart                        shell ganha os ops de sessão
```

O protocolo de mensagens reutiliza o formato do wire atual
(`{id, op, payload?}` → `{id, kind, json, blobs?}`) e os codecs existentes
(`metadata_wire`, `search_wire`, `cfi_wire`). Nenhuma mensagem carrega o
`Book` inteiro — o `Book` nunca atravessa a fronteira na sessão.

### 3. Header por formato

- **EPUB**: infla container.xml, OPF, nav/NCX, encryption.xml; spine, navegação,
  landmark/pageList, rendition (FXL) vêm daí sem tocar nos demais arquivos.
  `contentViewports` é extraído **só dos itens pre-paginated** (os arquivos
  XHTML de livros FXL são pequenos); itens reflowable que declararem viewport
  em conteúdo não o expõem no header (diferença documentada; quem consome
  `viewportForSpineIndex` é a lógica FXL, que só pergunta por itens
  pre-paginated). `archiveEntries` vem do central directory.
- **CBZ**: inventário do central directory + sniff dos primeiros bytes de cada
  candidato (stored: leitura direta; deflate: inflate parcial de ~64 B) para
  decidir página com a mesma semântica de `sniffImageType` do parse completo;
  ordenação natural idêntica; ComicInfo.xml inflado; primeira página
  (cover) sujeita a `coverMaxBytes`. Páginas sob demanda.
- **Outros**: parse completo dentro do worker; header = livro com `files`
  vazio + inventário; recursos servidos do livro residente.

### 4. Cache e políticas

- LRU no **worker** por `path`, orçado por bytes declarados de saída (texto
  conta como bytes UTF-8 ×~2 pela representação String), default 64 MiB.
  Evicção descarta conteúdo; o inventário fica.
- Cliente **não** mantém cache de conteúdo: o worker é a única fonte. Pico do
  cliente = header + payload da requisição em curso.
- Descarte: `dispose()` termina o isolate/worker e drena pendências com
  `SessionClosedException`. Reabertura = nova sessão (sem estado entre sessões).
- Cancelamento: `cancelPending()` completa ops em voo; ops novos depois do
  cancelamento continuam normais. Ops concluídos no worker entre o envio do
  cancel e o processamento são respondidos normalmente (cancel é cliente-side
  na fatia 1; busca é o caso de uso).

### 5. Contrato de integração no Grimoire

- `ViewerController` ganha construtor/fábrica que recebe `BookSession`
  opcional. Com sessão:
  - `BookServer` (io e web): o snapshot `_files` no `start()` é substituído
    por um **resolver assíncrono** (`Future<content> Function(path)`)
    apoiado na sessão. `urlForPath` e derivados viram `Future` onde precisam.
  - `BookProgression.of(book)` na construção → `session.computeProgression()`
    em segundo plano (chega depois do primeiro paint; `progress` sai de
    estado anulável).
  - `book.search(...)` → `session.search(...)` (fallback inline quando sem
    sessão, contrato atual preservado).
  - CFI: `session.resolveCfi/buildCfi`; `_cfiDocFor`/footnote buscam conteúdo
    via sessão e **não memoizam negativo sem invalidar**.
  - MathJax: decisão por página no prepare (o pipeline já injeta por página);
    o sniff global vira heurística de pré-download baseada no que carregar.
  - FXL: `fixedPagePresentationOf(session.book)` funciona sem mudança (dados
    de spine no header). Spread precisa do par carregado antes de montar URL.
- Narration: `MediaOverlayCatalog` ganha provedor opcional
  `Future<Uint8List?> Function(String)` para SMIL fora de `files.others`
  (default: comportamento atual). Inventário de paths continua vindo de
  `archiveEntries` (header). TTS usa `documentTextFor` já existente.
- Exemplo do Grimoire migra para abrir via `BookSession.openFile` no caminho
  de leitura (a estante continua com `readMetadata`).

### 6. Métricas e critério de sucesso (congelados antes da implementação)

Corpus: fixtures públicos (mahabharata 10,8 MB/2020 entradas, dracula 2,5 MB,
moby-dick overlays) + sintéticos gerados (reflowable grande com 300 capítulos
e imagens pesadas; CBZ grande) + biblioteca privada via env (só ids opacos).

- **t_open**: bytes→header pronto (sessão) vs bytes→`Book` completo (hoje).
- **t_first_content**: abertura → primeiro capítulo (HTML+CSS) carregado.
- **pico de RSS** (processo fresco por livro, `ProcessInfo`).
- Leitor real (macOS profile, Chrome debug): parse, montagem→primeiro
  relatório pós-layout, transições, busca — harness e2e existente estendido.
- Frio vs quente; rodadas alternadas A/B; mediana + cauda; ≥5 rodadas.

**Critério**: ≥25% menos pico de memória **ou** ≥20% menos tempo até a
primeira página em ≥2 livros grandes, sem regressão funcional e sem piora
material (>10%) na outra métrica; livros pequenos (dracula) não podem piorar
>10% em nenhuma das duas.

### 7. Furações conhecidas (do mapa de integração)

1. Testes que mutam `book.files` antes de `server.start()`
   (`book_server_test.dart`) — snapshot vira resolver; testes se atualizam.
2. `_documentTextByFile.putIfAbsent` e `_cfiDocFor` memoizam vazio/nulo —
   com sessão, memoização só depois do conteúdo chegar.
3. `_htmlByPath` (footnotes/search excerpt) — virar fetch por demanda.
4. `page_measurement_controller` pagina o livro inteiro via URLs — vai
   puxar todos os capítulos pelo resolver (LRU segura o pico).
5. Media overlays: SMIL de capítulos futuros via provedor de sessão.
6. Estatísticas de `Book.statistics` no header refletem só o carregado;
   livro inteiro via `computeStatistics()` (ninguém na família usa hoje).
