---
feature: Cinco campanhas paralelas do Unseal
slug: unseal-parallel-campaigns
version: 1.0
status: ready-for-implementation
generated: 2026-10-16
---

# Plano de implementação com cinco agentes

Este é o contrato de execução de R1/R3, R6, R7 e R10 do
[roadmap](roadmap.md), que continua sendo o único backlog. O plano foi
conferido no código de `01d5027`. As funcionalidades descritas aqui são futuras;
nenhuma faz parte do contrato publicado apenas por aparecer neste documento.

## 1. Como usar este plano

O coordenador prepara cinco worktrees a partir do commit da `main` que contém
este plano. Cada agente lê as seções 1 a 3, sua missão na seção 4 e as seções
5 a 8. Ele implementa somente a missão atribuída e entrega commits nessa
branch. O coordenador revisa os pontos compartilhados e a combinação final.

| Agente | Branch | Missão | Primeiro trabalho independente |
| --- | --- | --- | --- |
| A01 | `codex/unseal-pdf-structure` | PDF estruturado e posições estáveis | Contrato comum de snapshots, seguido de geometria e corpus PDF. |
| A02 | `codex/unseal-indexed-search` | Busca indexada | Tokenização, postings, ranking e testes com texto explícito. |
| A03 | `codex/unseal-rar5` | RAR5 comprimido | Comparador de bytes, cabeçalhos e decoder. |
| A04 | `codex/unseal-jpeg2000` | JPEG2000 e integração PDF | Comparador OpenJPEG e decoder isolado. |
| A05 | `codex/unseal-durable-annotations` | Anotações duráveis e intercâmbio W3C | Seletores, ambiguidade e migração com texto explícito. |

O paralelismo é de desenvolvimento. Busca e anotações dependem do contrato
comum para a integração definitiva; persistência em PDF depende também do
mapeamento entregue por A01. RAR5 e JPEG2000 não dependem desses marcos.

Antes de editar, cada agente deve conferir `git status --short`, o commit-base,
[AGENTS.md](../AGENTS.md), [arquitetura](architecture.md) e a implementação
indicada na sua missão. Prefira o grafo MCP para descobrir código, quando
disponível, e confirme os contratos relevantes no código atual.

### Preparação das worktrees pelo coordenador

Execute somente depois de commitar a preparação e conferir a árvore limpa.
Registre o SHA impresso como base de todas as missões. Os comandos criam novas
branches; se alguma já existir, inspecione e reutilize o trabalho existente.

```sh
(
set -eu
git switch main
test -z "$(git status --porcelain)"
BASE=$(git rev-parse HEAD)
printf '%s\n' "$BASE"
git worktree add -b codex/unseal-pdf-structure ../unseal-work-pdf "$BASE"
git worktree add -b codex/unseal-indexed-search ../unseal-work-search "$BASE"
git worktree add -b codex/unseal-rar5 ../unseal-work-rar5 "$BASE"
git worktree add -b codex/unseal-jpeg2000 ../unseal-work-jpeg2000 "$BASE"
git worktree add -b codex/unseal-durable-annotations ../unseal-work-annotations "$BASE"
)
```

Use caches, relatórios e clones de referência separados por worktree ou fora
do checkout. Cada agente instala as dependências no seu checkout com
`dart pub get --no-example`. Nenhum agente troca a branch da worktree alheia.

## 2. Contratos compartilhados congelados

Os requisitos C01 a C09 são normativos. Os nomes da proposta abaixo orientam a
implementação; ainda não são APIs disponíveis. O coordenador registra qualquer
mudança de campo, unidade ou semântica nesta seção antes de integrar consumidores.

### C01. Preservação do comportamento atual

`Book.search`, `TextLocator`, os codecs v1 de locators/anotações e
`relocateTextLocator` continuam compatíveis. A busca existente mantém sua
gramática e ordem; a relocação existente mantém seus desempates. APIs novas
separam ranking, ambiguidade e revisão. Não acrescente uma variante a
`BookLocator` sem avaliar os consumidores com switches exaustivos.

O texto produzido por `documentTextOf` é o espaço canônico atual. Preserve
espaços, entidades, separadores e comportamento histórico do scanner. Melhorias
que alterem esse texto exigem outro perfil e migração explícita. Normalização
de busca usa um mapa de projeção para o texto original.

### C02. Identidade, revisão e ocorrência

O contrato comum terá os seguintes valores imutáveis, sem dependência de PDF:

| Valor proposto | Campos e invariantes |
| --- | --- |
| `PublicationRevision` | `publicationId` opaco com namespace, `editionId` opcional, `sourceRevision` opcional e sua origem de verificação. Identidade lógica e revisão exata são informações diferentes. |
| `SectionOccurrence` | `sectionIndex` zero-based, `resourcePath` exato do parser e `readingOrderRevision`. O mesmo caminho repetido produz ocorrências distintas. |
| `CanonicalTextSnapshot` | Identidade, ocorrência, `textProfileId`, `textRevision`, `text` e comprimento UTF-16 derivado. O perfil inclui algoritmo, opções relevantes e revisão do plano de extração. |
| `CanonicalTextRange` | Identidade do snapshot, `start` inclusivo e `end` exclusivo. Deve validar `0 <= start <= end <= text.length`. Um ponto usa `start == end`. |

Identidade desconhecida continua desconhecida. Título, ISBN, nome de arquivo,
caminho e hash de um prefixo não comprovam revisão dos bytes. Uma revisão
`sha256:` corresponde ao arquivo original completo. Uma revisão fornecida pelo
host precisa declarar seu namespace e a garantia de não reutilização para
conteúdo diferente. Evidência opaca do host não vira hash verificado pelo parser.

