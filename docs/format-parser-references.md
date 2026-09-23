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
KEPUB, Markdown, RTF, CHM, DjVu, PDB e LRF. O objetivo é decidir quais formatos
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
- CHM tem documentação do contêiner ITSF e um leitor em Java puro sob Apache 2.0;
  ambos servem de base para estudar diretório, tópicos e dados comprimidos.
  — [CHM ITSF](https://www.nongnu.org/chmspec/latest/ITSF.html),
  [jchmlib](https://github.com/chimenchen/jchmlib)
- PDB é um contêiner com subformatos distintos. PalmDOC, eReader, Plucker e MOBI
  têm estruturas próprias; MOBI deve seguir o parser MOBI, enquanto eReader e
  Plucker exigem implementação separada. — [documentação PDB do Calibre](https://github.com/kovidgoyal/calibre/tree/master/format_docs/pdb)

### 3.2 Arquivos de teste e conformidade

- A Standard Ebooks oferece KEPUBs produzidos para Kobo, inclusive *The Red
  Badge of Courage*. É um candidato a teste com arquivo real, distinto do KEPUB
  gerado de uma amostra EPUB pelo Kepubify. Conferir direitos da edição e de
  cada componente antes de incluí-lo no repositório. — [edição](https://standardebooks.org/ebooks/stephen-crane/the-red-badge-of-courage),
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
- Para DjVu, as ferramentas DjVuLibre permitem gerar páginas com conteúdo
  próprio e conferir texto, índices e imagens. O corpus inclui uma página JPEG
  gerada e duas amostras reais com JB2/IW44 e licença registrada; estas últimas
  verificam a rejeição tipada dos codecs ainda ausentes. — [djvumake](https://djvu.sourceforge.net/doc/man/djvumake.html),
  [djvused](https://djvu.sourceforge.net/doc/man/djvused.html)
- O Calibre documenta a conversão para eReader PDB e LRF, e oferece `lrf2lrs`
  como validador auxiliar. As amostras foram geradas a partir de conteúdo
  próprio; arquivos de outros produtores ainda ampliariam a validação LRF.
  — [ebook-convert](https://manual.calibre-ebook.com/generated/en/ebook-convert.html),
  [lrf2lrs](https://manual.calibre-ebook.com/generated/en/lrf2lrs.html)

### 3.3 Escopo, licenças e segurança

- Suporte a DjVu com páginas visuais requer mais que extrair texto: a
  especificação cobre camadas de imagem comprimidas, e o DjVuLibre é uma
  implementação GPL que pode servir de oráculo de testes. — [especificação DjVu 3](https://www.epapyrus.jp/docs/techinfo/DjVu3Spec.pdf),
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
| CHM | ITSF + jchmlib | Manual PuTTY licenciado e casos pequenos gerados | Implementado: HTML, recursos, sumário e LZX com limites; índice de busca e ajudas mescladas pendentes |
| DjVu | Especificação DjVu 3 + DjVuLibre | Página JPEG gerada; dois arquivos reais licenciados com JB2/IW44 para testar rejeição | Páginas JPEG diretas funcionam; JB2/IW44 ainda exigem decodificadores visuais |
| PDB | Especificação por subtipo no Calibre e PyPlucker | PalmDOC e eReader gerados; Plucker DOC/zlib gerado por ferramenta independente | PalmDOC, eReader e Plucker têm parsers distintos com contratos limitados |
| LRF | Parser e ferramentas Calibre | LRF de texto e imagem gerados por Calibre 9.4.0 | Leitura pública limitada; falta amostra de outro produtor |

## 5. Resultado da implementação

KEPUB foi validado pelo caminho EPUB. Markdown, RTF, PalmDOC, eReader,
Plucker, CHM e LRF têm parsers públicos com testes e limites documentados.
DjVu abre páginas com JPEG direto e falha de modo tipado para as camadas
JB2/IW44. O detalhamento de cada contrato está em
[format-expansion.md](format-expansion.md).

## 6. Perguntas em Aberto / Fora do Escopo

- Incluir KEPUB produzido independentemente pelo ecossistema Kobo, após
  conferir os direitos da edição e de seus recursos.
- Encontrar LRF e Plucker reais redistribuíveis de outros produtores;
  as amostras geradas estão identificadas com sua proveniência.
- Implementar JB2/IW44 antes de ampliar a promessa de leitura visual DjVu.
- Cobrir variantes CHM Intel E8 e codepages antigas com arquivos licenciados.

---
**Próximo passo:** expandir os casos reais e os codecs pendentes sem retirar os
limites e erros tipados dos contratos atuais.
