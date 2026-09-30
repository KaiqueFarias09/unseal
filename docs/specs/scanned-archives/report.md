# Relatório de missão — acervos digitalizados: DjVu v3 completo + TIFF/BigTIFF (2026-09-30)

**Status: escopo do [desenho congelado](design.md) cumprido por incidência, com
paridades medidas contra os oráculos, fuzz estrutural sobre os fixtures reais
sem defeito, e os formatos não cobertos e os resultados não comprováveis
listados com os números medidos.** Nenhuma correção de código foi necessária
nesta rodada de fechamento: a campanha de fuzz com minimização (6.480 mutantes
únicos sobre os fixtures DjVu e TIFF) não produziu nenhum escape não-tipado,
crash ou timeout, e as paridades pinadas nos testes foram re-verificadas
byte a byte contra os oráculos arquivados. Commits das ondas: `99fea77`
(BZZ), `cd24da5` (TXTz+NAVM), `2606ab0` (Djbz+INCL), `6be4d26` (indiretos),
`eff3edf`/`041786b` (paridade e adversariais DjVu), `6d143db`+`6ba5e33`+
`b5af57a` (TIFF/BigTIFF: parser, corpus e paridade), `b2283f3` (docs TIFF).

## 1. Escopo entregue

### 1.1 DjVu v3 completo por incidência (ondas W2/W3)

- **BZZ** (`99fea77`): decodificador próprio (BWT inverso, MTF-4 modificado,
  árvore de contexto de 262 entradas, codificador ZP do pacote) com tamanho
  de bloco declarado validado contra o limite de 4 MiB e o cap de saída do
  chunk ANTES de alocar.
- **TXTz** (`cd24da5`): texto oculto comprimido byte a byte igual ao
  `djvutxt` 3.5.29 nas **207 páginas com texto dos 6 documentos em git —
  309.932 bytes** (soma medida sobre os oráculos arquivados
  `references.sha256`; paridade pinada por SHA-256 por documento em
  `test/tests/djvu/djvu_corpus_test.dart`). Convenções de separador derivadas
  do oráculo e pinadas: NUL de zona-página vira LF+FF e o separador entre
  páginas é LF+FF. `DjvuPage.text` prefere TXTz sobre TXTa quando ambos
  existem (o corpus real não tem página com ambos; o caso é coberto por
  fixture sintético).
- **NAVM** (`cd24da5`): `DjvuBook.navigation` real com árvore iterativa e
  claims de filhos verificados contra o pool de registros; URLs verbatim no
  `content` do ponto. 3 dos 6 documentos em git carregam NAVM; os testes
  pinam os rótulos/URLs/filhos dos três.
- **Djbz + INCL** (`2606ab0`): dicionários JB2 compartilhados com herança
  (record 9) e troca de dicionário no meio do documento — `spec-bundled`
  carrega 4 dicionários externos + 1 inline e 70 INCL que trocam o alvo nas
  páginas 2–20/21–40/41–60/61–71; os renders das páginas 1/36/71 são
  **byte-idênticos ao `ddjvu`** (re-medido nesta rodada: média de erro
  0,000/255). Ledger de 64 MP por documento cobrado antes de alocar cada
  bitmap.
- **Indiretos** (`6be4d26`, `041786b`): DIRM decodificado (header, nomes BZZ,
  sizes/flags/ids); `parseDjvuBook(bytes)` rejeita indireto tipado;
  `Unseal.readFile` resolve os componentes irmãos no adaptador io (nomes
  simples, sem traversal, sizes conferidos; tabela de nomes copiada verbatim
  para o DIRM montado). Paridade: bundle derivado de 12 páginas verificado
  manualmente 12/12 idêntico ao bundled; fixture derivada rastreada de 1
  página (`derived/cyrillic-page1-index.djvu`) pinada igual ao bundled em
  raster e texto.
- **Composição MRC**: máscara e páginas de foto byte-idênticas ao ddjvu —
  re-medido nesta rodada contra os renders arquivados, média 0,000/255 em
  cyrillic p1/p6/p12, spec-bundled p1/36/71, links p1, speller p61/p121.
  Páginas compostas seguem a convenção da casa (seleção dura de máscara sobre
  expansão bilinear), com desvio limitado documentado (§3).
- **Orçamentos**: documento em 2048 MP / 1 GiB de raster (speller mede
  1,414 GP de página somada); os testes de budget usam as constantes.
- **Fuzz**: família `djvu` no harness (sementes do corpus rastreado, magic
  AT&T para passar o sniffer) e campanha por fixture (§2).

### 1.2 TIFF multipágina e BigTIFF (onda W4)