Abrir uma sessão não passa a exigir hash completo do arquivo. A captura de
snapshot ocorre explicitamente sobre texto materializado. Sem evidência
suficiente, trabalho em memória é permitido; exportação para reutilização
automática deve falhar de forma explícita ou exigir verificação antes do uso.
Anotações importadas sem identidade suficiente podem servir para recuperação
por contexto, mas não recebem status de posição verificada.

`textRevision` usa SHA-256 dos code units UTF-16 little-endian, sem BOM e sem
normalização. Isso preserva inclusive surrogates isolados existentes na entrada.
`readingOrderRevision` usa SHA-256 da mesma codificação UTF-16LE aplicada ao
JSON compacto do array ordenado `[[resourcePath, isHtml], ...]`. A posição no
array identifica a ocorrência; duplicatas são preservadas. A01 implementa
esses helpers uma única vez, com vetores de bytes e hashes fixos para VM/web.
O schema do snapshot e o perfil textual também participam da comparação de
compatibilidade; um digest de texto igual sozinho não certifica a mesma edição.

Schema inicial: `schemaVersion = 1`. A identidade persistente do snapshot é a
tupla `(schemaVersion, publicationId, editionId, sourceRevision, sourceEvidence,
readingOrderRevision, sectionIndex, resourcePath, textProfileId, textRevision)`.
Compare os campos, incluindo nulls explícitos; identidade de objeto em memória
ou só o digest textual não bastam. `sourceEvidence` distingue `unverified`,
`host` e `sha256`. O codec único P0 preserva essa tupla e revalida ranges e
digest contra o texto/snapshot de destino. Uma flag importada de verificação
é uma alegação, não prova: o contexto de destino deve confirmá-la. Nulls iguais
permitem representar estado desconhecido, mas não concedem reuso verificado.

### C03. Unidades e compatibilidade dos intervalos

Offsets internos são code units UTF-16, não bytes, runes, graphemes ou tokens.
Texto astral ocupa dois code units. Um intervalo sempre se refere a uma
ocorrência de um snapshot, e não ao livro inteiro concatenado.

