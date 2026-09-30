# Incidência medida — acervos DjVu (onda W1)

Data: 2026-09-30. Entregável da §3 do
[desenho congelado](design.md): tabela chunk × arquivo medida com
`djvudump` e as prioridades que os números congelam para W2/W3. Hashes e
licenças de cada arquivo estão em
[`test/resources/djvu/PROVENANCE.md`](../../../test/resources/djvu/PROVENANCE.md).

## Método

```sh
# djvulibre 3.5.29 (Homebrew), sobre os 6 arquivos em git + 2 de estresse
djvudump test/resources/djvu/cyrillic.djvu        # idem para os demais
djvudump /Volumes/SSD/Projects/bench-artifacts/scanned-2026-09-30/pathogenic_bacteria_1896.djvu
djvudump /Volumes/SSD/Projects/bench-artifacts/scanned-2026-09-30/hawthornescount00clargoog.djvu
# contagem por linha de chunk/FORM:
awk '/^ *[A-Za-z0-9]+ \[/ { counts[$1]++ } END { for (k in counts) print k, counts[k] }' <dump>
```

`djvudump` termina limpo (exit 0) nos oito arquivos. Corpus em git:
`cyrillic.djvu`, `spec-bundled.djvu`, `navm-fgbz.djvu`, `links.djvu`,
`goody-twoshoes.djvu`, `speller-1921.djvu` (≈ 3,1 MB total). Estresse, fora
do git: `pathogenic_bacteria_1896.djvu` (25,3 MB) e
`hawthornescount00clargoog.djvu` (9,5 MB).

## Corpo e páginas

| Arquivo | Páginas (DIRM) | Arquivos no DIRM | Tamanho (bytes) |
| --- | --- | --- | --- |
| `cyrillic.djvu` | 12 | 13 | 171.563 |
| `spec-bundled.djvu` | 71 | 85 | 489.402 |
| `navm-fgbz.djvu` | 6 | 7 | 100.415 |
| `links.djvu` | 1 | 1 | 440 |
| `goody-twoshoes.djvu` | 16 | 16 | 1.060.487 |
| `speller-1921.djvu` | 121 | 121 | 1.298.208 |
| `pathogenic_bacteria_1896.djvu` (estresse) | 520 | 572 | 26.562.908 |
| `hawthornescount00clargoog.djvu` (estresse) | 449 | 449 | 10.004.746 |

## Incidência chunk × arquivo

| Chunk/FORM | cyrillic | spec-bundled | navm-fgbz | links | goody-twoshoes | speller-1921 | pathogenic (estresse) | hawthorne (estresse) | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `FORM:DJVM` | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 8 |
| `FORM:DJVU` | 12 | 71 | 6 | 1 | 16 | 121 | 520 | 449 | 1.196 |
| `FORM:DJVI` | 1 | 4 | 1 | 0 | 0 | 0 | 52 | 0 | 58 |
| `FORM:THUM` | 0 | 10 | 0 | 0 | 0 | 0 | 0 | 0 | 10 |
| `DIRM` | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 8 (todos bundled) |
| `INFO` | 12 | 71 | 6 | 1 | 16 | 121 | 520 | 449 | 1.196 |
| `Djbz` | 1 | 5 | 1 | 0 | 0 | 0 | 52 | 0 | 59 |
| `INCL` | 12 | 70 | 6 | 0 | 0 | 0 | 513 | 0 | 601 |
| `Sjbz` | 12 | 71 | 6 | 1 | 16 | 119 | 517 | 449 | 1.191 |
| `BG44` | 0 | 33 | 12 | 0 | 64 | 20 | 0 | 192 | 321 |
| `FG44` | 0 | 0 | 0 | 0 | 16 | 3 | 0 | 48 | 67 |
| `BGjp` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `TXTa` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `TXTz` | 12 | 71 | 0 | 0 | 9 | 115 | 0 | 379 | 586 |
| `NAVM` | 0 | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 3 |
| `BMKz` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `ANTa` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `ANTz` | 0 | 71 | 1 | 0 | 0 | 0 | 0 | 0 | 72 |
| `TH44` | 0 | 71 | 0 | 0 | 0 | 0 | 0 | 0 | 71 |
| `FGbz` | 0 | 13 | 6 | 0 | 0 | 0 | 0 | 0 | 19 |
| `FGjp` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `Smmr` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `INCF` | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `CIDa` (extra, obsoleto) | 0 | 71 | 0 | 0 | 16 | 121 | 0 | 449 | 657 |

