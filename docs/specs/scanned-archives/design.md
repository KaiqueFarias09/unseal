# Desenho congelado — acervos digitalizados: DjVu v3 completo + TIFF/BigTIFF

Data: 2026-09-30. Status: **congelado antes da implementação** (mesmo ritual
das campanhas anteriores). Coordena os agentes; desvios entram como
"(implementado: …)" aqui.

## 1. Objetivo e critérios

1. Completar DjVu v3 **conforme incidência em corpus real**: dicionários
   JB2 compartilhados (Djbz/INCL), componentes indiretos (DIRM/INCF),
   texto comprimido (TXTz/BZZ), navegação comprimida (NAVM/BMKz).
2. TIFF multipágina e depois BigTIFF com offsets seguros (64-bit, sem
   overflow).
3. Núcleo em Dart puro; **limites verificados antes de alocar** (mesma
   postura dos codecs existentes: tamanho declarado validado contra os
   bounds ANTES do `Uint8List`); suporte **explícito por codec**
   (tabela por codec no README + exceções tipadas
   `DjvuUnsupportedCodecException`/nova para TIFF).
4. Corpus redistribuível com licença + hash + proveniência (padrão
   `test/resources/djvu/PROVENANCE.md`); paridade de páginas e texto
   contra referências independentes (`ddjvu`/`djvutxt` 3.5.29 brew,
   `tiffinfo`/`tiffcp` libtiff); fuzz com minimização (harness existente);
   leitura visual no Grimoire.
5. Regressões VM + Chrome e testes ponta a ponta.
6. Documentar precisamente formatos/fragmentos NÃO cobertos e resultados
   não comprováveis.

## 2. Postura de licença (congelada)

**Nenhum código GPL entra no pacote.** Implementação clean-room a partir
de: especificação DjVu v3 (sndjvu.org + PDF DjVu3Spec, em
/tmp/djvu-corpus/DjVu3Spec.pdf) e cross-check contra a referência MIT
`djvu-rs`/`djvu-bzz` (mesma postura já usada: notice vendido em
`licenses/djvu-rs-MIT.txt`). Oráculo de desenvolvimento: `djvutxt`/`ddjvu`
locais — saídas comparadas byte a byte e registradas como goldens nos
testes (testes são o contrato comportamental).

## 3. Corpus (agente W1)

Arquivos-alvo (todos verificados por quem pesquisou; hashes na
proveniência):

| Arquivo | Licença | Cobre |
| --- | --- | --- |
| `cyrillic.djvu` (djvu-rs corpus) | PD (1905) | DIRM bundled, Djbz, 12×INCL, 12×TXTz, 12×Sjbz |
| `spec_bundled.djvu` (djvu-rs fixtures) | Unlicense | 71 págs, 5×Djbz, 70×INCL, 71×TXTz, NAVM, THUM, FGbz, ANTz |
| `navm_fgbz.djvu` (idem) | Unlicense | NAVM, ANTz, FGbz, Djbz+6×INCL |
| `links.djvu` (idem) | Unlicense | NAVM mínimo |
| `goody.djvu` (archive.org 1888) | PD | produção real: JB2+BG44+FG44, 9×TXTz |
| `speller.djvu` (archive.org 1921) | PD | 121 págs, 115×TXTz (pipeline Google) |

- Corpo em git ≤ ~4 MB; arquivos de estresse maiores (pathogenic_bacteria
  25 MB, hawthorne 10 MB) ficam em
  `/Volumes/SSD/Projects/bench-artifacts/scanned-2026-09-30/` (fora do
  git), citados na proveniência.
- **Tabela de incidência** (chunk × arquivo, via `djvudump`) é entregável
  do W1 e congela prioridades das ondas seguintes.
- **Referências independentes** geradas e arquivadas junto: `djvutxt -out=text`
  por arquivo (texto), `ddjvu -format=bmp` por página amostrada (pixels),
  ambos com hash sha256 no PROVENANCE.
- **Indiretos**: nenhum bundle indireto redistribuível existe na natureza
  (pesquisa exaustiva) — DERIVAR: extrair componentes verbatim de
  cyrillic/spec_bundled e montar indireto com `djvmcvt -i` (bytes DIRM
  derivados nossos; conteúdo PD/Unlicense). Documentar: incidência real de
  indiretos não pôde ser medida por falta de corpus público — resultado
  não comprovável, registrado.