Reuso direto exige identidade/revisões/perfil compatíveis, texto verificado e
limites válidos. Campos ausentes não são curingas. Reordenação de capítulos,
mudança de perfil ou revisão diferente exige reconstrução ou migração explícita.
Seletores W3C contam Unicode code points em texto normalizado e em ordem lógica,
conforme a [especificação](https://www.w3.org/TR/annotation-model/#text-position-selector).
O adaptador precisa de projeção entre esse texto e o canônico; UTF-16 não é a
unidade externa. Validade de range não comprova fronteira de grapheme ou de
surrogate: conversões impossíveis devem informar não suporte, sem deslocar o alvo.

### C04. PDF, geometria e mapeamento

A01 é responsável por fonte estável e mapeamento, inclusive no PDF com mais de
20 páginas. O modo completo atual usa estatísticas de todas as páginas; a sessão
usa amostra inicial. Não atribua a ambos a mesma revisão por conveniência.

O novo modelo PDF distingue âncora da fonte, texto canônico e ordem de leitura.
Uma âncora da fonte é estável para a mesma revisão do arquivo e do extrator;
ela não é um offset derivado do reflow. O mapeamento retorna `mapped`,
`ambiguous`, `missing` ou `unsupported`, com motivo. Mudança de revisão é
incompatibilidade, salvo migração explicitamente solicitada.

Geometria usa pontos da página recortada e rotacionada, com origem no canto
superior esquerdo, dimensões declaradas e transformação afim invertível para
as coordenadas PDF de origem. Preserve quadriláteros e direção quando caixas
axis-aligned perderem informação. Página e seção usam índices zero-based na API;
nomes existentes como `page_1.html` preservam sua convenção de recurso.

Palavras derivam dos runs/glyphs e métricas do extrator. Dividir igualmente a
largura de uma linha não comprova geometria de palavras. Tabelas referenciam
regiões e intervalos, sem reescrever silenciosamente o texto canônico existente.
Texto nativo e OCR importado devem ter origem distinta; OCR não é executado aqui.

### C05. Busca, cobertura e persistência

O índice informa schema, versões/opções de tokenização e normalização,
identidade, ordem e revisões textuais. Postings preservam ocorrência e ranges
originais. Empates de ranking são determinísticos: score decrescente, ocorrência
crescente, início crescente e fim crescente.

Cobertura distingue ocorrências elegíveis, indexadas e pendentes/com falha.
`complete` exige todas as elegíveis indexadas sem lacunas. `isTruncated`
continua significando corte de resultados, não cobertura. Consulta vazia ou sem
hits sobre índice parcial não prova ausência no livro. Importação valida limites,
schema e revisões antes de confiar em postings. Índice obsoleto não retorna hits
com aparência de válidos; rejeita ou reconstrói de maneira observável.

### C06. Anotações e ambiguidade

O envelope novo guarda identidade/revisões, ocorrência, intervalo, citação e
contexto. A API nova distingue `resolved`, `ambiguous`, `missing`,
`incompatibleRevision` e `unsupported`. Ela retorna evidências e candidatos
quando necessário. Empate indistinguível permanece ambíguo, mesmo quando um
candidato aparece antes no livro. Migração entre edições é uma operação explícita.

Os codecs v1 e o helper antigo continuam independentes. O novo adaptador W3C
declara seu subconjunto; preservar campos desconhecidos ou rejeitar recursos
não suportados precisa ser explícito. Não anuncie conformidade Readium completa
por ter reutilizado ideias de locators ou posições.

### C07. Limites, erros e ciclo de vida

Cada feature declara defaults finitos e limites configuráveis antes de alocar.
Inclua trabalho intermediário: tokens/postings, candidatos, tabelas, dicionários,
coeficientes, tiles, buffers de cor e mensagens em trânsito. Valide aritmética
também no JavaScript. Reutilize políticas existentes onde a unidade coincidir;
limite de saída não substitui orçamento de memória de trabalho.

Input corrompido dos codecs normaliza para `ComicException`/`PdfException` nas
fronteiras públicas. Preserve erros documentados de consultas inválidas nas APIs
existentes. APIs novas distinguem argumento inválido, revisão incompatível,
limite excedido, cancelamento e descarte, com round trip no worker.

Cancelamento de entrega não comprova interrupção de CPU. Construção incremental
do índice deve ceder execução em lotes limitados e comprovar parada. Codecs
síncronos precisam de limites de trabalho; não prometem preempção instantânea.
Descarte libera recursos e invalida pedidos futuros. Duas sessões são isoladas.

### C08. Fronteiras e wire

Features dependem de foundation. Unseal permanece Dart puro, sem executável
nativo, Flutter, rede ou banco obrigatórios. Programas externos são oráculos de
desenvolvimento. Persistência, HTTP, interface e reprodução são dos consumidores.

A01 implementa os valores C02/C03 em `lib/src/foundation/text/` num commit inicial
P0 revisável, sem dependências de feature e com testes de conformidade. Exporta
somente tipos completos usados por consumidores reais da campanha. A02/A05
desenvolvem seus núcleos com strings/entradas privadas explícitas enquanto P0 é
revisado. Depois atualizam suas branches pela `main` com P0 e usam a implementação
única; eliminam adaptadores temporários duplicados antes da entrega.

Reserve os prefixos lógicos `pdfLayout.*` para A01 e `searchIndex.*` para A02.
A01/A02 traduzem-nos para as convenções reais do dispatcher sem alterar operações
existentes. A05 começa com API pura sobre snapshots; só acrescenta operações
remotas se necessárias ao caso público, usando `annotationAnchor.*`.
Payloads de transporte são privados, versionados e structured-clone-safe.
Mudanças do envelope global de wire passam pelo coordenador. RAR5/JPEG2000
continuam retornando recursos binários e não precisam de campos geométricos novos.

### C09. Decisão de arquitetura

Foram comparadas duas estruturas: tipos comuns de runtime já nesta preparação,
e serviços por feature com protocolo comum normativo. A segunda é a base deste
plano: mantém a preparação documental e introduz código quando houver consumidor.
Da primeira foram incorporados o snapshot imutável, ranges vinculados e a
implementação única de revisão/validação. P0 evita cinco interpretações do contrato.

Rejeitamos alterar `Book`/locator v1 de forma abrangente e uma hierarquia universal
de geometria/OCR antecipada. O modelo espacial fica em PDF até existir outro
consumidor concreto. Aceitamos uma dependência inicial P0 em troca de evitar APIs
sem implementação e DTOs duplicados. A comparação e a revisão independente
convergiram na preparação documental com esse marco explícito.

### Uso pretendido, não executável na versão atual

As fachadas devem ocultar carregamento, projeção e transporte. O usuário não
monta payloads de worker nem calcula hashes manualmente. Os nomes abaixo são
esboços; C01 a C08 fixam a semântica que suas assinaturas precisam preservar.

```dart
// A02: API aditiva, sem mudar Book.search.
final index = await BookSearchIndex.build(book, identity: sourceIdentity);
final results = index.query('navegacao', mode: IndexedQueryMode.prefix);
final locator = results.hits.first.toTextLocator();
// A05: a mesma família de snapshots sustenta captura e resolução.
final anchor = DurableAnnotations.capture(book, locator, identity: sourceIdentity);
final outcome = DurableAnnotations.resolve(anchor, revisedBook,
    identity: revisedIdentity, policy: AnchorPolicy.explicitMigration);
// A01: estrutura preserva fonte e mapeia para o perfil canônico solicitado.
final page = await session.loadPdfPageStructure(24);
final mapping = page.mapSourceRange(savedSourceRange);
```

## 3. Propriedade dos arquivos e marcos de integração

| Área | Responsável | Regra de colaboração |
| --- | --- | --- |
| `foundation/text/` do contrato novo e seus vetores | A01 em P0 | Coordenador revisa antes de A02/A05 integrarem; scanner atual permanece compatível. |
| PDF entidades, runs, layout, reflow e geometria/wire | A01 | Não absorve o codec JPEG2000. |
| Novo índice em `features/search/` e seu wire | A02 | Não redesenha o texto canônico nem os perfis PDF. |
| `features/comic/archive/`, decoder RAR5 | A03 | Um decoder comum aos caminhos eager e sessão. |
| `features/pdf/codec/jpeg2000/` e adaptador de imagem | A04 | Só o hunk de dispatch de `decodePdfImageStream` é reservado em `pdf_content_stream.dart`; A01 cuida dos demais hunks de texto. |
| `features/annotations/`, seletores e novos adapters de locator | A05 | Preserva os contratos v1 e consome P0. |
| `session_engine.dart`, transports, worker switches e exports | Agente da operação + coordenador | Mudanças pequenas e aditivas, separadas do algoritmo; revisão conjunta dos hunks sobrepostos. |
| README, changelog, guias, roadmap, notices e manifests | Cada agente na sua feature | Coordenador reconcilia a união, preserva licenças e remove somente escopo comprovadamente entregue. |

P0 contém contrato comum implementado e vetores, mas nenhum stub de busca/layout.
O coordenador pode integrar esse commit isolado antes do restante de A01. Enquanto
isso, outros agentes avançam com seus próprios núcleos e fixtures. Para incorporar
P0, preferir atualizar pela `main`; registrar qualquer cherry-pick para evitar
aplicar o mesmo patch duas vezes na integração.

P1 é a estabilidade/mapeamento PDF. A02/A05 podem entregar comportamento seguro
para EPUB antes de P1, documentando restrição PDF. A campanha completa só termina
depois do aceite combinado de PDF da seção 7. Um adaptador que sempre responde
`unsupported` não satisfaz a entrega de persistência PDF.

## 4. Missões dos agentes

Todos os requisitos abaixo têm prioridade alta na entrega delimitada. Etapas
internas não são autorização para declarar a missão completa pela metade.

### A01. PDF estruturado e posições estáveis

Objetivo: expor palavras, blocos, colunas, ordem e tabelas com geometria verificável,
e resolver a dependência de posições entre extração completa e progressiva.

Base de port: [PdfPig em C#](https://github.com/UglyToad/PdfPig/tree/3452b9fb52440202fa30b8dd8bf57c5186f8de29),
Apache-2.0, sobretudo `UglyToad.PdfPig.DocumentLayoutAnalysis`: word extraction,
Docstrum/segmentação e leitura de blocos. Para tabelas,
[Tabula Java](https://github.com/tabulapdf/tabula-java/tree/2cdf3b4fd3f7e921dca8cc6814cdd9316be40f0f),
MIT, com `BasicExtractionAlgorithm` e `SpreadsheetExtractionAlgorithm`.
Reutilizar algoritmos sobre o parser existente; não portar outro parser PDF inteiro.

Comece por `pdf_page_text.dart`, `PdfTextExtractor` em `pdf_content_stream.dart`,
`pdf_reflow.dart`, `pdf_session_header.dart` e `SessionEngine._pdfMaterialize`.
Descubra os caminhos pelo grafo: os nomes de módulos são pontos de partida,
não garantia de que um arquivo permanecerá no mesmo lugar.

| ID | Entrega obrigatória | Critério de aceite |
| --- | --- | --- |
| PDF01 | P0 de C02/C03 com tipos imutáveis, validação e codec compartilhado. | Vetores fixos dão os mesmos hashes/ranges no VM e Chrome; ocorrência repetida é distinta; revisão incompatível é recusada. |
| PDF02 | Runs/glyphs, palavras e blocos com origem e transformação. | Fixtures rotacionadas, ligaturas e fontes distintas têm palavras/regiões corretas, sem largura inventada a partir da linha. |
| PDF03 | Ordem de leitura e colunas, distinguindo metadados editoriais. | Páginas anotadas independentemente validam sequência esperada, incluindo cabeçalho, rodapé e duas colunas. |
| PDF04 | Tabelas simples com e sem linhas, células e ranges/regions. | O corpus contém ambos os tipos; células, ordem e limites coincidem com a expectativa humana. Casos não suportados têm diagnóstico explícito. |
| PDF05 | Âncora estável da fonte e mapeamento para texto canônico. | PDF variado com mais de 20 páginas, com mudanças estatísticas depois da amostra, preserva o alvo ao reabrir/trocar modo ou retorna ambiguidade real. Para casos inequívocos exigidos, o alvo resolve corretamente. |
| PDF06 | API pública, eager/sessão e wire com o mesmo modelo. | Texto de linhas retornadas corresponde ao snapshot declarado; chamadas inline/isolate/worker preservam geometria, revisões e falhas. |

Sequência: P0 isolado; capturar evidência dos runs; segmentar palavras/blocos;
ordenar colunas; detectar tabelas; estabilizar/mapear posições; integrar sessão/wire.

Testes mínimos: `test/tests/pdf/`, `test/tests/progressive/pdf_session_test.dart`,
`test/tests/core/document_text_edge_cases_test.dart` e
`test/web/session_pdf_cbr_worker_test.dart`. Acrescentar vetores P0, goldens de
layout anotados e casos acima de 20 páginas. Criar um comparador de layout que
falhe quando o oráculo obrigatório faltar e registre diferenças, em vez de
exigir igualdade cega com heurísticas do PdfPig. Expectativa humana decide ordem
correta quando o oráculo também divergir. Usar pelo menos um PDF independente
e licenciado além dos documentos gerados para fronteiras exatas.

Fora desta missão: renderização PDF, OCR executável/modelos, JPEG2000 e geometria
universal para todos os formatos. Documentar as limitações de tabelas e layout.

### A02. Busca indexada por publicação

Objetivo: consultas repetidas, prefixo, tolerância a erros e ranking sem perder
o vínculo entre resultado e caracteres do livro.

Base de port: [MiniSearch em TypeScript](https://github.com/lucaong/minisearch/tree/3d239d1c3ae7aef1bf5d8945dd7b5f0709f646f5),
MIT, incluindo `SearchableMap` e [design do índice](https://github.com/lucaong/minisearch/blob/3d239d1c3ae7aef1bf5d8945dd7b5f0709f646f5/DESIGN_DOCUMENT.md).
[Tantivy em Rust](https://github.com/quickwit-oss/tantivy/tree/e1acb3e0112f2b4819946aa4ea5742bf429853d8),
MIT, serve para postings/posições/BM25 e schema. Portar o núcleo necessário;
o runtime Dart não executa JavaScript nem depende de um servidor de busca.

Leia `book_search.dart`, `query_compiler.dart`, `search_match.dart`,
`search_results.dart` e os caminhos de busca de `BookSession`/`SessionEngine`.

| ID | Entrega obrigatória | Critério de aceite |
| --- | --- | --- |
| IDX01 | Índice invertido opcional com postings por ocorrência e projeção. | Hits recortam o texto original correto em português, texto astral, combinações Unicode, hífens e caminhos repetidos. |
| IDX02 | Ranking BM25 ou BM25+, prefixo e fuzzy com distância/trabalho limitados. | Corpus de consultas com expectativa fixa valida ranking, distância e desempate; consulta adversarial atinge limite explícito, sem travar. |
| IDX03 | Construção incremental e cobertura de C05. | Consultas antes/durante/depois da construção distinguem cobertura parcial e corte de hits; cancelamento para trabalho observável em lotes finitos. |
| IDX04 | Serialização/importação versionada. | Reabrir mantém resultados; mudar texto, ordem, tokenizer, perfil ou revisão invalida o índice. Entrada hostil é rejeitada antes de alocações excessivas. |
| IDX05 | Adapters `Book`/sessão e ciclo de vida. | Não indexa placeholders do header; duas sessões não misturam índices; dispose libera estado; wire real preserva cobertura, ranking e ranges. |
| IDX06 | Compatibilidade e medição. | A suíte antiga permanece igual; relatório reproduzível compara construção, consultas quentes, tamanho, memória e falhas em VM/browser. |

Antes de P0, implemente estruturas puras com entradas privadas de texto explícito.
Depois integre o contrato único. Antes de P1, PDF persistido deve ser recusado ou
restrito ao snapshot comprovado; o aceite completo usa o cenário combinado.

Testes mínimos: `test/tests/core/book_search_test.dart`,
`test/tests/locators/search_locator_test.dart`, `test/public_search_api_test.dart`,
`test/web/book_search_unicode_test.dart`, novas suítes de índice e sessão/worker.
Compare queries da API nova com uma busca ingênua independente da mesma gramática.
Quando declarar equivalência com um modo antigo, compare os mesmos parâmetros.
Uma consulta por token não equivale automaticamente a `contains` por substring.

Benchmark: livros pequenos e grandes, consultas raras/comuns/inexistentes,
acentos/prefixo/fuzzy, índice frio e quente. Reutilize
`benchmark/document_text_search_benchmarks.dart` e o protocolo do guia de
desenvolvimento. Relate o custo de construção e a memória além de ganhos quentes.

Fora desta missão: catálogo persistente de toda a biblioteca, banco de dados,
embeddings, serviços de rede e mudança do scanner canônico.

### A03. RAR5 comprimido para CBR

Objetivo: abrir quadrinhos com entradas RAR5 comprimidas nos caminhos completo
e progressivo, com saída íntegra e limites anteriores à descompressão.

Base de port: [rardecode em Go](https://github.com/nwaples/rardecode/tree/ad22ba91a2ab0d3ff6bca20cd978b33ee78faab1),
BSD-2-Clause, especialmente `archive50.go`, `decode50.go` e filtros associados.
Use [libarchive](https://github.com/libarchive/libarchive/tree/87dec938e1578901f4919faa76e5f541b4d145b1)
como segundo decoder independente; confira a licença de cada arquivo utilizado.
O cabeçalho de `archive_read_support_format_rar5.c` é uma referência de licença,
não autorização para assumir licença uniforme de todo o repositório.

Leia `rar_reader.dart`, `rar_random_access.dart`, `rar4_method29_decoder.dart`,
`parse_comic_book.dart` e o caminho de abertura do header CBR. O eager e a sessão
possuem parsers diferentes; ambos precisam chamar o mesmo decoder novo.

| ID | Entrega obrigatória | Critério de aceite |
| --- | --- | --- |
| RAR01 | Parser de cabeçalhos RAR5 validado, nomes UTF-8 e metadados de compressão. | Preserva versão, tamanho de dicionário, flags solid/split, presença de CRC e distinção entre CRC ausente e CRC igual a zero. |
| RAR02 | Streams LZ/Huffman não sólidos de volume único, algoritmo RAR5 versão 0 e métodos 1 a 5. | Exigir filtros `0=delta`, `1=E8`, `2=E8/E9`, `3=ARM`, conforme `decode50.go` fixado, com caso válido e corrompido por filtro. Dicionários declarados de 128 KiB até 64 MiB são cobertos dentro da política total. Saída real/gerada é byte-identical aos dois decoders. |
| RAR03 | CRC de cabeçalhos e dados quando presentes, tamanhos e limites. | Corrupções controladas, CRC zero válido, tamanhos divergentes, dicionários enormes e índices inválidos produzem falha tipada e limitada. |
| RAR04 | Integração eager e CBR sessão. | A mesma página possui bytes idênticos em abertura completa, pedidos fora de ordem, releitura e duas sessões em VM/Chrome. |
| RAR05 | Matriz explícita do subconjunto. | Solid, volumes divididos, criptografia, algoritmos posteriores, filtros fora de 0 a 3 e dicionários acima do limite são identificados e rejeitados; nunca passam pelo caminho não sólido. RAR4 existente não regride. |

Sequência: comparador e fixtures; metadados/checksums; decoder/filtros; integração
nos dois caminhos; ataques aos limites; documentação. Solid não é requisito desta
primeira entrega delimitada. Caso seja implementado, exige orçamento de histórico,
replay/cache limitado, pedidos fora de ordem e aceite adicional; caso contrário
permanece explicitamente no roadmap. Não anuncie suporte RAR5 completo.

Testes mínimos: `test/tests/comic/rar_test.dart`, `rar_random_access_test.dart`,
`test/tests/progressive/cbr_session_test.dart` e Chrome de sessão PDF/CBR.
Acrescente casos por filtro e corrupção, oráculo obrigatório e corpus licenciado
independente. Estenda `test/support/rar_fixtures.dart` para fronteiras sintéticas.

A abertura do header hoje pode inflar entradas para inspecionar a assinatura.
Meça e documente esse custo; chamar o container de random-access não comprova
descompressão lazy. Cancelamento deve descrever o comportamento efetivamente testado.

### A04. JPEG2000 e `JPXDecode`

Objetivo: recuperar pixels de imagens JPEG2000 suportadas e disponibilizá-las
como recursos PDF nos caminhos eager e sessão.

Base de port: [OpenJPEG em C](https://github.com/uclouvain/openjpeg/tree/8314119b067c0fc77834731168daaebd379fdb12),
BSD-2-Clause no [LICENSE inspecionado](https://github.com/uclouvain/openjpeg/blob/8314119b067c0fc77834731168daaebd379fdb12/LICENSE).
Estude `src/lib/openjp2/`: codestream, tier1/tier2, MQ, wavelets e conversão.
Portar decoder; ferramentas de encode/decode são oráculos de desenvolvimento.

Leia `decodePdfImageStream`, `decodePdfImageObject`, `_drawXObject`,
`SessionEngine._pdfResource` e `pdf_bitmap.dart`. `PdfBitmap` atual é 1bpp;
não o trate como buffer RGBA. O limite de imagens aplicado depois do decode
não limita o trabalho do codec.

| ID | Entrega obrigatória | Critério de aceite |
| --- | --- | --- |
| JPX01 | J2K e wrapper JP2, subconjunto Part 1 explícito. | Decodifica grayscale/RGB unsigned de 8 bits, 5/3 reversível e 9/7 irreversível, LRCP/RLCP, tile único e múltiplos tiles com bordas parciais. RGB cobre ausência de MCT, RCT e ICT padronizados, componentes 1:1. Cada variante aceita tem fixture. |
| JPX02 | Deltas contra OpenJPEG. | Lossless compara samples exatos antes da conversão. Para lossy, o protocolo e os tetos por fixture são definidos a partir de saída independente e revisados pelo coordenador antes de testar Dart; informar erro máximo, RMSE e pixels divergentes. Ajustar tolerâncias para acomodar o decoder invalida o aceite. |
| JPX03 | Orçamento cumulativo de trabalho e memória. | Dimensões, precisão, componentes, codeblocks, coeficientes, tiles, raster e PNG são limitados antes da alocação; teste VM/JS com produtos/offsets extremos. |
| JPX04 | Adaptador PDF e integração de recurso. | Cobrir `/JPXDecode` direto e array `[/ASCII85Decode /JPXDecode]`, inclusive nomes/parâmetros indiretos. Dimensões presentes no PDF que conflitem com o codestream causam rejeição tipada na fronteira do adaptador. Espaço de cor explícito só é aceito se compatível com os componentes/perfil declarado; ausência usa a informação válida do codestream. Paridade eager/sessão e caminho do recurso são preservados. |
| JPX05 | Limitações e erros observáveis. | Alpha/SMaskInData, ICC/palette, subsampling, CMYK, precisões diferentes, Part 2 e HTJ2K são suportados com evidência ou identificados como não suportados, sem pixels inventados. |

Documente a política de imagem não suportada versus input perigoso: hoje o PDF
pode conservar a geometria sem pixels extraídos. Preserve compatibilidade dessa
política ou faça mudança pública explícita e testada. O codec privado fornece
falha tipada; o adaptador decide a degradação documentada. Não altere texto ou
reflow nesta branch.

Testes mínimos: novas suítes codec/JPX, `test/tests/pdf/pdf_extraction_test.dart`,
`pdf_bitmap_test.dart`, `pdf_ccitt_test.dart`, `pdf_jbig2_test.dart`, sessão PDF
e Chrome real. Acrescente fixture PDF com JPX e codestream independente licenciado.
Inclua cinza/RGB, lossless/lossy, LRCP/RLCP, MCT e multi-tile, além de conflitos
de dimensões/cor, cadeia ASCII85 e rejeição dos filtros/perfis fora do subconjunto.

O `tool/pdf_parity.dart --image` atual pode emitir SKIP com exit zero e seu
adaptador PDF.js é monocromático. A04 cria comparação de samples/colorida com
OpenJPEG; a ausência do oráculo obrigatório deve falhar o aceite. Não produza
goldens de referência usando o próprio decoder Dart.

### A05. Anotações duráveis e adaptador W3C

Objetivo: guardar seleções com identidade e contexto, recuperar trechos após
alterações e expor ambiguidades sem modificar o comportamento dos codecs antigos.

Base de port: [Hypothesis client em TypeScript](https://github.com/hypothesis/client/tree/a7b7400d0d706d4357ec37c2a3610b25dcca89d5),
sobretudo `src/annotator/anchoring/`. A licença principal é BSD-2-Clause com
termos separados de subcomponentes no LICENSE. O DOM/browser não é dependência
de runtime do port. [Readium Kotlin](https://github.com/readium/kotlin-toolkit/tree/89b96c20c447d0aec17db57a06456b7decffde4c),
BSD-3-Clause, é referência de identidade/locators/posições, não de DRM.
Use o [W3C Web Annotation Data Model](https://www.w3.org/TR/annotation-model/)
como contrato externo dos seletores.

Leia `book_locator.dart`, `fuzzy_relocation.dart`, `locator_codec.dart`,
`annotation_codec.dart`, records de highlight/bookmark e os testes existentes.
O helper atual escolhe o primeiro candidato em empate e seus testes exigem isso.

| ID | Entrega obrigatória | Critério de aceite |
| --- | --- | --- |
| ANN01 | Envelope aditivo versionado com C02/C03/C06. | Captura/exporta/importa identidade, ocorrência, ranges, citação e contexto sem reinterpretar payloads v1. |
| ANN02 | Resolução verificada e migração explícita. | Mesmo texto/revisão resolve exatamente; markup alterado, correção textual e reordenação usam evidências e política declarada. Alvo removido é missing. |
| ANN03 | Ambiguidade e revisão desconhecida. | Frases repetidas com contexto idêntico retornam candidatos/ambiguidade; revisão incompatível e identidade desconhecida não viram resolved por proximidade arbitrária. |
| ANN04 | W3C TextQuoteSelector/TextPositionSelector no subconjunto declarado. | Conversão de unidades é testada com astral/combining; round trips preservam informação suportada e sinalizam perda/não suporte. JSON hostil tem limites e falhas tipadas. |
| ANN05 | Limites e compatibilidade. | Limites de candidatos, tamanho de citações/contexto e trabalho impedem explosões; codecs e desempates v1 continuam passando; execução pura funciona no VM/browser. |
| ANN06 | Integração PDF. | Após P1, a mesma âncora de trecho inequívoco resolve entre modos/reabertura no corpus longo; regiões e ranges concordam com a busca. |

Antes de P0, implemente seleção de candidatos e seletores sobre strings privadas
explícitas. Depois use snapshots comuns. Metadados parecidos não autorizam migrar
entre livros; o consumidor solicita a política entre edições.

Testes mínimos: `test/tests/locators/`, `test/tests/annotations/`, novas suítes
de anchors/interop e Chrome com casos Unicode. Compare o subconjunto comum com
Hypothesis usando fixtures licenciadas; mantenha expectativas próprias para a
ambiguidade, pois o comportamento requerido pode ser mais estrito que o oráculo.

Fora desta missão: widgets/menus do Grimoire, sync, banco, relógio de conflitos
distribuído, DRM e conformidade integral com todos os seletores W3C/Readium.

## 5. Evidência, testes e requisitos não funcionais

| ID | Categoria | Obrigação comum |
| --- | --- | --- |
| N01 | Compatibilidade | Dart puro e mínimo SDK declarado em `pubspec.yaml`; verificar novas APIs sem importar `src`. Se não houver SDK mínimo disponível, declarar a lacuna e deixar a validação pendente. |
| N02 | Segurança | Defaults finitos documentados, testes imediatamente abaixo/acima dos limites e aritmética VM/web; regressão focada para cada fix de parser/fronteira. |
| N03 | Corpus | Fixture original imutável, licença própria, origem, produtor/versão, hash e resultado independente. Incluir fonte real independente e casos sintéticos rotulados. |
| N04 | Oráculos | Fixar revisão/build/opções. O comparador de aceite falha sem oráculo obrigatório; SKIP não conta como validação. Fixtures/goldens usuais devem permitir a suíte normal offline. |
| N05 | Desempenho | Executar baseline/trabalho alternados, mínimo cinco repetições em ambiente igual, relatando p50/p95, memória observada e limitações da amostragem. Separar custo frio/quente e casos que pioraram. |
| N06 | Plataforma | Exercitar os caminhos inline, isolate e worker que a API suporta. Chrome precisa do worker compilado e de teste que confirme execução no worker, sem fallback escondido. |
| N07 | Reprodutibilidade | Ferramentas de comparação têm instruções/flags reais e exit code de falha. Resultados resumidos no handoff; relatórios e dumps grandes ficam em output ignorado. |
| N08 | Licenças | Conferir os arquivos efetivamente portados, atualizar `THIRD_PARTY_NOTICES.md` e `licenses/`, preservar NOTICE/copyright aplicáveis. Licença do código não cobre automaticamente fixtures/fontes/modelos. |

Reutilize fixtures/manifests e o harness determinístico existentes. Novas famílias
ou seeds precisam entrar no inventário com hashes/proveniência no mesmo commit.
Comparadores novos ficam em `tool/` e documentam como instalar o oráculo e
reproduzir cada divergência. A suíte CI normal não baixa arquivos para passar.

Durante a implementação, rode a suíte da missão. Antes de entregar a branch:

```sh
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test --exclude-tags fuzz
dart compile js web/unseal_worker.dart -o test/web/unseal_worker.js
dart test -p chrome test/web/
dart test --tags fuzz
dart run tool/fuzz_corpus_inventory.dart --check-manifest
dart pub publish --dry-run
git diff --check
```

Os arquivos JS/deps/map são gerados e ignorados. Após os testes, remova apenas
os arquivos gerados conhecidos, conforme o guia de desenvolvimento; não use
limpeza indiscriminada do checkout. Falha, teste não executado ou oráculo ausente
é pendência no handoff, não sucesso. Use a versão de SDK indicada no repositório.

## 6. Documentação e handoff obrigatórios por branch

Cada agente atualiza a documentação junto do código que entrega:

- README: uso real com `package:unseal/unseal.dart`, comportamento, unidades,
  limites, formatos/subconjuntos e plataformas disponíveis.
- Guia de arquitetura/codebase: somente os módulos, fluxos e decisões que mudaram.
- Changelog: entradas em uma seção `Unreleased` comum, sem alterar a seção
  histórica 1.2.0 nem decidir sozinho a próxima versão publicada.
- Roadmap: remover apenas trabalho cujo aceite passou; preservar limitações
  restantes e atualizar links para o comportamento documentado.
- Notices/licenças e proveniência: registrar código adaptado, fixtures e oráculos.

O handoff no PR ou na resposta final contém: SHA-base e commits entregues;
requisitos implementados com testes correspondentes; comandos e resultados;
matriz suportado/rejeitado; medições com contexto; limitações e dependências;
arquivos compartilhados alterados; passos exatos para repetir o aceite.
Não crie relatórios de campanha permanentes em vários documentos. O código,
testes, fixtures e guias mantidos são a evidência durável; este plano guarda os
critérios enquanto houver trabalho pendente.

Prompt de despacho, com uma única substituição de agente e worktree:

> Implemente a missão A0N de `doc/parallel-implementation.md` nesta worktree,
> a partir do SHA-base informado pelo coordenador. Leia os contratos comuns e
> cumpra os critérios, limites, testes, referências e deveres de documentação.
> Trabalhe apenas na branch atribuída. Confira os arquivos atuais antes de
> editar. Avance nos núcleos independentes enquanto aguarda P0/P1; registre
> bloqueios de integração sem duplicar o contrato comum. Entregue commits
> revisáveis, árvore limpa e o handoff da seção 6. Não faça push, merge na main,
> tag ou publicação sem instrução específica do usuário/coordenador autorizado.

## 7. Integração e aceite da combinação

O coordenador confere o commit-base comum, revisa P0 e integra somente esse
marco quando aprovado tecnicamente. Os demais agentes incorporam a `main`
atualizada preservando seus commits; merge é a opção padrão para branches já
compartilhadas. Rebase exige coordenação e autorização para reescrever histórico.

RAR5 e JPEG2000 podem entrar assim que passarem seus aceites. P1 vem antes da
certificação de persistência PDF de busca/anotações. A02/A05 podem entrar com
restrições explícitas enquanto o aceite PDF fica pendente; isso não encerra a
campanha inteira. Depois de cada merge, atualize as branches restantes e rode
os testes das fronteiras que mudaram, além dos checks de cada branch.

| Cenário combinado | Condição de aprovação |
| --- | --- |
| P0 + busca + anotações | Hit indexado vira seleção e âncora para os mesmos caracteres; Unicode e caminhos repetidos mantêm ocorrência/range corretos. |
| P1 + busca + anotações | Em PDF com mais de 20 páginas, indexar, anotar, materializar, fechar/reabrir e trocar modo preserva os trechos inequívocos. Revisão incompatível invalida o índice e exige migração da âncora. |
| Layout + JPEG2000 | Página com texto e JPX mantém geometria, ordem, ranges e recurso correto em eager/sessão; o dispatch de imagem não altera o texto. |
| RAR5 + sessão/worker | Bytes das páginas coincidem em leitura completa e fora de ordem; corrupção tem a mesma família de erro e sessões permanecem isoladas. |
| Ciclo de vida | Cancelar/dispor durante indexação ou requests não publica cobertura completa falsa nem reaproveita estado de outra sessão. CPU/bytes/memória ficam dentro dos limites declarados. |
| Compatibilidade | Exemplos públicos, payloads v1 e suíte anterior continuam válidos; nenhuma documentação promete subconjunto ainda rejeitado. |

A revisão final resolve conflitos por significado, principalmente exports,
switches de wire, README, `Unreleased`, notices e manifests. Um merge textual
sem conflitos não comprova compatibilidade. Leia o diff agregado e compare
as claims públicas com os testes e a matriz suportado/rejeitado.

Com a combinação revisada e commitada na `main` limpa, execute o gate completo
usando a versão efetiva de `pubspec.yaml`:

```sh
VERSION=$(sed -n 's/^version: //p' pubspec.yaml)
make release-check VERSION="$VERSION"
git status --short
```

Esse comando verifica prontidão técnica, não decide a versão futura nem publica.
Tags, push e publicação continuam exigindo instrução específica. Se os commits
mudarem após o gate, rode novamente as verificações afetadas e o gate da entrega.

## 8. Conclusão da campanha e escopo posterior

Pronto significa cinco missões atendidas no subconjunto declarado, P0/P1
integrados, cenários combinados aprovados, guias reconciliados e `main` limpa.
Testes verdes com oráculos pulados, APIs só internas, placeholders, corpus
reescrito ou suporte PDF permanentemente desativado não atendem esse critério.

Trabalho posterior continua no roadmap: solid RAR5 se não entregue, variantes
JPEG2000 adicionais, tabelas/layout mais complexos, Readium completo, contratos
espaciais para outros formatos e renderizador nativo do Grimoire. Não aumente
silenciosamente o escopo para implementar esses itens nesta preparação.

Quando uma missão for concluída, mover seu comportamento para os guias públicos
e remover sua seção operacional já obsoleta. Ao concluir todas, remover este
plano e seus pointers; o histórico Git preserva a decisão. Para futuras telas do
Grimoire, a skill `user-flow` pode consumir os contratos implementados. O próximo
passo desta campanha é despachar as cinco missões, sem trabalho de UI no Unseal.
