---
feature: Leitura EPUB de layout fixo
slug: epub-fixed-layout
version: 1.0
status: draft
generated: 2026-09-26
---

# Pesquisa: EPUB de layout fixo em Unseal, Grimoire e Grimoire Narration

## 1. Objetivo da Pesquisa

Avaliar um projeto grande, com resultado perceptível ao usuário e trabalho divisível entre agentes: ler EPUBs de layout fixo com geometria, ordem, navegação e recursos acessíveis preservados. A pesquisa identifica contratos já existentes e uma lacuna de integração; não afirma que todo EPUB fixo falha atualmente nem que a proposta já passou nos testes de conformidade.

## 2. Eixos de Pesquisa

- Semântica de layout e navegação exigida pela especificação EPUB.
- Contratos existentes e lacuna entre Unseal, Grimoire e Narration.
- Preservação de texto, acessibilidade, anotações e sincronização.
- Corpus de conformidade e medição em Mac, web e Android físico.

## 3. Achados por Eixo

### Semântica EPUB

- EPUB 3.3 define layout `pre-paginated`, orientação, spreads sintéticos, colocação de cada página e dimensões do conteúdo XHTML/SVG. Há regras globais e substituições por item da ordem de leitura. — [EPUB 3.3, controle de layout](https://www.w3.org/TR/epub-33/#sec-layout-rendering-control)
- Sistemas de leitura devem respeitar a ordem do `spine`, inclusive referências repetidas a um mesmo recurso; itens não lineares ativados pelo usuário também precisam ser apresentados. A direção da leitura pode ser declarada no `spine`. — [EPUB Reading Systems 3.3](https://www.w3.org/TR/epub-rs-33/)
- Readium CSS foi feito para conteúdo refluível e declara que suas folhas não devem ser usadas para EPUB de layout fixo. Isso reforça a necessidade de um modo de apresentação próprio, mesmo que ele reutilize infraestrutura de servidor e WebView. — [Readium CSS quickstart](https://readium.org/css/docs/CSS02-quickstart.html)

### Estado dos pacotes

- Unseal já expõe `EpubRendition` com `layoutFor`, `orientationFor`, `spreadFor`, `flowFor` e `pageSpreadFor`; também expõe `pageList`, `landmarks` e metadados de acessibilidade. As dimensões internas de XHTML/SVG ainda não são extraídas para esses valores. — [modelo de rendition](../../../lib/src/features/epub/entities/package/epub_rendition.dart), [README de Unseal](../../../README.md)
- Grimoire descreve EPUB como HTML refluído; o caminho de página fixa documentado cobre quadrinhos e fac-símile de PDF. A busca no código de `lib/` não encontrou uso dos tipos `EpubRendition` ou `EpubLayout`, e os testes de “fixed layout pages” usam um PDF de teste. Assim, a integração específica de EPUB fixo é uma lacuna de implementação a verificar com fixtures reais. — [README de Grimoire](../../../../e_livre_viewer/README.md), [teste atual de página fixa](../../../../e_livre_viewer/test/viewer_features_test.dart)
- Narration já consome segmentos SMIL e sincroniza áudio com marcações no texto canônico do visualizador. O modo fixo precisará preservar essa correspondência ao navegar ou ampliar uma página. — [arquitetura de Narration](../../../../e_livre_viewer_narration/docs/architecture.md), [regras de media overlays](https://www.w3.org/TR/epub-rs-33/#sec-media-overlays)

### Texto e acessibilidade

- EPUB Reading Systems 3.3 especifica o comportamento de mídia sincronizada, incluindo início no ponto escolhido, fim de clipes e retomada depois de navegação. Um modo fixo que apenas mostra uma imagem da página perde a oportunidade de seleção e sincronização em livros XHTML/SVG. — [EPUB Reading Systems 3.3](https://www.w3.org/TR/epub-rs-33/)
- A orientação visual de páginas fixas e a ordem lógica de leitura podem divergir. A orientação da W3C para acessibilidade de EPUB fixo recomenda examinar legibilidade, ordem e alternativas disponíveis, sem deduzir acessibilidade a partir da aparência. — [EPUB Fixed Layout Accessibility](https://www.w3.org/TR/epub-fxl-a11y/)
- A política atual de Grimoire desativa JavaScript escrito pelo livro por padrão. Livros fixos que dependem de scripts precisam de tratamento explícito sem enfraquecer essa decisão de segurança. — [README de Grimoire](../../../../e_livre_viewer/README.md), [EPUB Reading Systems 3.3, scripting](https://www.w3.org/TR/epub-rs-33/#sec-scripting)

### Verificação

- O repositório oficial de testes EPUB da W3C fornece livros de teste e critérios de aprovação para sistemas de leitura. Os testes devem ser selecionados por comportamento, versão da especificação e licença, com resultados separados por plataforma. — [w3c/epub-tests](https://github.com/w3c/epub-tests)
- O app de exemplo de Grimoire já foi medido em profile em um Galaxy S23, mas os números existentes cobrem abertura e fluidez de livros comuns, não EPUB fixo. O Mac e o Chrome permitem completar uma matriz inicial de renderização e regressões. — [baseline local](../ai-intensive-roadmap/baseline-2026-09-25.md), [guia de perfil do Flutter](https://docs.flutter.dev/perf/ui-performance)

## 4. Comparativo

| Abordagem | Benefício | Limite | Decisão |
| --- | --- | --- | --- |
| Reusar a paginação refluída para todo EPUB | Pouca alteração inicial | Pode alterar geometria e ignorar spreads declarados | Preservar para itens refluíveis |
| Modo EPUB fixo dedicado sobre XHTML/SVG original | Mantém DOM, texto selecionável, recursos e geometria | Requer composição, zoom, navegação e testes por plataforma | Recomendado |
| Rasterizar cada página | Composição simples | Perde texto/semântica e pode piorar memória e nitidez | Apenas eventual fallback explícito para casos específicos |

## 5. Recomendação para o MVP

Começar com EPUB 3 de layout fixo em XHTML: honrar layout global e por item, dimensões declaradas, orientação, spreads, direção e colocação da página, preservando DOM e texto canônico. Integrar o modo ao leitor existente, com navegação, zoom, posição/restauração, links, busca e marcações testadas. Depois ampliar para SVG, páginas mistas refluíveis/fixas, anotações e SMIL; a matriz W3C e os livros reais devem determinar a ordem de exceções e refinamentos. Implementar em etapas com um resultado funcional visível em Android, macOS e web, sem exigir um novo parser em Grimoire.

## 6. Perguntas em Aberto / Fora do Escopo

- Quais livros reais de layout fixo podem entrar legalmente no corpus redistribuível? Os privados devem permanecer fora do Git e dos relatórios.
- Como o host deve apresentar opção de spread/zoom quando a preferência do leitor conflita com a declaração do editor? Registrar a decisão na API e nos testes.
- Conteúdo que exige JavaScript do livro permanece sujeito à política segura existente; eventual opt-in é um projeto de segurança separado.
- DRM, certificação de acessibilidade e equivalência pixel a pixel com todos os leitores comerciais não são metas deste projeto.
- A ausência de uso de `EpubRendition` no código atual foi verificada por busca, mas a experiência real de cada livro fixo ainda requer teste visual antes de classificar a falha específica.

---
**Próximo passo:** executar uma especificação (`srs`) e uma matriz de testes sobre este documento, começando pelos casos W3C aplicáveis e pelos contratos públicos existentes.