## 4. Onda W2 — BZZ, TXTz, NAVM (unseal)

- `lib/src/features/djvu/bzz_decoder.dart`: decoder BZZ (BWT inverso +
  MTF-4 modificado + árvore de contexto de 262 entradas + codificador ZP
  existente no pacote). Mesmos padrões de limites (tamanho declarado
  validado antes de alocar; cap de saída; erros tipados `DjvuException`).
- `TXTz`: header/grama §8.3.5 (BE24 comprimento, UTF-8, byte de versão,
  registros de zona de 17 bytes: Ztype/X/Y/W/H/parent/child); texto da
  página = texto em ordem de leitura conforme separadores da spec —
  **paridade byte a byte com `djvutxt`** nos goldens. `DjvuPage.text`
  passa a vir de TXTz quando presente (TXTa segue igual); `documentText`/
  busca via `files.html` herdam de graça.
- `NAVM`/`BMKz`: registros (contagem de filhos + BE24 descrição + BE24
  URL) → `DjvuBook.navigation` real (pontos com título; destino de página
  resolvido quando a URL aponta para `#+N`/página). Sem NAVM: navigation
  vazia como hoje.
- Wire web: `book_wire_codec` do DjvuBook já leva texto por página;
  navigation segue o codec genérico de navigation (verificar e estender se
  o ramo Djvu não a carrega). Testes Chrome espelham (djvu_wire_test com
  TXTz/NAVM).
  - "(implementado: TXTz via BZZ próprio validado byte a byte contra
    `djvutxt` nos 207 páginas de texto do corpus — 310.032 bytes; texto da
    página prefere TXTz sobre TXTa quando ambos existem — corpus real não
    tem página com ambos; separadores: NUL de zona-página vira LF+FF e o
    separador entre páginas é LF+FF, regra derivada empiricamente do oráculo
    e pinada por hash nos testes. NAVM vira Navigation real com árvore
    iterativa e claims verificados; URLs ficam verbatim no `content` do
    ponto. Wire carrega navigation no ramo Djvu; chrome test cobre TXTz+NAVM.
    FGbz passou de tipado para ignorado (tinta preta sobre o background)
    para que spec-bundled/navm-fgbz abram inteiros — o desenho §4 já
    permitia 'tipados/ignorados'; Smmr/FGjp seguem tipados. Orçamentos de
    documento subiram para 2048 MP / 1 GiB porque speller mede 1.414 MP de
    página; os testes de budget usam as constantes e seguem verdes.)"
- Explícito não coberto (W2): FGjp, FGbz, Smmr, ANTa/ANAZ, TH44 — continuam
  tipados/ignorados conforme incidência medida; tabela final no README.

## 5. Onda W3 — Djbz + INCL + indiretos (unseal, após W2)

- `Djbz`: dicionário de símbolos compartilhado por documento; `Sjbz`
  decodifica com símbolos herdados (record type 9/referência herdada no
  JB2 decoder — hoje rejeitados). Múltiplos Djbz + `INCL` por página
  (INCLUDE numero o dicionário ativo). Ordem: INCL precede Sjbz na página.
- **Indiretos**: DIRM com flag bundled limpo lista componentes por nome
  (+ flags/id). Contrato: `parseDjvuBook(bytes)` continua bytes-only e
  rejeita indiretos tipada; NOVO caminho io em `Unseal.readFile`
  (book_dispatch io) que, detectado DIRM indireto, carrega os arquivos
  irmãos (mesmo diretório) e entrega as páginas — `DjvuComponentsResolver`.
  Web/bytes: rejeição tipada documentada (não dá para resolver irmãos sem
  filesystem/pacote).
