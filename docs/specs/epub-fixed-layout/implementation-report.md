---
feature: Leitura EPUB de layout fixo
slug: epub-fixed-layout
version: 0.3
status: fxl-03-in-progress
generated: 2026-09-26
---

# Relatório de implementação — EPUB 3 de layout fixo

Registro progressivo da missão (`prompt-80-implementacao.md`). Commits locais,
sem push/tag/publicação. Artefatos binários (capturas, logs de medição) vivem
fora do Git em `/tmp/fxl-artifacts/` (efêmero) e são reproduzíveis pelos
comandos listados; a auditoria (`prompt-40-auditoria.md`) roda a partir do
commit exato informado no fim deste relatório.

## Ambiente

- macOS 27.0 arm64, Dart 3.13.4 (fvm), Flutter via fvm default.
- Chrome 153 (web), Galaxy S23 físico SM-S911B (Android 16, adb wireless
  `192.168.100.234:41679` / `RXCXA00HDPE`), app `dev.grimoire.grimoire_example`.
- Unseal `/Volumes/SSD/Projects/eLivre` (main local), Grimoire
  `/Volumes/SSD/Projects/e_livre_viewer` (main local), Grimoire Narration
  `/Volumes/SSD/Projects/e_livre_viewer_narration` (checkout com alterações
  locais pré-existentes preservadas; baseline 66/66 testes verdes antes do
  FXL).
- Worktrees de agente: `/Volumes/SSD/Projects/ai-worktrees/fxl-unseal`
  (branch `fxl/unseal`), `/Volumes/SSD/Projects/ai-worktrees/fxl-grimoire`
  (branch `fxl/grimoire`). Dependência local via `pubspec_overrides.yaml`
  (gitignored): Grimoire → Unseal main local.

## FXL-01 — Contrato e matriz ✅

- `spec.md` v1.1: contrato verificável Unseal/Grimoire/Narration, decisões
  (editor manda, JS do livro desligado, orientação reportada ao host).
- `matrix.md` v1.0: 29 casos (A geometria, B spreads, C RTL/orientação,
  D mistos, E SVG, F não-linear/repetidos, G zoom/quirks/redimensionar,
  H interações, J livros reais/privado, K regressões), cada um com fixture,
  origem/licença, resultado esperado, critério de aprovação.
- Baseline verificado do leitor atual (probe real no macOS + captura):
  page-blanche abre pelo caminho refluível, página bitmap em tamanho natural
  cortada pela janela, sem palco/spread/zoom (parse 169 ms, abertura 827 ms,
  viradas ~107 ms). Capturas: `/tmp/fxl-artifacts/baseline/`.
- Fixtures: `page-blanche.epub` (W3C/IDPF, CC-BY-SA-3.0, já rastreada) +
  13 fixtures sintéticas determinísticas geradas (MIT, ver FXL-02).
- Commits: `e879a15` (spec+matriz+missão), `16b66a5` (baseline verificado).

## FXL-02 — Primeira entrega vertical ✅

**Unseal** (`fxl/unseal` → merge `fbb8096`):
- `072661a` modelo: `EpubViewport`, `EpubBook.contentViewports`,
  `nonLinearSpinePaths`, `spineIdrefs`, helpers
  `layoutForSpineIndex/…/viewportForSpineIndex/spineItemIsLinear`; SVG
  standalone entra em `files.html`/reading order/CFI/busca.
- `6dad2b9` fixtures: 13 EPUBs sintéticos (`fxl-*.epub`, 2.1–3.5 KB) gerados
  deterministicamente, manifest.json + corpus-manifest.json atualizados.
- `376726e` wire: `spineIdrefs`, viewports compactos e linearidade no codec
  web, decodificação tolerante.
- Gates: `dart analyze --fatal-infos` limpo; VM 1011→**1046** testes; Chrome
  test/web 40→**41**; `--check-manifest` OK; `pub publish --dry-run` 0 avisos.

**Grimoire** (`fxl/grimoire` → merge `4c12075` + `8e44d02`):
- `053dd03` deps `unseal ^1.2.0` (lockstep; overrides locais gitignored).
- `96c3dbb` apresentação: `fixed_layout.dart`
  (`FixedPagePresentation`, `fixedPagePresentationOf`, `isFixedLayoutFile`),
  `injectFixedPageMarkers`, `ViewerController.isFixedLayoutEpub/isFixedLayoutPage`,
  medição semeada 1 página por item fixo, typography gating; JS `elv-fixed`
  (body = palco `elv-stage`, `data-elv-page="W×H"`, fit-scale
  `min(vw/W, vh/H)`, transform-origin 0 0), positionChanged `column 0/1`,
  pageTurn horizontal RTL-aware, teclado, canonical text/`locateFragment`/
  `ttsMark`/highlights preservados; viewport meta do livro descartada em
  páginas fixas (device-width mantido — evita dupla escala; documentado).
