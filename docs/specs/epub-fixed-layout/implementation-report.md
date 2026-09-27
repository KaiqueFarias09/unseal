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


## FXL-05 — Validação de produto ✅ (com falha registrada no web)

### Defeitos encontrados e corrigidos durante a validação

1. `d97c5c4` — pareamento de spread espiava `index+1` sem limite e crashava
   (`RangeError 0..9: 10`) quando um par se formava no fim do spine
   (reproduzido com page-blanche, 10 itens). Correção: legibilidade avaliada
   na dupla exata; permissão por item só declaração. Teste: suíte 21/21.
2. `1fb46da` (Unseal) — `fxl-spread-hints`/`fxl-spread-portrait` foram gerados
   sem `rendition:layout=pre-paginated`; o leitor corretamente não os tratava
   como fixos (prova de que a detecção não falso-positiva). Fixtures
   regeneradas, hashes/manifests/corpus atualizados, sincronizadas com o
   Grimoire (`93c77b7`).
3. `61b25a1` — o boot do wrapper de spread rodava do `<head>`, antes do DOM
   (`#elv-spread` null): sem fit, sem relay, metades em tamanho natural.
   Movido para o fim do `<body>`. Captura pós-fix mostra o par lado a lado.

### Matriz por plataforma (resultados)

Legenda: ✓ atendido · ✗ falha registrada · ⚠ parcial/limitado.

| Caso | macOS (desktop webview, debug/profile) | Chrome (web release) | S23 físico (profile) |
| --- | --- | --- | --- |
| A1/A2/A3 XHTML fixo, virar, restaurar | ✓ (captura antes/depois; e2e 6 viradas ida-e-volta; restore por locator) | ⚠ aplicativo abre e ativa modo fixo; pintura de bitmap incompleta (falha abaixo) | ✓ captura do aparelho: fit-page correto |
| B1/B2 spreads + colocação | ✓ captura `macos-spread-hints.png` (par left+right, gap, escala) | não testado (falha de pintura acima bloqueia validação visual) | não testado visualmente |
| B4 spread none | ✓ unidade (sem par em retrato) | — | — |
| C1/C2 RTL | ✓ captura `macos-rtl.png` (filler à esquerda, página à direita) | — | — |
| C3 orientação reportada | ✓ API + teste | ✓ (mesma engine Dart) | ✓ |
| D1/D2 itens mistos | ✓ captura `macos-mixed.png` (item fixo em estágio entre prosa) | — | — |
| E1 SVG standalone | ✓ (Unseal: reading order/CFI/busca; apresentação = caminho fixo) | — | — |
| F1 não-lineares | ✓ (fora do fluxo, alcançáveis por locator) | — | — |
| F2 spine repetido | ✓ (teste in-memory) | — | — |
| G1 zoom (fitPage/fitWidth/1:1/custom+pan) | ✓ (unidade + wrapper) | — | — |
| G2 quirks de viewport | ✓ (unidade, tipado sem crash) | — | — |
| G3 redimensionar re-pareia | ✓ (teste) | — | — |
| H1 busca/seleção/anotação | ✓ (testes FXL-04) | — | — |
| H3/H4 narração em página fixa | ✓ (Narration 68/68, overlay+silêncio) | — | — |
| I1 `scripted` inerte | ✓ (teste FXL-04) | — | — |
| J1 page-blanche real | ✓ | ✗ | ✓ |
| K1–K3 regressões refluível/PDF/quadrinhos | ✓ 325 + 35 testes | — | — |

**Falha web registrada (não mascarada):** no build release web, o modo fixo
ativa e o app abre page-blanche, mas o conteúdo bitmap não pinta por
completo na captura (`/tmp/fxl-artifacts/matrix/chrome-page-blanche*.png` —
faixas escuras/colunas em branco). Texto canônico e estágio foram validados
em Chrome headless durante o FXL-02 (seleção, transform, col 0/1) com fixture
XHTML; o caminho de imagem (bitmap FXL) em release web precisa de
investigação própria (suspeita: decodificação/pintura de blob de imagem
grande no canvas do iframe). Bloqueio adicional: `flutter drive -d chrome`
fica preso no handshake DWDS em execução não interativa
(`/tmp/fxl-artifacts/chrome-drive.log`).

