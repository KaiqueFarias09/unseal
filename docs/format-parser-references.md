---
feature: Referências para novos formatos de leitura
slug: format-parser-references
version: 1.0
status: draft
generated: 2026-09-23
---

# Referências para parsers e arquivos de teste

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
  também pode produzir amostras pequenas de conteúdo próprio. Antes de copiar
  o manual, conferir a licença e registrar origem e hash da versão escolhida.
  — [amostra CHM](https://github.com/bjxpen/chmv/tree/main/test/fixtures),
  [chmcmd](https://gitlab.com/freepascal.org/fpc/source/-/blob/bce88f2e2bf76c3f979902aaa60598a0487f1509/packages/chm/src/chmcmd.lpr)
- Para DjVu, as ferramentas DjVuLibre permitem gerar páginas com conteúdo
  próprio e conferir texto, índices e imagens. Ainda falta selecionar uma
  amostra real redistribuível para testar variantes externas. — [djvumake](https://djvu.sourceforge.net/doc/man/djvumake.html),
  [djvused](https://djvu.sourceforge.net/doc/man/djvused.html)
- O Calibre documenta a conversão para eReader PDB e LRF, e oferece `lrf2lrs`
  como validador auxiliar. Amostras geradas de texto próprio são possíveis,
  mas não substituem arquivos reais com proveniência independente.
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
  de campos relacionados a DRM. Uma primeira implementação deve se limitar a
  arquivos sem DRM e identificar essa variante antes de ler registros.
  — [formato eReader](https://github.com/kovidgoyal/calibre/blob/master/format_docs/pdb/ereader.txt)
- O Plucker combina texto e recursos em registros próprios; sua documentação e
  ferramentas originais ajudam a gerar fixtures, mas não foi localizada uma
  amostra real com licença inequívoca para inclusão imediata.
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
| CHM | ITSF + jchmlib | Manual PuTTY licenciado e casos `chmcmd` | Navegação e HTML com LZX e limites de descompressão |
| DjVu | Especificação DjVu 3 + DjVuLibre | Casos gerados; amostra real ainda pendente | Texto/estrutura não equivale a suporte visual completo |
| PDB | Especificação por subtipo no Calibre | PalmDOC gerado; eReader/Plucker reais pendentes | Identificar criador/tipo; não tratar todo PDB como PalmDOC |
| LRF | Parser e ferramentas Calibre | LRF gerado; arquivo real com licença pendente | Adiar suporte público até validar em corpus independente |

## 5. Recomendação para o MVP

Priorizar a validação de KEPUB com um arquivo real da Standard Ebooks e um
arquivo convertido por Kepubify. Markdown avulso e RTF têm especificações e
testes suficientes para suporte incremental em Dart puro, desde que o contrato
declare os recursos realmente preservados. CHM pode vir depois com uma amostra
real e limites de LZX; eReader PDB sem DRM é a próxima variante PDB plausível.
Manter DjVu visual, Plucker e LRF condicionados a corpus independente e demanda
medida, pois exigem implementações e validação próprias.

## 6. Perguntas em Aberto / Fora do Escopo

- Baixar e registrar versão, hash, licença e proveniência de cada candidato
  antes de incorporá-lo a `test/resources/`. A pesquisa não adicionou binários.
- Confirmar a situação de direitos da edição KEPUB escolhida no local de
  redistribuição, inclusive capa e demais recursos.
- Encontrar arquivos reais redistribuíveis de eReader PDB, Plucker, DjVu e LRF;
  enquanto isso, manter seus casos gerados identificados como tal.
- Definir a demanda que justificaria os codecs visuais de DjVu e o parser LRF.
- Escolher explicitamente o subconjunto de RTF e as extensões de Markdown que
  a API pública prometerá preservar.

---
**Próximo passo:** usar esta pesquisa como base para requisitos por formato e
registrar os limites e os testes mínimos antes de ampliar a API pública.