- Paridade: páginas do indireto derivado == páginas do bundled original
  (hash de pixels `ddjvu`).
  - "(implementado: DIRM decodificado (header + nomes BZZ com sizes/flags/
    ids); `parseDjvuBook(bytes)` segue rejeitando indiretos tipada;
    `Unseal.readFile` resolve irmãos no adaptador io (nomes simples, sem
    traversal, sizes conferidos; tabela de nomes original copiada verbatim
    para o DIRM montado, então INCL continua resolvendo); web/bytes segue
    rejeição tipada documentada. Fixture rastreado derivado: 1 página +
    dicionário de cyrillic via `djvm -d` + `djvmcvt -i` (PROVENANCE.md);
    paridade de página/texto contra o bundled original pinada. Dicionários:
    Djbz decodifica (streams de dicionário só aceitam records 2/5/9/10/11);
    ledger de 64 MP por documento; herança via record 9 + INCL resolvido
    pelos ids do DIRM; troca de dicionário no meio do documento
    (spec-bundled, 4 dicionários + 1 inline) validada por renders
    byte-idênticos do ddjvu nas páginas 1/36/71. Dicionários encadeados
    (record 9 com contagem > 0 num Djbz) seguem tipados-não-suportados.
    Paridade MRC composta: o compositor da casa usa seleção dura de máscara
    com expansão bilinear — desvio limitado e documentado vs o stencil
    mesclado do ddjvu (média ≤ 3,3/255 em goody); páginas de máscara e foto
    ficam byte-idênticas.)"

## 6. Onda W4 — TIFF multipágina → BigTIFF (unseal, paralela)

- Novo `lib/tiff.dart` + `lib/src/features/tiff/`. Modelo `TiffBook`
  (padrão DjvuBook: páginas com raster como `BinaryFile` + wrappers html
  por página; sem camada de texto). `BookFormat.tiff`,
  `DetectedFormat.tiff` (II*\0 / MM\0* e BigTIFF 2B/2M),
  despacho em `book_dispatch`.
- Codecs suportados, **por incidência medida em corpus** (LoC samples +
  gerados + reescrita com `tiffcp`): baseline none, PackBits, LZW,
  Deflate/Zip, CCITT G4 (acervos!), JPEG-in-TIFF se trivial. Cada codec:
  suporte explícito (tabela) ou `TiffUnsupportedCodecException` tipada.
- **Limites antes de alocar**: ImageByteLength/StripOffsets validados
  contra o tamanho do arquivo ANTES de `Uint8List`; caps de
  amostras/pixel, strips/tiles, dimensões (256 MP teto da casa); IFD chain
  com detecção de ciclo; SampleFormat/PlanarConfig não suportados →
  tipado.
- **BigTIFF**: offsets de 8 bytes, entry de 20 bytes, contagens >2^32;
  checagens de overflow explícitas (offset+length ≤ filesize, sem int
  wrap). Structural features (multipage, BigTIFF) documentadas por
  suporte.
- Raster: decodificar para pixels (BMP como os codecs da casa) para
  entrega ao viewer; tiles e planar=1 no primeiro corte (planar=2 raro —
  incidência decide).
- Wire web: ramo `TiffBook` em `book_wire_codec` + teste Chrome estilo
  `djvu_wire_test`.
- Paridade: `tiffinfo` (estrutura), pixels via decodificação com libtiff
  (`tiffcp` para codec conhecido + comparação de raster) nas referências.

## 7. Ondas W5 — integração

- Grimoire: assets de exemplo (1 DjVu com TXTz+NAVM — cyrillic; 1 TIFF
  multipágina gerado, gitignored como os large-*), entrada na prateleira,
  **teste visual/e2e** de leitura (abrir, paginar, mostrar texto/nav) no
  macOS; wire/Chrome regressions; e2e ponta a ponta.
- Fuzz: seeds djvu novos (TXTz/NAVM/Djbz/INCL/indirect-DIRM) + família
  `tiff`; minimização pelo `fuzz_book_campaign` existente.
- Docs: README (tabela por codec DjVu+TIFF, limites), guide, spec
  `docs/format-expansion.md` ou novo doc de acervos; seção "formatos ainda
  não cobertos" precisa (FGjp/FGbz/Smmr/ANTa/TH44/planar=2/exóticos TIFF)
  e "resultados não comprovados" (incidência de indiretos, paridades sem
  oráculo).

## 8. Higiene

Commits atômicos Conventional+gitmoji, paths explícitos, sem
push/publicação/tag; fixtures binários são dados-fonte (não reescrever
para teste passar; proveniência na mesma commit). Irmãos limpos verificados
(em 2026-09-30: unseal @b253f73 limpo, grimoire @6fcca33 limpo,
narration intocado).
