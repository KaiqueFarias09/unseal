---
feature: Leitura EPUB de layout fixo
slug: epub-fixed-layout
version: 1.0
generated: 2026-09-26
status: baseline-recorded
---

# Matriz de casos — EPUB 3 de layout fixo

Cada linha é um caso observável com fixture identificada. `Resultado atual`
registra o leitor na linha de partida (Grimoire 1.0.0 @ a68a357 + Unseal
1.2.0 local @ f0a1ae5): o caminho refluível ignora `rendition:layout`, e as
colunas por plataforma são preenchidas em FXL-05. Fixtures `fxl-*` são
geradas deterministicamente por
`tool/generate_synthetic_format_fixtures.dart` (licença MIT deste repositório)
e registradas em `test/resources/books/manifest.json` +
`test/resources/fuzz/corpus-manifest.json`.

| ID | Recurso | Fixture (origem/licença) | Resultado esperado | Resultado atual (baseline) | Critério de aprovação |
| --- | --- | --- | --- | --- | --- |
| A1 | XHTML `pre-paginated` global abre e preserva dimensões/DOM | `fxl-xhtml-viewport.epub` (gerado, MIT) | Página ocupa palco 1200×1600 escalado; DOM/texto intactos | Renderiza por colunas; viewport ignorada; página não preserva geometria | Abre por `ViewerController.start`; dimensão declarada no palco; texto selecionável |
| A2 | Virar páginas em livro fixo | `fxl-xhtml-viewport.epub` | Swipe/setas navegam `fileIndex ± 1` | pageTurn cruza arquivo, mas geometria errada | `position.fileIndex` muda; sem colunas intermediárias |
| A3 | Restaurar posição | `fxl-xhtml-viewport.epub` | Reabrir volta à mesma página | Restaura por offset em espaço refluível | `goToLocator` restaura `fileIndex` |
| A4 | Regressão: EPUB refluível inalterado | `dracula.epub` (Grimoire example, domínio público) | Comportamento idêntico ao baseline | N/A | Suíte de integração refluível verde, sem diferença de comportamento |
| B1 | Spread sintético (paisagem) | `fxl-spread-hints.epub` (gerado, MIT) | Duas páginas lado a lado em viewport larga | Sem spread (uma página por vez) | Par esquerda+direita visível; `page-spread-center` sozinho |
| B2 | `page-spread-left/right` respeitados | `fxl-spread-hints.epub` | Colocação conforme declaração | Ignorado | Página marcada left nunca cai à direita |
| B3 | Spread em retrato (`spread=portrait`) | `fxl-spread-portrait.epub` (gerado, MIT) | Spread permitido em retrato | Ignorado | Par visível em viewport estreita se declarado |
| B4 | Spread `none` proíbe par | `fxl-spread-hints.epub` (variante) | Uma página por vez | Igual (acidental) | Sem par mesmo em tela larga |
| C1 | RTL: progressão direita→esquerda | `fxl-rtl.epub` (gerado, MIT) | Avanço espelha direção | `page-progression-direction` já respeitado no refluível; fixo inexistente | Ordem visual e de virada espelhadas |
| C2 | RTL: espalhar par espelhado | `fxl-rtl.epub` | Página par à esquerda | Ignorado | Colocação espelhada |
| C3 | Orientação declarada reportada ao host | `fxl-orientation.epub` (gerado, MIT) | Host consulta orientação efetiva por item | Ignorado | API expõe `orientationForSpineIndex`; host do exemplo trava orientação |
| D1 | Item misto fixo dentro de livro refluível | `fxl-mixed-fixed-override.epub` (gerado, MIT) | Item fixo usa palco; vizinhos refluíveis paginam | Tudo refluído | Alternância correta no mesmo livro |
| D2 | Item refluível dentro de livro fixo | `fxl-mixed-reflow-override.epub` (gerado, MIT) | Item refluível usa colunas | Tudo refluído | Alternância correta |
| E1 | SVG standalone no spine | `fxl-svg.epub` (gerado, MIT) | Página SVG com `viewBox` preservada; presente no reading order | Página **descartada** do reading order | Página visível; CFI/progressão contam a página |
| E2 | XHTML com SVG inline | `tristram-shandy.epub` (existente) | Sem regressão | OK | Suíte existente verde |
| F1 | Item `linear="no"` fora do fluxo linear | `fxl-nonlinear.epub` (gerado, MIT) | Acessível via link; fora da contagem | Incluído no fluxo | Página não conta em progressão; alcançável por link |
| F2 | Referência repetida no spine | `fxl-repeated-spine.epub` (gerado, MIT) | Cada ocorrência é página própria | Verificar (spinePaths repete?) | Ocorrências navegáveis independentemente |
| G1 | Zoom fixo: fit/fit-width/1:1/custom | `fxl-xhtml-viewport.epub` | Multiplicador aplica no palco | Sem zoom (só quadrinhos) | APIs de zoom funcionam; pan quando excede |
| G2 | Viewport ausente/malformada/enorme | `fxl-viewport-quirks.epub` (gerado, MIT) | Degrada p/ fit-width; viewport >20000 px rejeitada | Ignorado | Casos tipados sem crash; parse não falha |
| G3 | Redimensionar/janela/orientação mantém página | `fxl-xhtml-viewport.epub` | Fit recalcula; `fileIndex` estável | Recarrega refluído | Posição estável |
| H1 | Seleção/anotação/busca em página fixa | `fxl-xhtml-viewport.epub` | Offsets canônicos inalterados | N/A no modo fixo | Seleção → anotação → restauração; busca acha termo da página |
| H2 | Teclado e ordem de leitura | `fxl-xhtml-viewport.epub` | Setas/PageUp viram página; ordem = spine | Parcial (teclado refluível) | Navegação por teclado no modo fixo |
| H3 | SMIL media overlay em página fixa | `fxl-overlays.epub` (gerado, MIT) | Narração destaca fragmento no palco | N/A | `fragmentOffset`+`markNarrationRange` funcionam no modo fixo |
| H4 | Narrar página fixa sem texto | `fxl-overlays.epub` (página imagem) | Avança sem travar | N/A | TTS/overlay completam a página |
| I1 | `scripted` rejeitado explicitamente | `fxl-scripted.epub` (gerado, MIT) | `<script>` inerte; DOM sem efeito do script | JS já desligado por política | Teste prova que script não executa |
| J1 | Livro FXL real (bitmap pages) | `page-blanche.epub` (W3C/IDPF, CC-BY-SA-3.0) | Páginas 1200×1577 preservadas, spread ok | Renderiza refluído, geometria errada | Matriz A/B/C verifica com fixture real |
| J2 | Livro FXL privado do usuário | (privado, fora do Git) | Observação por plataforma | Não testado | Registro com ID privado; fora de relatórios compartilháveis |
| K1 | Regressão: PDF facsimile | `dickens-sample.pdf` (existente) | Sem mudança | OK | Suíte PDF verde |
| K2 | Regressão: quadrinhos | `synthetic-pages.cb7` (existente) | Sem mudança | OK | Suíte quadrinhos verde |
| K3 | Regressão: media overlays refluível | `moby-dick-media-overlays.epub` (existente) | Sem mudança | OK | Suíte Narration verde |

Livros privados (J2) ficam fora do Git e dos relatórios compartilháveis;
registram-se apenas IDs privados e resultado.

## Baseline do leitor atual (registro FXL-01)

Confirmado por inspeção de código (nenhum uso de `EpubRendition`/`EpubLayout`
em `lib/` do Grimoire), por probe de integração no macOS
(`example/integration_test/fxl_baseline_probe.dart`, temporário) e por captura
visual (`/tmp/fxl-artifacts/baseline/macos-page-blanche-before-window.png`):
com `page-blanche.epub`, o leitor atual parseia (169 ms) e abre (primeiro
relatório de página 827 ms) pelo caminho refluível — `column 0/1`, viradas de
página ~107 ms cruzando arquivos — mas a página bitmap renderiza no tamanho
natural dos pixels, cortada pela janela, sem palco 1200×1577, sem fit-to-window,
sem spreads e sem zoom. Livros `pre-paginated` são paginados pelo caminho de
colunas, a viewport do livro é ignorada, itens SVG standalone são descartados
do reading order pelo parser e itens `linear="no"` entram no fluxo linear.
`page-progression-direction` é o único recurso já honrado (refluível).