- **Despacho e modelo**: `BookFormat.tiff`/`DetectedFormat.tiff` cobrem os
  quatro magics (II/MM × 42/43, versão desambiguada no parser); `TiffBook`
  espelha `DjvuBook` (páginas com width/height/dpi, imagem BMP + wrappers
  HTML, metadados ImageDescription/DateTime/Software/Artist/Copyright e DPI
  de X/ResolutionUnit); ramo no `book_wire_codec` com teste Chrome.
- **Codecs suportados** (tabela por codec no README e em
  `test/resources/tiff/PROVENANCE.md`): none, PackBits, LZW (inclusive o
  compat bit-reverso antigo, com a heurística de detecção do libtiff),
  Deflate/AdobeDeflate com predictor 2, CCITT Group 4 e Group 3 (modified
  Huffman incluído; decodificador T.4/T.6 row-oriented próprio, com fallback
  contínuo para produtores sem EOL — o arquivo real
  `testfax3_bug54_1dnoEOL.tif` decodifica; o G4 real 2453×3369 decodifica
  pixel-idêntico ao `tiffcmp`), e passthrough de JPEG só com strip única
  auto-contida.
- **BigTIFF**: offsets 64-bit lidos como par high/low com rejeição acima de
  4 GiB, entradas de 20 bytes, contagens 64-bit, ambas as ordens de bytes.
- **Multipágina**: todo IFD da cadeia vira página (página 1 primeiro),
  SubIFDs ignorados, ciclo de IFD detectado e rejeitado tipado.
- **Limites antes de alocar**: offsets/byte counts validados contra o arquivo
  (subtração, sem wrap); caps de entrada 128 MiB, 1.024 páginas, 65.536
  entradas por IFD, 4 samples/pixel, 256 MP/página, 1M segmentos/página,
  256 MP decodificados por documento e 128 MiB de raster por documento.
- **Paridade contra libtiff**: `tiffcmp -t` por página contra
  `tiffcp -c none` para **todos os fixtures decodificáveis — OK em
  2026-09-30 com libtiff 4.7.2** (incluindo a página G4 real 2453×3369, os
  strips LZW compat antigos e as páginas tiled LZW reais); em CI a mesma
  evidência fica pinada como hashes SHA-256 de raster (goldens em
  `test/tests/tiff/tiff_test.dart`) mais os oráculos de pixel PBM/PGM/PPM
  comparados pixel a pixel para as imagens reais bilevel/gray/RGB.
- **Corpus**: 9 fixtures geradas (`tool/tiff_fixtures.dart` + `tiffcp` 4.7.2)
  + 15 imagens reais do corpus MIT do libtiff (commit `d23249978a7a`),
  ≈ 750 KB em git, hashes e licença em `PROVENANCE.md`.

## 2. Campanha de fuzz com minimização

Ferramenta: `tool/fuzz_book_campaign.dart` — mutação estrutural
determinística sobre os fixtures reais (mutadores de
`test/fuzz/harness/fuzz_mutators.dart`: bit-flip, overwrite, truncamento,
region fill, cauda aleatória; 2 rodadas de mutação por mutante), cada
execução dentro de worker isolate matável com deadline de 20 s atravessando
4 pontos de entrada (`detectFormat`, `Unseal.parse`, `readMetadataSync`,
`Unseal.read`). Classificação por execução: **ok** (parseia; com perda de
>50% do texto marcado como `content-loss`, informativo), **typed**
(rejeição da hierarquia `UnsealException`) e **defect** (erro não-tipado,
crash do isolate ou timeout — com minimização por redução de quartos e
repro salvo fora do git).

Execução desta rodada (2 sementes × passes padrão e profundo; relatórios
JSON e repro em `/Volumes/SSD/Projects/bench-artifacts/scanned-2026-09-30/fuzz/`,
fora do Git):

| Formato | Fixtures | Mutantes únicos | Execuções | ok | typed | defect | content-loss |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| DjVu (7 fixtures, 120 rounds × 2 sementes) | 7 | 1.680 | 2.016 | 176 | 1.504 | **0** | 5 |
| TIFF (24 fixtures, 100 rounds × 2 sementes) | 24 | 4.800 | 5.760 | 1.005 | 3.795 | **0** | 0 |
| **Total** | **31** | **6.480** | **7.776** | **1.181** | **5.299** | **0** | **5** |

- Pristine checks: 31 fixtures únicos (DjVu 7/7 ok; TIFF 17 ok e 7 tipados —
  os tipados são exatamente os fixtures negativos por desenho: JPEGTables,
  SGILOG, planar=2, old JPEG, palette, tiled JPEG e o IFD loop hostil).
- **Zero defeitos: nenhum escape não-tipado, nenhum crash, nenhum timeout.**
  O minimizador nunca disparou (diretório de repro vazio) e nenhum teste de
  regressão novo foi necessário em `test/fuzz/regressions/`.