Nenhum documento indireto foi observado na natureza (DIRM `indirect`/`INCF`:
0 em 8 arquivos); o indireto da §3 é o derivado
(`djvmcvt -i` sobre `cyrillic.djvu`, paridade 12/12 páginas idênticas — ver
`/Volumes/SSD/Projects/bench-artifacts/scanned-2026-09-30/derived/README.md`).

## Padrões estruturais observados

- **Dicionários múltiplos com troca ativa** (`spec-bundled`): 4 dicionários em
  formas `DJVI` (`dict0020/0040/0060/0071.iff`) + 1 `Djbz` inline dentro da
  página 1; os 70 `INCL` apontam `dict0020` 19× (págs. 2–20), `dict0040` 20×
  (21–40), `dict0060` 20× (41–60), `dict0071` 11× (61–71). Ou seja: INCLUDE
  re-numera o dicionário ativo por página e o alvo muda ao longo do documento.
  `pathogenic` repete o padrão em escala (52 `Djbz`, ~10 páginas por
  dicionário, 513 `INCL` em 520 páginas); `cyrillic` é o caso mínimo (1
  dicionário, todas as páginas).
- **Páginas sem máscara**: `speller` tem 121 páginas mas 119 `Sjbz` — há
  página só de fundo (BG44). `pathogenic` tem 520 páginas, 517 `Sjbz` e
  **zero** BG44: acervo de máscara pura sobre fundo branco.
- **`CIDa`** aparece em todo pipeline Google/IA (`goody`, `speller`,
  `hawthorne`) e no sintético `spec-bundled` — chunk obsoleto da spec, sempre
  36 bytes; ignorável, mas precisa não quebrar o parse da página.
- **`THUM`/`TH44`** (miniaturas) só em `spec-bundled` — estrutura separada do
  livro, referenciada pelo DIRM com flag de thumbnail.
- **`TXTz` domina o texto real** (586 de 586 chunks de texto do corpus
  binário; `TXTa`: 0). O único TXTa do pacote é o fixture sintético
  `jpeg-only.djvu` — mantê-lo como caso de continuidade, não como
  representativo.
- **`BMKz`, `ANTa`, `FGjp`, `Smmr`**: zero em tudo. `FGbz` (19) existe em
  documentos com máscara colorida por paleta (`navm-fgbz` é o fixture dele).

## Prioridade congelada por classe (o que os números dizem)

- **Texto (W2)**: `TXTz` é obrigatório e o caminho principal (207 páginas com
  texto nos 6 em git; paridade byte a byte contra `djvutxt`, oráculos já
  arquivados). `TXTa` segue como está (só sintético). `NAVM` cobre 3/6
  arquivos em git; `BMKz` sem fixture — parse conforme spec, sem golden.
  `ANTz` (72) e `CIDa` (657) permanecem fora do escopo W2: continuar
  tipados/ignorados sem quebrar o parse.
- **Dicionários e indiretos (W3)**: `Djbz`+`INCL` são onipresentes no corpus
  JB2 (601 INCL / 59 Djbz) e o caso múltiplos-dicionários com troca de alvo
  (`spec-bundled`, `pathogenic`) é obrigatório, não opcional. DIRM bundled
  está em 8/8 documentos — o parser atual já o atravessa. Indireto: 0 na
  natureza (resultado não comprovável, como o desenho já registrava); o
  bundle derivado `cyrillic-indirect` (13 componentes, índice de 115 bytes) é
  o caso de teste W3, com paridade de pixels já demonstrada.
- **Camadas de imagem**: `BG44` em 6/8 documentos, `FG44` em 3/8 — a suíte
  IW44 existente continua sendo o núcleo; `Sjbz` 1.191× é o codec JB2 (já
  coberto, falta herança do dicionário). `FGjp`/`BGjp` ficam restritos ao
  fixture sintético jpeg-only. `FGbz` (19×) e `TH44` (71×) ficam fora das
  ondas W2/W3 conforme desenho §4-§5 — seguem tipados/ignorados; tabela final
  de formatos não cobertos vai ao README (W5).
- **TIFF (W4)**: amostras reais multipágina publicadas não foram coletáveis
  (loc.gov 403 programático; archive.org sem formato indexado); o conjunto
  local é o asset de regressão do libtiff + reescritas `tiffcp` (G4/LZW) —
  ver `bench-artifacts/.../tiff/README.md`. Incidência multipage "na
  natureza" segue não comprovada; W4 decide os fixtures rastreados.