### Medições (mesmo dispositivo/livro/modo de build; rodadas repetidas)

macOS, profile, page-blanche, instrumento idêntico (`fxl_baseline_probe`,
temporário; logs em `/tmp/fxl-artifacts/`):

| Marco | Antes (a68a357, caminho refluível) | Depois (FXL) |
| --- | --- | --- |
| Parse | 83 / 88 / 99 ms (mediana 88) | 95 / 102 / 91 ms (mediana 95) |
| Abertura→1º relatório | 640 / 354 / 652 ms | 671 / 272 / 213 ms |
| Virada (nextChapter) | ~104 ms | 279 / 120 / 123 ms (1ª inclui warm-up) |

e2e commitado (`e2e_fxl_reader_test.dart`, profile, 3 rodadas): parse
81–93 ms; controlador→1º relatório 154–220 ms; mediana de virada 561–579 ms
(6 viradas 0→3→0, cada uma recarrega arquivo/palco); frames: jank 0–3%,
p90 1,0–1,8 ms, pico isolado 36–75 ms. Nenhum ganho é reivindicado: o
"caminho antes" não preservava geometria; as viradas do modo fixo custam
mais que colunas (~0,5–0,6 s por recarga de arquivo vs ~0,1 s) — custo
conhecido de navegação entre arquivos, documentado como ponto de melhoria
(precarregar o par seguinte).

S23 (profile, sm-s911b): parse 718 / 737 / 751 ms; captura visual do
fit-page correta (`s23-page-blanche.png`). O driver de integração
(`flutter drive`) ficou instável no adb wireless (timeout do VMService antes
dos marcos seguintes); tempo de abertura/virada no aparelho ficou sem número
confiável e está registrado como não medido — não reportado como aprovado
por inferência. Memória: não instrumentada (limitação; exigiria DevTools
interativo), registrada como não medido.

### Como reproduzir (auditoria)

A partir do commit informado abaixo, com overrides locais gitignored
(Grimoire→Unseal):

```sh
# Unseal
dart analyze --fatal-infos && dart test --exclude-tags fuzz \
  && dart test -p chrome test/web/ \
  && dart run tool/fuzz_corpus_inventory.dart --check-manifest
# Grimoire
flutter pub get && dart analyze --fatal-infos && flutter test
(cd example && flutter analyze && flutter test)
# Narration (overrides locais p/ grimoire+unseal)
flutter analyze --fatal-infos && flutter test
# e2e real engine (macOS/S23; asset commitado em example/assets/books)
cd example && flutter drive --profile -d macos \
  --driver=test_driver/e2e_scenario_driver.dart \
  --target=integration_test/e2e_fxl_reader_test.dart
```

## Commit de entrega (auditoria parte deste exato estado)

- Unseal main local: `1fb46da`
- Grimoire main local: `93c77b7`
- Grimoire Narration main local: `aafa55f` (+ alterações locais pré-existentes
  não commitadas preservadas, como exigido)
- Sem push, tag ou publicação.

## Limitações e pendências honestas

- Web/bitmaps: falha de pintura em release web (acima); spreads no web
  nunca validados visualmente.
- S23: tempo de abertura/virada e memória não medidos com número confiável
  (driver sem fio); visual e parse registrados.
- Livro FXL privado do usuário (caso J2 da matriz): não testado nesta
  sessão (arquivo privado não foi disponibilizado ao coordenador).
- `dart analyze --fatal-infos` do Narration tem 1 aviso pré-existente em
  `tool/generate_sample_epub.dart` (presente também sem as mudanças FXL).
- BookProgression (fração de progresso do Unseal) ainda pondera itens
  `linear="no"` no denominador do livro inteiro; o fluxo/contagem de páginas
  do leitor já os exclui.
