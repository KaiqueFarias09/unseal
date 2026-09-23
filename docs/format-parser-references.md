---
feature: Referências para novos formatos de leitura
slug: format-parser-references
version: 1.0
status: draft
generated: 2026-09-23
---

# Referências para parsers e arquivos de teste

> Esta pesquisa registra a seleção inicial de referências. O estado implementado
> e as limitações da próxima release estão em [Format expansion](format-expansion.md).

## 1. Objetivo da Pesquisa

Identificar especificações, implementações de referência e arquivos de teste para
KEPUB, Markdown, RTF, CHM, DjVu, PDB, LRF e LRX. O objetivo é decidir quais formatos
podem entrar no Unseal, uma biblioteca Dart pura que também roda no navegador,
sem declarar suporte com base apenas em arquivos gerados pelo próprio parser.

## 2. Eixos de Pesquisa

- Especificações e parsers compatíveis com a arquitetura Dart pura.
- Arquivos reais e casos de conformidade com origem e direitos verificáveis.
- Limites de escopo, licenças e riscos de parsing de arquivos não confiáveis.

## 3. Achados por Eixo

### 3.1 Especificações e parsers

- KEPUB mantém a estrutura de EPUB e usa a extensão `.kepub.epub` para ativar o
  mecanismo de leitura Kobo; o caminho EPUB existente deve ser validado antes de
  criar um parser independente. — [Kobo EPUB Guidelines](https://github.com/kobolabs/epub-spec)
- O Kepubify, sob licença MIT, fornece um conversor EPUB→KEPUB independente para
  gerar casos de comparação. — [Kepubify](https://github.com/pgaskin/kepubify)
- Markdown tem uma especificação testável; `package:markdown` é uma implementação
  Dart utilizável em VM e navegador, mas a conversão para HTML requer uma política
  própria para conteúdo não confiável. — [CommonMark](https://spec.commonmark.org/0.31.2/),
  [package:markdown](https://pub.dev/packages/markdown)
- RTF tem uma especificação publicada pela Microsoft que cobre grupos, palavras
  de controle, destinos e Unicode. Ela permite implementar um parser de leitura
  limitado sem depender de ferramentas nativas. — [RTF 1.9.1](https://officeprotocoldoc.z19.web.core.windows.net/files/Archive_References/%5BMSFT-RTF%5D.pdf)
- CHM usa o contêiner ITSF e LZX. A tradução Intel E8 foi comparada com a
  regra publicada pela Microsoft e com o leitor CHMLib; os testes também
  cobrem LCIDs que selecionam Windows-1251, 1252 e 1256. A disposição de
  registros `#SYSTEM` vem das notas de formato CHM; os IDs de idioma e as
  páginas de código vêm das tabelas da Microsoft. —
  [CHM ITSF](https://www.nongnu.org/chmspec/latest/ITSF.html),
  [CHM #SYSTEM](https://www.nongnu.org/chmspec/latest/Internal.html),
  [MS-PATCH E8](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-patch/e6c8366d-a8c3-4f34-aa5d-56f44f938a09),
  [MS-LCID](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-lcid/63d3d639-7fd2-4afb-abbe-0d5b5551eef8),
  [code pages da Microsoft](https://learn.microsoft.com/en-us/windows/win32/intl/code-page-identifiers),
  [CHMLib](https://github.com/jedwing/CHMLib/blob/master/src/lzx.c)
- PDB é um contêiner com subformatos distintos. PalmDOC, eReader, Plucker e MOBI
  têm estruturas próprias; MOBI deve seguir o parser MOBI, enquanto eReader e
  Plucker exigem implementação separada. — [documentação PDB do Calibre](https://github.com/kovidgoyal/calibre/tree/master/format_docs/pdb)

### 3.2 Arquivos de teste e conformidade

- A Standard Ebooks oferece KEPUBs produzidos para Kobo, inclusive *The Red
  Badge of Courage*. O corpus inclui essa edição real, produzida sem Kepubify,
  com licença, origem e hash registrados no manifesto. Ela complementa o KEPUB
  convertido de uma amostra EPUB pelo Kepubify. — [edição](https://standardebooks.org/ebooks/stephen-crane/the-red-badge-of-courage),
  [orientações de download](https://standardebooks.org/help/how-to-use-our-ebooks)
- O projeto CommonMark disponibiliza mais de 500 exemplos com entrada Markdown
  e saída esperada; são úteis como matriz de conformidade. Imagens relativas,
  front matter e metadados de livro precisam de casos próprios. — [suíte CommonMark](https://github.com/commonmark/commonmark-spec/blob/master/README.md)
- O `LICENSE.rtf` do Calibre é um arquivo RTF real e público para uma prova de
  leitura. Casos pequenos gerados devem cobrir Unicode, grupos aninhados,
  destinos ignorados, imagens e entradas truncadas. — [arquivo RTF](https://github.com/kovidgoyal/calibre/blob/master/LICENSE.rtf),
  [especificação RTF](https://officeprotocoldoc.z19.web.core.windows.net/files/Archive_References/%5BMSFT-RTF%5D.pdf)
- O projeto chmv guarda um manual PuTTY em CHM junto de sua licença; `chmcmd`
  também pode produzir amostras pequenas de conteúdo próprio. O corpus já inclui
  esse manual com a licença PuTTY e o hash da versão testada no manifesto.
  — [amostra CHM](https://github.com/bjxpen/chmv/tree/main/test/fixtures),
  [chmcmd](https://gitlab.com/freepascal.org/fpc/source/-/blob/bce88f2e2bf76c3f979902aaa60598a0487f1509/packages/chm/src/chmcmd.lpr)
- Para DjVu, o corpus inclui uma página JPEG gerada, uma camada Sjbz real de
  obra federal dos EUA e um arquivo IW44 com licença Unlicense. O teste remove
  as demais camadas em memória para verificar a máscara JB2; o documento
  composto de origem continua rejeitado. — [especificação DjVu 3](https://www.epapyrus.jp/docs/techinfo/DjVu3Spec.pdf),
  [djvu-rs](https://github.com/matyushkin/djvu-rs)
- O Calibre documenta a conversão para eReader PDB e LRF, e oferece `lrf2lrs`
  como validador auxiliar. As amostras válidas do corpus foram geradas a partir
  de conteúdo próprio pelo Calibre 9.4.0. Uma tentativa com o writer independente
  Eruditio, no commit `c517504356fcf1ec68a72be5a5005dff393da3f8` (Apache-2.0),
  produziu um arquivo de 873 bytes, mas o Calibre 9.4.0 o rejeitou por um Link
  genérico desconhecido em `BookAttr`; o Unseal também não encontrou sua árvore
  de páginas. A documentação de proveniência registra os hashes e o motivo da
  exclusão. As variantes LRF 1, 799 e 800 são sintéticas e cobrem somente o
  cabeçalho legado.
  — [ebook-convert](https://manual.calibre-ebook.com/generated/en/ebook-convert.html),
  [lrf2lrs](https://manual.calibre-ebook.com/generated/en/lrf2lrs.html),
  [writer Eruditio em commit fixo](https://github.com/DevExzh/eruditio/blob/c517504356fcf1ec68a72be5a5005dff393da3f8/crates/eruditio/src/formats/lrf/writer.rs),
  [BookAttr no Calibre 9.4.0](https://github.com/kovidgoyal/calibre/blob/55e3f7667ee04a52addee24a38c91b98b28a55d1/src/calibre/ebooks/lrf/objects.py#L1163)
- A documentação oficial da Sony separa BBeB sem proteção do BBeB com Marlin
  e sua nota histórica diz que o BBeB pode usar OpenMG para proteger direitos.
  Essas páginas não especificam o invólucro `.lrx`. O Calibre serve apenas como
  oráculo comportamental para reconhecer `LRX`/`ftypLRX2` e localizar a caixa
  `bbeb` com metadados; nenhum código GPL foi copiado. Os testes usam bytes
  sintéticos. O Unseal expõe somente os metadados plaintext encontrados nessa
  caixa e rejeita qualquer tentativa de ler o conteúdo do livro como DRM.
  — [Sony sobre formatos suportados](https://www.sony.com/electronics/support/articles/S1F0504),
  [Sony sobre BBeB e OpenMG](https://www.sony.com/ja/SonyInfo/News/Press/200403/04-0324A),
  [metadados LRX no Calibre](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/ebooks/metadata/lrx.py)

### 3.3 Escopo, licenças e segurança

- O subset JB2 segue os registros e a codificação ZP da especificação DjVu 3;
  suas tabelas de estado foram conferidas com a implementação independente
  djvu-rs, sob licença MIT. A implementação em Dart não copia código GPL do
  DjVuLibre. — [especificação DjVu 3](https://www.epapyrus.jp/docs/techinfo/DjVu3Spec.pdf),
  [djvu-rs](https://github.com/matyushkin/djvu-rs),
  [DjVuLibre](https://github.com/DjVuLibre/DjVuLibre)
- O Calibre oferece documentação e leitores para eReader, Plucker e LRF, mas
  seu código é GPL-3.0. Usá-lo para comparar resultados não implica copiar sua
  implementação para o Unseal. — [Calibre](https://github.com/kovidgoyal/calibre),
  [parser LRF](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/ebooks/lrf/lrfparser.py)
- O eReader PDB inclui variantes de cabeçalho, compressão, PML e recursos, além
  de campos relacionados a DRM. A implementação atual se limita a arquivos
  sem DRM e identifica a variante antes de ler registros.
  — [formato eReader](https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/ereader.txt)
- O Plucker combina texto e recursos em registros próprios; sua documentação e
  ferramentas originais geraram fixtures DOC/zlib, mas não foi localizada uma
  amostra real de outro produtor com licença inequívoca para inclusão imediata.
  — [formato Plucker](https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/plucker.html),
  [projeto Plucker](https://sourceforge.net/projects/plucker/)
- Um aviso de segurança do Calibre sobre extração eReader reforça a necessidade
  de limitar recursos e validar nomes antes de expô-los. Os limites de arquivo
  e descompressão do Unseal também devem valer para os novos formatos.
  — [aviso GHSA-vmfh-7mr7-pp2w](https://github.com/kovidgoyal/calibre/security/advisories/GHSA-vmfh-7mr7-pp2w)

## 4. Comparativo

| Formato | Base principal | Arquivo de teste viável | Decisão de escopo |
|---|---|---|---|
| KEPUB | Parser EPUB atual + diretrizes Kobo | KEPUB real da Standard Ebooks; EPUB convertido com Kepubify | Validar detecção, conteúdo, recursos e navegação antes de criar código específico |
| Markdown | CommonMark + `package:markdown` | Suíte CommonMark e livro Markdown próprio | Delimitar HTML, front matter e imagens relativas |
| RTF | Especificação Microsoft | `LICENSE.rtf` e casos gerados | Extrair texto, estilos e metadados antes de imagens complexas |
| CHM | ITSF, MS-PATCH E8, CHMLib e IDs de codepage da Microsoft | Manual PuTTY licenciado e CHMs gerados em CP1251/1252/1256 | Implementado: HTML, recursos, sumário, E8 e codepages cobertas com limites; índice de busca e ajudas mescladas pendentes |
| DjVu | Especificação DjVu 3 + tabelas ZP cross-checkadas com djvu-rs (MIT) | Página JPEG gerada; camada Sjbz real de fixture pública federal dos EUA; IW44 Unlicense para rejeição | JPEG direto e máscara JB2 page-local são exibidos; JB2 sai como BMP 1-bit. IW44, composição de camadas, dicionários compartilhados e indiretos permanecem rejeitados |
| PDB | Especificação por subtipo no Calibre e PyPlucker | PalmDOC e eReader gerados; Plucker DOC/zlib gerado por ferramenta independente | PalmDOC, eReader e Plucker têm parsers distintos com contratos limitados |
| LRF | Parser Calibre como oráculo; Sony para o contexto BBeB | LRF de texto/imagem gerados por Calibre 9.4.0 e variantes sintéticas; writer Eruditio Apache-2.0 avaliado e rejeitado por incompatibilidade | Versões até 800 são cobertas sinteticamente; segue faltando amostra redistribuível válida de outro produtor |
| LRX | Sony sobre BBeB sem proteção/Marlin e OpenMG; Calibre como oráculo limitado de metadados | LRX2 sintético com região de metadados plaintext; nenhum livro protegido redistribuído | Metadados LRX2 apenas; conteúdo DRM é sempre rejeitado |

## 5. Resultado da implementação

KEPUB foi validado pelo caminho EPUB. Markdown, RTF, PalmDOC, eReader,
Plucker, CHM e LRF têm parsers públicos com testes e limites documentados.
LRX2 expõe apenas metadados plaintext; Unseal rejeita o conteúdo protegido.
DjVu abre páginas JPEG diretas e máscaras JB2 page-local (símbolos diretos,
refinamento e cópia local), geradas como BMP 1-bit. IW44 e páginas compostas
continuam falhando de modo tipado. Cada documento também respeita limites
cumulativos de 256 milhões de pixels decodificados e 128 MiB de raster
materializado. O detalhamento de cada contrato está em
[format-expansion.md](format-expansion.md).

## 6. Perguntas em Aberto / Fora do Escopo

- Testar, se houver uma amostra redistribuível, um KEPUB produzido pela própria
  Kobo. A edição independente da Standard Ebooks já está no corpus.
- Encontrar LRF redistribuível válido produzido por outra ferramenta ou por um
  dispositivo Sony. O writer Eruditio em `c517504` foi compilado e testado, mas
  seus objetos `BookAttr` não passam no leitor Calibre 9.4.0 nem no Unseal; o
  corpus real-world desse commit não contém LRF. A amostra de Yosemite não
  informa a licença do arquivo e seu download foi bloqueado pelo navegador.
  As variantes legadas atuais são sintéticas e estão descritas em
  `test/resources/books/lrf/PROVENANCE.md`.
- Encontrar Plucker real redistribuível de outro produtor; as amostras geradas
  atuais estão identificadas com sua proveniência.
- Encontrar amostras CHM redistribuíveis para codepages fora de 1251/1252/1256;
  os casos existentes são gerados a partir de texto original.
- Encontrar um CHM redistribuível com a flag Intel E8 ligada. O CHM PuTTY real
  atual tem a flag E8 desligada no cabeçalho do primeiro fluxo LZX; os testes
  E8 continuam usando quadros sintéticos. O compressor `paslzxcomp` do Free
  Pascal também declara que sempre grava zero para essa flag, então não serve
  para gerar essa evidência. — [PuTTY fixture e hash](../test/resources/books/manifest.json),
  [fonte `paslzxcomp.pas` do Free Pascal](https://gitlab.com/freepascal.org/fpc/source/-/blob/dcb91d0b52/packages/chm/src/paslzxcomp.pas),
  [regra Microsoft MS-PATCH E8](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-patch/e6c8366d-a8c3-4f34-aa5d-56f44f938a09).
- Implementar IW44 e composição de camadas antes de ampliar a promessa de
  leitura de páginas DjVu compostas; completar dicionários JB2 compartilhados,
  reset, TXTz/NAVM e componentes de documentos indiretos.

---
**Próximo passo:** expandir os casos reais e os codecs pendentes sem retirar os
limites e erros tipados dos contratos atuais.
