---
feature: Leitura EPUB de layout fixo
slug: epub-fixed-layout
version: 1.1
status: implemented
generated: 2026-09-26
---

# Especificação verificável — EPUB 3 de layout fixo

Esta especificação deriva de `research.md` e define o que cada pacote deve
fazer para que os critérios FXL-01…FXL-05 (`prompt-80-implementacao.md`) sejam
observáveis. A matriz de casos versionada vive em `matrix.md`.

## 1. Escopo e decisões de design

- **Modo dedicado, não rasterização.** Páginas `pre-paginated` XHTML/SVG são
  apresentadas com o DOM original dentro de um palco de dimensões declaradas
  (`viewport` do XHTML, `viewBox`/`width`/`height` do SVG), escalado para caber
  na viewport. Texto permanece selecionável; não há captura de imagem da página.
- **Itens refluíveis preservam o caminho atual** (colunas CSS). Livros mistos
  alternam por item do spine, conforme `rendition:layout` efetivo.
- **Editor manda por padrão.** Geometria, orientação, spread e colocação
  declarados no livro vencem. O leitor expõe override explícito na API do
  controlador (zoom e spread), sem UI obrigatória; hosts decidem como expor.
  A orientação declarada é **reportada** ao host (evento/consulta por item);
  forçar a orientação do dispositivo é responsabilidade do host, pois uma
  biblioteca não deve mexer em `SystemChrome` global.
- **JavaScript do livro permanece desligado** (`BookJavaScriptPolicy.disabled`).
  Itens `scripted` são renderizados como dados; o `<script>` não executa e o
  comportamento é coberto por teste (caso de rejeição explícita).
- **DRM e certificação de acessibilidade** continuam fora do escopo.

## 2. Contrato do Unseal (modelo)

Adições ao modelo EPUB, todas públicas por `lib/unseal.dart`/`lib/epub.dart`:

1. **`EpubViewport { int width, height }`** — dimensões declaradas de um
   documento de conteúdo. Origem válida: `<meta name="viewport">` XHTML com
   `width`/`height` inteiros positivos; SVG raiz com `viewBox` e/ou
   `width`/`height`. Declaração malformada, fracionária ou não positiva é
   ignorada (item fica sem viewport), sem falhar o parse.
2. **`EpubBook.contentViewports: Map<String, EpubViewport>`** — chaveado pelo
   caminho OPF-relativo normalizado do documento de conteúdo (mesmo espaço de
   chaves de `files.html`), cobrindo XHTML e SVG standalone.
3. **Linearidade do spine.** `linear="no"` do `itemref` passa a ser exposto:
   `EpubBook.nonLinearSpinePaths: Set<String>` (caminhos do spine marcados
   não lineares). Itens não lineares continuam no `readingOrder`.
4. **Consultas efetivas por índice do spine** em `EpubBook`:
   `EpubLayout layoutForSpineIndex(int)`, `EpubOrientation orientationForSpineIndex(int)`,
   `EpubSpread spreadForSpineIndex(int)`, `EpubPageSpread? pageSpreadForSpineIndex(int)`,
   `EpubViewport? viewportForSpineIndex(int)`, `bool spineItemIsLinear(int)`.
   Resolvem idref → manifest → overrides de `EpubRendition`; fallback para os
   padrões da especificação (reflowable/auto/auto/auto).
5. **Documentos SVG standalone no reading order.** Itens de spine com
   media-type `image/svg+xml` entram em `files.html` como `TextFile` (bytes +
   texto) e portanto em `readingOrder`, CFI, busca e progressão. Conteúdo SVG
   inline em XHTML não muda.
6. **Wire codec web**: `contentViewports` e a linearidade viajam no codec do
   livro (compacto: apenas itens `pre-paginated` e itens não lineares),
   com versão/round-trip testado em `dart test -p chrome`.

Regras de segurança: viewport é usado como dado declarado, com limites —
dimensões além de 20000 px são rejeitadas (item sem viewport). Nenhum
allocation é derivado da viewport no parser.

## 3. Contrato do Grimoire (apresentação)

1. **Detecção.** `ViewerController.isFixedLayoutEpub` e
   `isFixedLayoutPage(int fileIndex)` derivam de `EpubBook.layoutForSpineIndex`.
2. **Página fixa (FXL-02).** O servidor serve o XHTML original com `class`
   extra `elv-fixed` no `<body>` e `data-elv-page="W×H"` (da viewport declarada;
   sem viewport declarada: 100% da viewport do webview, fit-width). O
   `viewer.js` constrói um palco `.elv-stage` de `W×H` px com o conteúdo
   original, centralizado e escalado por `min(vw/W, vh/H)`; colunas desativadas;
   eventos reportam `column=0, columns=1`. Gestos horizontais viram página
   (caminho `pageTurn` existente, que já navega `fileIndex ± 1`).