- Os 5 `content-loss` (DjVu profundo) são mutantes que parseiam com menos de
  metade do texto do original — dano de conteúdo esperado sob mutação de
  bytes de TXTz, não violação de invariante; a classe existe para mostrar
  perda silenciosa, e nenhuma delas veio de entrada íntegra.
- O inventário de corpus (`tool/fuzz_corpus_inventory.dart`) foi atualizado
  nesta rodada: o manifesto rastreado (`test/resources/fuzz/corpus-manifest.json`)
  ainda não conhecia os arquivos das ondas DjVu/TIFF — passou de 173 para
  **212 arquivos rastreados**, o que traz os fixtures DjVu/TIFF para a
  campanha estendida (`dart test --tags fuzz`).

## 3. Formatos ainda não cobertos (com incidência medida)

### 3.1 DjVu — por chunk (incidência em `incidence.md`)

| Chunk/estrutura | Incidência medida | Estado no parser |
| --- | --- | --- |
| `FGjp` | 0 em 8 arquivos (só o fixture sintético `jpeg-only` exerce BGjp; FGjp não tem fixture) | **Tipado-não-suportado** (substitui a camada JPEG de primeiro plano) |
| `Smmr` | 0 | **Tipado-não-suportado** (substitui a máscara JB2) |
| `ANTa`/`ANAZ` | 0 | Ignorados |
| `ANTz` | **72** (spec-bundled 71, navm-fgbz 1) | Presente e **silenciosamente ignorado** (anotações fora do contrato de leitura) |
| `TH44` (formas `THUM`) | **71** TH44 / 10 THUM (spec-bundled) | **Ignorado** (miniaturas, estrutura fora do livro) |
| `FGbz` | **19** (spec-bundled 13, navm-fgbz 6) | **Ignorado desde a onda W2**: a máscara renderiza tinta preta onde o ddjvu pinta cores de paleta — desvio medido nesta rodada: média 0,068/8,954/5,399 por 255 (máx. 255) nas páginas 1/3/6 de navm-fgbz |
| `BGjp` | 0 no corpus escaneado | **Suportado** (página JPEG direta) via `jpeg-only.djvu` |
| `BMKz` | 0 | **Silenciosamente ignorado** (NAVM implementado; BMKz sem fixture e sem parse conforme spec) |
| Dicionários `Djbz` encadeados (record 9 com contagem > 0) | 0 no corpus (o padrão observado são dicionários independentes trocados por INCL — esse é suportado) | **Tipado-não-suportado** |
| `TXTa` | 0 no corpus binário (586/586 chunks de texto são TXTz) | Suportado como legado (fixture sintético) |
| `CIDa` (obsoleto) | 657 | Ignorado sem quebrar o parse |

### 3.2 TIFF — por codec/layout (incidência no corpus rastreado)

Todos os itens abaixo falham com `TiffUnsupportedCodecException` (ou
`TiffException`, nos casos estruturais) e têm fixture rastreada que documenta
o caso:

| Codec/layout | Incidência no corpus rastreado (24 fixtures) |
| --- | --- |
| Palette (PhotometricInterpretation 3) | 1 real (`palette-1c-8b.tiff`) — tipado |
| LogLuv/SGILOG (SampleFormat ≠ 1) | 1 real (`logluv-3c-16b.tiff`) — tipado |
| PlanarConfiguration 2 | 1 real (`minisblack-2c-8b-alpha.tiff`, alpha assoc.) — tipado; nota: Extra Samples em layout chunky (planar=1) decodificam com o canal extra descartado |
| SampleFormat ≠ 1 (float etc.) | tipado (mesmo site do LogLuv) |
| Old-style JPEG (compression 6) | 1 real (`ojpeg_zackthecat_...`) — tipado |
| JPEG-in-TIFF além de strip única auto-contida (JPEGTables, tiled, multi-strip) | 2 (`jpeg-external-tables.tif` gerada, `quad-tile.jpg.tiff` real) — tipados |
| Tiled (qualquer codec raster) | tipado |
| FillOrder 2 | tipado |
| Uncompressed-mode extensions (T4Options bit 1 / T6Options bit 0) | tipados |
| Predictor ≠ 2, BitsPerSample mistos, sub-byte multi-amostra | tipados/`TiffException` |

Incidência "na natureza" para TIFF não pôde ser medida (§4.2); a incidência
acima é a do corpus rastreado, que documenta cada classe não-suportada com
arquivo real ou gerado.

## 4. Resultados não comprováveis