- `d52e104` fixtures sincronizados do Unseal (14 EPUBs) + README de resources.
- `928bf30` docs (README, guia, CHANGELOG).
- `8e44d02` `example/integration_test/e2e_fxl_reader_test.dart`: probe
  real-engine com marcos separados (parse/controller/viradas/frames).
- Gates: analyze limpo; `flutter test` 304→**314**; example analyze+test OK;
  `dart doc --dry-run` 0 avisos.

**Evidência visual (macOS, janela 800×632, debug):**
- Antes (`/tmp/fxl-artifacts/baseline/macos-page-blanche-before-window.png`):
  bitmap em pixels naturais, cortado à direita.
- Depois (`/tmp/fxl-artifacts/fxl02/macos-page-blanche-after.png`): palco
  1200×1577 com fit-page, página inteira visível, centrada.
- e2e real engine (debug): parse 210 ms, controller→1º relatório 356 ms,
  viradas medianas 560 ms (6 viradas, ida e volta), frames jank 1%.
- Regressão refluível: suíte completa 314 verde + e2e refluível existente.

**Critérios A1, A2, A3, J1 atendidos no macOS** (matriz).

## FXL-03 — Geometria e navegação completas ✅

Commit `af4e787` (branch `fxl/grimoire`, merge `097ec58` no main local):
- **Spreads sintéticos**: `FixedPresentation` + `fixedPresentationsOf` (walk de
  pareamento no spine: `page-spread-left/right` forçam lado, `center` fica
  sozinho, fillers em branco apenas quando há contexto de spread; `auto`
  pareia só em viewport larga e escala legível ≥0.35). Wrapper
  `/__spread__/<l>/<r>` no servidor IO (loopback) e no web (blob): duas
  metades iframe same-origin com `elvframe=1` + frame guard
  (`injectSpreadFrameGuard`), que religa a ponte via `window.parent`;
  palco único escalado (fit/zoom/pan), ordem visual espelhada em RTL,
  pageTurn por par via gestos/teclado no wrapper.
- **Zoom**: `ViewerFixedLayoutSettings` (`FixedPageZoomMode`
  fitPage/fitWidth/oneToOne/custom, escala 1..5) + `setFixedLayoutSettings`
  no controlador; página única ganha os mesmos modos no viewer.js
  (`setFixedLayout`), pan por arrasto quando ampliado.
- **Orientação reportada**: `fixedLayoutOrientationFor(fileIndex)` no
  controlador (o host decide travar o dispositivo).
- **Navegação**: `_flowTarget` — spreads viram como unidade e itens
  `linear="no"` saem do fluxo linear (continuam alcançáveis por locator/
  sumário/link); `setLogicalViewport` re-pareia e recarrega mantendo a
  posição; restauração de locator dentro de um par recarrega o spread
  inteiro.
- Cobertura pequena/grande viewport nos testes de pareamento
  (700×1300 vs 2400×1300); wrapper com metades guardadas verificado por
  fetch; `flutter test` 314→**322**.
- Nota de auditoria: pareamento exige viewports declarados nas duas metades
  (decisão registrada no código; livros sem viewport degradam para página
  única, sem fillers).

## FXL-04 — Interações e acessibilidade ✅

Commits `6c9c0fc` (Grimoire) e `aafa55f` (Narration):
- **Script do livro**: `fxl-scripted.epub` servido sem o `<script>` do livro
  (política `disabled` intocada); teste prova isolamento no modo fixo.
- **Busca**: `controller.search` encontra termos no texto canônico de página
  fixa; marcas via `showSearchMatches` chegam ao palco.
- **Seleção/anotações**: seleção na página fixa produz offsets canônicos;
  `addHighlightFromSelection` grava (offsets + CFI) e re-render via
  `applyHighlights`.
- **SMIL/Narration**: catálogo considera página `pre-paginated` elegível para
  overlay (segments/fragment resolvidos); playback de overlay na página fixa
  toca o clipe e, na página fixa sem texto, a narração termina sem travar
  (testes com os doubles existentes; suíte Narration 66→**68**).
- **Ordem de leitura/teclado**: ordem = spine; teclado e swipe viram página
  no modo fixo (caminho `pageTurn`, já coberto no FXL-02/03 e validado em
  navegador real na entrega FXL-02).
- **Limites documentados** (spec §6): JS do livro permanece desligado;
  DRM fora do escopo; sem equivalência pixel a pixel.