3. **Spreads (FXL-03).** Quando o spread efetivo permite (declaração do livro +
   orientação atual) e a largura disponível couber duas páginas, o servidor
   compõe `/__spread__/<i>/<j>` com dois iframes same-origin, cada um com a
   página fixa original; o palco do spread soma as larguras e respeita a ordem
   visual do RTL (`page-progression-direction="rtl"` espelha a colocação).
   Colocação: `page-spread-left/right/center` e `rendition:spread-*`; um item
   `center` fica sozinho. `fileIndex` do par = primeiro item do par na ordem do
   spine.
4. **Zoom (FXL-03).** `ViewerFixedLayoutSettings { zoomMode: fitPage|fitWidth|oneToOne|custom, customScale }`
   no controlador (default `fitPage`). Aplicado como multiplicador do fit
   base no palco; pan quando o conteúdo excede a viewport (maquinaria de zoom
   dos quadrinhos reutilizada).
5. **Navegação (FXL-03).** Links internos, sumário (`goToNavPoint`), landmarks,
   `goToLocator`/CFI e restauração de posição resolvem para `fileIndex` da
   página (offset é irrelevante dentro da página fixa: qualquer offset daquele
   arquivo restaura a mesma página). `linear="no"`: excluído da contagem de
   páginas e da progressão linear; acessível por link/sumário. Referências
   repetidas no spine produzem páginas independentes (cada ocorrência é um
   `fileIndex` próprio).
6. **Interações (FXL-04).** Seleção, busca (`BookSearch` + `DocumentTextScanner`
   sobre o texto canônico do XHTML), anotações (offsets + CFI) e marcas de
   narração funcionam dentro do palco fixo sem mudança de espaço de offsets.
   Teclado (setas, PageUp/Down) vira página. Ordem lógica de leitura = ordem do
   spine; o host acessa a orientação efetiva por item.
7. **Mudança de tamanho/orientação (FXL-03).** O palco recalcula o fit;
   `fileIndex` e posição permanecem estáveis. Fechar/reabrir restaura a página.

## 4. Contrato do Grimoire Narration (FXL-04)

- Media overlays em páginas fixas usam o mesmo contrato de sempre:
  `fragmentOffset(fileIndex, fragment)` + `markNarrationRange` devem funcionar
  no modo fixo (o `viewer.js` do palco resolve fragmento → offset canônico e
  aplica a marca dentro do palco).
- Páginas fixas sem texto (imagem/SVG sem texto) não travam narração: TTS
  planeja capítulo vazio e avança; overlay com segmentos de texto parcial
  narra o que existe.
- `media:active-class` e correspondência com texto canônico preservados;
  geração/tokens e esperas de arquivo inalterados.

## 5. Critérios de aceitação por etapa

| Etapa | Termina quando |
| --- | --- |
| FXL-01 | `matrix.md` tem, para cada recurso, ≥1 caso observável com fixture identificada (origem/licença/hash), resultado no leitor atual e critério de aprovação. |
| FXL-02 | Um EPUB XHTML `pre-paginated` abre pelo caminho público (`GrimoireView`/`ViewerController.start`), preserva dimensões e DOM, página utilizável, vira páginas e restaura posição; teste de integração no motor real (fake-friendly + webview no macOS); captura visual comparável; regressão automatizada em EPUB refluível verde. |
| FXL-03 | Todos os casos de geometria/navegação da matriz passam em viewport pequeno e grande; posição estável ao redimensionar, fechar/reabrir e voltar. |
| FXL-04 | Testes de ponta a ponta para seleção, busca, anotação, teclado, ordem de leitura; SMIL integra quando presente; limite de JS documentado e caso `scripted` rejeitado explicitamente. |
| FXL-05 | Matriz executada no macOS, Chrome e S23 físico com resultados por plataforma; medições antes/depois com dispersão; regressões refluível/PDF/quadrinhos verdes. |

## 6. Limites explícitos (fora do contrato)

- Conteúdo que exige JavaScript do livro não é suportado (política atual).
- DRM: falha tipada, sem bypass.
- Não há equivalência pixel a pixel com leitores comerciais; a conformidade é
  com a matriz desta especificação.
- Viewport ausente em item `pre-paginated` degrada para fit-width do documento
  original (sem recorte).