1. **Incidência de indiretos (DIRM `indirect`/`INCF`) na natureza não pôde
   ser medida**: nenhum bundle indireto redistribuível existe publicamente
   (pesquisa exaustiva da W1). A paridade está provada para o bundle
   **derivado** (`djvmcvt -i` sobre cyrillic: 12/12 páginas idênticas,
   verificação manual registrada em `041786b`) e para a fixture derivada
   rastreada de 1 página (raster e texto idênticos ao bundled, testados).
   Não é evidência sobre documentos indiretos produzidos por terceiros.
2. **Corpus público multipage TIFF real não foi coletável**: loc.gov atrás de
   desafio Cloudflare (HTTP 403 programático) em 2026-09-30. O conjunto usado
   são as imagens de teste do próprio libtiff (MIT) + fixtures geradas;
   multipage real via `test_two_ifds.tif`/`tiff_with_subifd_chain.tif`.
   Incidência multipage em acervos reais segue não comprovada.
3. **MRC composto não é claimed como ddjvu-idêntico**: o compositor da casa
   (seleção dura de máscara + expansão bilinear) desvia do stencil mesclado
   do ddjvu dentro do bound documentado — re-medido nesta rodada contra os
   renders arquivados: média 3,221/255 (máx. 91) em goody p1, 1,632/255 (88)
   em goody p8, 2,685/255 (72) em goody p16 e 0,598/255 (176) em speller p1.
   Essas páginas são pinadas com **hashes próprios**, não com hashes ddjvu.
   `FGbz` segue com cores de paleta não reproduzidas (tinta preta; médias
   0,068–8,954/255 em navm-fgbz, máx. 255).
4. **A nota de missão sobre um "artefato de canto em 2 canais" na página de
   foto p2 do speller não reproduz contra o oráculo arquivado**: speller p2
   é hoje byte-idêntica ao ddjvu (média 0,000/255, render e oracle com o
   mesmo SHA-256). O desvio composto que existe (p1) é distribuído pela
   página — bbox x[29..1243] y[79..1177] de 1275×1650, três canais
   afetados — não concentrado em canto. Fica registrado o fato medido; a
   menção original não corresponde a nenhum estado atual verificável.
5. **Oráculo único por formato**: `djvutxt`/`ddjvu` do djvulibre 3.5.29
   (Homebrew) é a única referência independente usada para DjVu (texto e
   pixels); `tiffcmp`/`tiffcp` do libtiff 4.7.2 é a única para TIFF. As
   paridades byte a byte são contra UMA referência por formato; não há
   segunda implementação independente de acordo.

## 5. Matriz de verificação (números exatos desta rodada)

| Verificação | Resultado |
| --- | --- |
| `dart format --output=none --set-exit-if-changed .` | limpo (504 arquivos, 0 mudanças) |
| `dart analyze --fatal-infos` | limpo ("No issues found!") |
| `dart test --exclude-tags fuzz` (VM) | **1.274 testes, todos passando** |
| `dart test -p chrome test/web/` (worker recompilado) | **52 testes, todos passando** |
| `dart test --tags fuzz` (campanha estendida sobre o corpus rastreado) | passando (1 teste; corpus de 212 arquivos × 3 mutações cada) |
| `dart run tool/fuzz_corpus_inventory.dart --check-manifest` | **OK: 212 tracked files** (manifesto atualizado nesta rodada; estava em 173 sem os arquivos DjVu/TIFF) |
| Campanha `fuzz_book_campaign` (DjVu + TIFF) | 6.480 mutantes únicos / 7.776 execuções / **0 defeitos** / 5 content-loss informativos |
| Paridade DjVu re-medida (oráculos arquivados) | 9 páginas byte-idênticas (média 0,000); compostas dentro do bound (médias 0,598–3,221, máx. 72–176) |
| Paridade TIFF | `tiffcmp -t` OK para todos os decodificáveis (libtiff 4.7.2, 2026-09-30) + goldens SHA-256 e oráculos PBM/PGM/PPM pixel a pixel em CI |

## 6. Coerência de documentação

Tabela por codec do README (linha DjVu e linha TIFF), seção de limites e os
sites de exceção tipada no código foram conferidos nesta rodada. Ajustes
aplicados (só docs):

- README: `BMKz` adicionado à lista explícita de chunks ignorados (era o
  único chunk silenciosamente ignorado fora da lista); nota de que dicionário
  compartilhado que herda outro dicionário é rejeitado tipado; cap de
  256 MP decodificados por documento incluído na lista de limites TIFF
  (existia no código, faltava no README, nos dois lugares).
- `design.md`: nota "(implementado)" do TXTz corrigida de 310.032 para
  **309.932 bytes** — o número medido somando os oráculos arquivados (a
  nota congelada tinha um arredondamento impreciso).
