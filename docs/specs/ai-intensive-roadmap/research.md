---
feature: AI-intensive roadmap for the Unseal package family
slug: ai-intensive-roadmap
version: 1.1
status: draft
generated: 2026-09-25
---

# Pesquisa: projetos de alto esforço para Unseal, Grimoire e Grimoire Narration

## 1. Objetivo da Pesquisa

Identificar trabalhos grandes que uma IA com orçamento abundante possa executar em etapas auditáveis, com benefício mensurável para quem usa os três pacotes. A IA destinatária tem acesso aos arquivos e ao Mac do usuário e pode coordenar vários agentes. Este documento é uma avaliação de oportunidades e uma instrução para iniciar os pacotes de trabalho prioritários quando for entregue a ela; não afirma que os ganhos de desempenho ou as lacunas propostas já foram medidos em produção.

## 2. Eixos de Pesquisa

- Desempenho percebido e consumo de memória ao abrir, navegar e pesquisar livros.
- Compatibilidade e robustez com livros reais, casos adversos e referências independentes.
- Fidelidade e acessibilidade de EPUB, PDF e DjVu no caminho completo até a tela.
- Interoperabilidade de posições, catálogos e anotações.
- Narrativa, sincronização e comportamento em plataformas reais.

## 3. Achados por Eixo

### Desempenho percebido e memória

- **Já existe:** Unseal mede detecção, metadados, parsing, busca e alguns caminhos de livros reais; o comparador tem rodadas A/B alternadas. Ampliar esses instrumentos é mais útil que começar um benchmark paralelo. — [README de Unseal](../../../README.md), [comparador A/B](../../../benchmark/compare_baselines.dart)
- **Já existe:** Grimoire mede controlador, servidor, corpus e JavaScript, mas essas medições isoladas não estabelecem o tempo de um arquivo fechado até a primeira página utilizável em um dispositivo. — [benchmarks de Grimoire](../../../../e_livre_viewer/benchmark/grimoire_benchmarks.dart), [arquitetura de Grimoire](../../../../e_livre_viewer/docs/architecture.md)
- **Hipótese a testar:** o worker web pode elevar o pico de memória ao transportar um livro completo; a documentação local já registra que livros grandes podem existir temporariamente no worker e na tela. Medir antes de alterar o protocolo. — [README de Unseal](../../../README.md), [guia de memória do Flutter](https://docs.flutter.dev/tools/devtools/memory)
- **Método externo:** o Mac do usuário permite medir a biblioteca Dart, o leitor macOS e o leitor web em um navegador real. Essas são três plataformas de medição distintas. Build profile e dispositivo físico representativo continuam necessários para afirmar desempenho em celulares; debug ou simulador não substituem essa verificação. Atualização 2026-09-26: um Galaxy S23 (SM-S911B) está disponível por adb e já forneceu a primeira amostra móvel em build profile (ver baseline). — [guia de desempenho do Flutter](https://docs.flutter.dev/perf/ui-performance), [visão de desempenho do DevTools](https://docs.flutter.dev/tools/devtools/performance)

### Compatibilidade e robustez

- **Já existe:** há testes determinísticos de fuzz, limites de arquivo, manifestos de fixtures e uma varredura optativa da biblioteca privada. O próximo salto é diversidade de origem e um relatório reproduzível por família de formato, não apenas quantidade de arquivos sintéticos. — [arquitetura de Unseal](../../../docs/architecture.md), [varredura de biblioteca](../../../benchmark/library_sweep.dart)
- **Lacuna validada:** o parser de OPDS atual recebe XML/Atom; a especificação OPDS 2 usa JSON e tem esquemas publicados. É uma extensão concreta, mas com benefício concentrado nos apps que navegam catálogos. — [parser atual](../../../lib/src/features/opds/opds_feed.dart), [especificação OPDS 2](https://specs.opds.io/opds-2.0)
- **Método externo:** EPUBCheck é um verificador de conformidade do arquivo EPUB, e os testes W3C exercitam comportamentos de sistemas de leitura. Ambos servem para selecionar e classificar casos, sem tratar a saída de outro programa como verdade absoluta sobre a experiência do leitor. — [EPUBCheck](https://github.com/w3c/epubcheck), [testes EPUB da W3C](https://github.com/w3c/epub-tests)
- **Método externo:** campanhas de fuzz precisam medir cobertura alcançada e preservar amostras que a aumentam; mais execuções do mesmo conjunto não garantem novos caminhos. OSS-Fuzz não lista Dart entre suas linguagens com suporte direto, portanto a proposta é melhorar o harness local, não prometer integração imediata. — [guia de cobertura do OSS-Fuzz](https://github.com/google/oss-fuzz/blob/master/docs/getting-started/new_project_guide.md), [linguagens suportadas](https://github.com/google/oss-fuzz)

### Fidelidade e acessibilidade

- **Já existe:** Unseal expõe page-list, landmarks, preferências de apresentação e metadados de acessibilidade de EPUB 3; Grimoire já tem paginação, busca, PDF em reflow/fac-símile e um caminho de livro até a tela. O trabalho novo deve testar e completar comportamento, sem repetir a modelagem já entregue. — [README de Unseal](../../../README.md), [arquitetura de Grimoire](../../../../e_livre_viewer/docs/architecture.md)
- **Lacuna documentada:** DjVu ainda rejeita dicionários JB2 compartilhados, documentos indiretos e texto/navegação comprimidos; PDF visa leitura e extração, não renderização universal. Completar essas áreas exige corpus real, comparação visual e limites de recursos. — [limites de Unseal](../../../README.md), [expansão de formatos](../../../docs/format-expansion.md)
- **Referência externa:** EPUB 3.3 define page-list, landmarks, layout fixo e media overlays; a especificação de sistemas de leitura define obrigações de apresentação e sincronização. Isso permite criar uma matriz de casos observáveis para Unseal + Grimoire + Narration. — [EPUB 3.3](https://www.w3.org/TR/epub-33/), [EPUB Reading Systems 3.3](https://www.w3.org/TR/epub-rs-33/)
- **Referência externa:** metadados declarados pelo editor ajudam descoberta, mas não certificam acessibilidade da experiência; o relatório deve separar extração de metadados, resultado visual e comportamento com tecnologia assistiva. — [EPUB Accessibility 1.1](https://www.w3.org/TR/epub-a11y-11/), [README de Unseal](../../../README.md)

### Interoperabilidade

- **Já existe:** Unseal tem locators tipados, CFI, progressão, anotações e um codec JSON próprio. Isso permite uma ponte opcional com ecossistemas externos sem trocar os contratos internos à força. — [arquitetura de Unseal](../../../docs/architecture.md), [codec atual](../../../lib/src/features/locators/locator_codec.dart)
- **Referência externa:** Readium especifica locators e uma lista de posições que pode ser calculada pelo serviço de publicação e consumida pela navegação. Uma adaptação explícita pode facilitar importação/exportação e referência de posição entre leitores. — [locators Readium](https://readium.org/architecture/models/locators/), [positions list](https://readium.org/architecture/models/locators/positions/)
- **Referência externa:** o manifesto Readium fornece um modelo de publicação com ordem de leitura, recursos e links, que também fundamenta OPDS 2. Suporte a esse manifesto seria um projeto separado de parsing de um arquivo local. — [Readium Web Publication Manifest](https://readium.org/webpub-manifest/), [OPDS 2](https://specs.opds.io/opds-2.0)

### Narração e plataformas

- **Já existe:** Grimoire Narration escolhe SMIL quando disponível e TTS caso contrário, usa drivers injetáveis e testes de ciclo de vida; a documentação registra que pausar TTS interrompe e repete a sentença atual. — [arquitetura de Narration](../../../../e_livre_viewer_narration/docs/architecture.md), [README de Narration](../../../../e_livre_viewer_narration/README.md)
- **Referência externa:** EPUB Reading Systems 3.3 detalha início no ponto escolhido, fim de clipes, sincronização após navegação, velocidade e estruturas ignoráveis/escapáveis. Isso fornece uma matriz objetiva para testes com overlays reais e dispositivos, além dos testes de drivers falsos. — [EPUB Reading Systems 3.3, seção 9](https://www.w3.org/TR/epub-rs-33/#sec-media-overlays)
- **Limite de evidência:** testes unitários e de integração com motores falsos exercitam lógica, mas a reprodução em segundo plano e a interação com o mecanismo de fala do sistema precisam de observação em Android/iOS reais. — [testes de Narration](../../../../e_livre_viewer_narration/test/), [guia de perfil em dispositivo físico](https://docs.flutter.dev/perf/ui-performance)

## 4. Comparativo

| Projeto candidato | Benefício direto ao usuário | Adequação a IA com muitos créditos | Prova exigida | Prioridade |
| --- | --- | --- | --- | --- |
| Laboratório de desempenho ponta a ponta, seguido de otimização guiada | Abertura mais rápida, menos travamentos e menor pico de RAM | Alta: instrumentação, múltiplas hipóteses e repetição A/B | p50/p95 da primeira página e transições, pico de RAM, quadros lentos; resultados separados para Dart VM, macOS e web no Mac | 1 |
| Corpus real e diferencial com triagem automática | Mais livros abrem corretamente, com menos travamentos e conteúdo perdido | Muito alta: aquisição licenciada, classificação, minimização e regressões | Matriz por formato/proveniência, falhas reproduzíveis, cobertura nova, taxa de leitura correta | 1 |
| Matriz de conformidade visual e de acessibilidade EPUB | Layout, navegação, seleção e leitura mais corretos | Alta: muitas combinações de livro/tela/configuração | Casos W3C, capturas comparáveis, critérios humanos de leitura e acessibilidade | 2 |
| Narração SMIL/TTS em plataformas reais | Áudio acompanha o texto e permanece controlável em segundo plano | Média/alta: cenários longos e concorrentes | Clipe certo, marcação/posição, troca de capítulo, pausa/retomada e sessão de mídia no Mac; Android/iOS só quando houver dispositivo | 2 |
| Memória e leitura progressiva para livros enormes | Livros grandes deixam de esgotar RAM ou bloquear a interface | Alta, mas arquitetura arriscada | Redução de pico e tempo da primeira página em arquivo real grande, sem perda de semântica | 3, após perfil |
| Interoperabilidade Readium e OPDS 2 | Posições e catálogos portáveis entre aplicativos | Média: bastante especificação, menos investigação empírica | Round-trip de locators, schemas, casos de catálogos reais | 3 |
| Completar PDF/DjVu difíceis ou adicionar OCR optativo | Leitura de material hoje degradado | Alta, porém risco de escopo/licença/custo | Corpus real, diferença visual/textual e limites de recursos; OCR fora do núcleo puro Dart | 3, após medir incidência |

## 5. Recomendação para o MVP

Ao receber este documento como tarefa, começar a executar dois programas independentes de produção de evidências: **(A) desempenho de abertura até primeira página e navegação**, e **(B) corpus real, diferencial e fuzz guiado por cobertura**. Ambos aproveitam infraestrutura existente e revelam onde os créditos adicionais terão maior efeito. Depois de obter a matriz de resultados, implementar melhorias pontuais na trilha com maior impacto observado; usar conformidade EPUB e narração como segunda onda, pois já há contratos suficientes para formular testes verificáveis. Não é necessário esperar uma SRS para produzir o baseline, o corpus e as primeiras correções focadas.

### Ambiente local e interpretação dos resultados

- Usar o **Mac do usuário** para os benchmarks existentes: `dart run benchmark/unseal_benchmarks.dart` no Unseal, `flutter test benchmark/grimoire_benchmarks.dart` no Grimoire e `flutter test benchmark/grimoire_narration_benchmarks.dart` no Narration. Os três aceitam filtros e relatório JSON; ler cada cabeçalho antes de executar. Os microbenchmarks ajudam a localizar custos, mas não são medida da experiência completa. — [entrada de Unseal](../../../benchmark/unseal_benchmarks.dart), [entrada de Grimoire](../../../../e_livre_viewer/benchmark/grimoire_benchmarks.dart), [entrada de Narration](../../../../e_livre_viewer_narration/benchmark/grimoire_narration_benchmarks.dart)
- Acrescentar um cenário **macOS nativo** no app de exemplo, em build profile quando disponível, para medir abertura até primeira página, transição, busca, fluidez e memória. Acrescentar o mesmo cenário na **versão web em Chrome no Mac**, cobrindo iframe, worker quando configurado e custo do protocolo. Identificar separadamente a contribuição de parsing, ponte e renderização. — [plataformas de Grimoire](../../../../e_livre_viewer/docs/architecture.md), [worker de Unseal](../../../README.md), [guia de perfil do Flutter](https://docs.flutter.dev/perf/ui-performance)
- Executar baseline e candidato no **mesmo Mac, SDK, navegador, modo de compilação, corpus, viewport e condições de cache**. Repetir rodadas alternadas e reportar mediana, p95, dispersão, memória e falhas. Registrar mudanças de temperatura/carga do sistema; descartar e repetir medições contaminadas. — [comparador A/B já existente](../../../benchmark/compare_baselines.dart), [ferramentas de desempenho do Flutter](https://docs.flutter.dev/tools/devtools/performance)
- Nomear as conclusões por plataforma: “melhorou na VM deste Mac”, “melhorou no app macOS”, “melhorou no Chrome deste Mac” ou “melhorou no Galaxy S23”. Números móveis exigem build profile no aparelho e comparação A/B no mesmo dispositivo; a amostra única de 2026-09-25 não é comparação. Em 2026-09-26 houve A/B da **resolução** de CFI no S23 e validação do leitor real no macOS, S23 e Chrome, mas ainda não A/B do tempo da primeira página. Ver [resultados e limites](baseline-2026-09-25.md). — [guia de desempenho do Flutter](https://docs.flutter.dev/perf/ui-performance)

### Organização dos agentes

- Um agente **coordenador** registra o estado dos três checkouts, contratos públicos, metodologia e resultados, integra mudanças e verifica regressões. Separar trabalho preexistente de trabalho novo antes de editar. — [regras de Unseal](../../../AGENTS.md), [arquitetura de Grimoire](../../../../e_livre_viewer/docs/architecture.md)
- Um agente de **desempenho** instrumenta o caminho completo e é o único a comandar medições comparativas no Mac. Um agente de **corpus** prepara proveniência, casos diferenciais, minimização e testes; outro de **leitor web/macOS** prepara cenários de ponta a ponta. A trilha de **narração** pode começar depois do primeiro baseline ou em arquivos independentes. — [benchmarks de Unseal](../../../benchmark/unseal_benchmarks.dart), [benchmarks de Grimoire](../../../../e_livre_viewer/benchmark/grimoire_benchmarks.dart), [arquitetura de Narration](../../../../e_livre_viewer_narration/docs/architecture.md)
- Agentes podem investigar, escrever testes e revisar em paralelo, preferindo checkouts isolados ou arquivos sem sobreposição. **Medições de desempenho são seriadas no mesmo Mac:** não executar simultaneamente benchmark, build, fuzz, navegador automatizado ou varredura pesada da biblioteca. O coordenador reserva janelas de medição e integra cada alteração antes da comparação A/B. — [comparador A/B](../../../benchmark/compare_baselines.dart), [guia de perfil do Flutter](https://docs.flutter.dev/perf/ui-performance)

### Pacote de trabalho A — desempenho que o leitor percebe

1. Registrar os commits e alterações locais dos três pacotes, versões do SDK/navegador, Mac e conjunto de livros. Guardar baseline em checkout/artefato isolado antes de alterar implementação; preservar alterações preexistentes.
2. Instrumentar etapas: leitura de bytes, detecção, metadados, parsing, transporte worker/isolate, montagem do servidor, primeira página pronta, troca de capítulo, busca, retorno ao livro e encerramento. Medir tempo, pico de memória e quadros lentos.
3. Executar rodadas A/B alternadas no Mac, sem outros agentes consumindo CPU ou memória. Separar frio/quente, Dart VM, app macOS, navegador web e arquivo pequeno/médio/grande. Registrar medianas, p95, dispersão e falhas, inclusive as de memória.
4. Escolher os três maiores custos observados, experimentar uma mudança por vez, preservar semântica/locators e adicionar regressões. Aceitar ganho apenas se o caminho completo melhorar sem regressão material nos formatos vizinhos.

### Pacote de trabalho B — qualidade em escala

1. Construir corpus com licença/proveniência, origem independente, formato, tamanho, recursos relevantes e hash; manter livros privados fora do Git e exportar somente IDs anônimos.
2. Rodar cada livro com Unseal e, onde couber, uma referência independente, comparando metadados, capítulos, texto extraído, imagens, navegação e erros. Para EPUB, classificar validade com EPUBCheck, sem equiparar validade a legibilidade.
3. Priorizar por frequência e gravidade: crash/hang/estouro de recursos, livro válido que falha, perda de conteúdo, diferença de navegação, detalhe cosmético. Minimizar exemplos que falham e registrar um teste focado para cada correção.
4. Mutar corpus estruturalmente, medir cobertura nova, manter sementes úteis e rejeitar entradas acima de limites de tempo/memória. Publicar matriz antes/depois com denominadores e exclusões.

### Instrução curta para entregar à outra IA

> Você tem acesso aos três checkouts e ao Mac do usuário e pode usar vários agentes. Comece agora os pacotes A e B deste documento: registre o estado local e produza baseline, corpus e metodologia reproduzível; depois implemente correções e otimizações em etapas pequenas. Divida investigação e testes independentes entre agentes, mas reserve o Mac exclusivamente para cada rodada de benchmark e integre mudanças de forma sequencial. Meça separadamente Dart VM, aplicativo macOS, versão web no Chrome e o Galaxy S23 conectado (números móveis só com build profile e A/B no mesmo aparelho). Cada etapa deve trazer hipótese, arquivos alterados, regressões, benchmark A/B no mesmo ambiente, números absolutos e percentuais, dispersão, memória, casos que pioraram e limitações. Preserve trabalho preexistente, fixtures e proveniência; não publique, faça push ou adicione dependências de plataforma ao núcleo Unseal. Quando não houver ganho mensurável, mantenha o resultado como investigação e não apresente a otimização como concluída.

## 6. Perguntas em Aberto / Fora do Escopo

- Qual dispositivo físico mais fraco ainda representa os usuários móveis pretendidos? Um Galaxy S23 (SM-S911B) está disponível como dispositivo de referência desde 2026-09-25 e fornece a primeira amostra móvel; metas absolutas para aparelhos mais fracos continuam pendentes de definição. Sem isso, metas absolutas para Android/iOS seriam arbitrárias; o trabalho no Mac/web pode prosseguir agora.
- Quantos livros reais de cada formato podem entrar em um corpus redistribuível, e quais só podem ser avaliados localmente?
- O usuário quer compatibilidade Readium/OPDS como recurso público dos pacotes ou somente uma ponte de aplicativo? Esta decisão define o contrato e a ordem do trabalho.
- OCR depende de idioma, tamanho do modelo e plataforma. Uma integração opcional pode ser pesquisada; baixar modelos ou acoplar Flutter ao núcleo Unseal não faz parte desta recomendação.
- A redação inicial desta pesquisa antecedeu as medições. O [baseline e as rodadas posteriores](baseline-2026-09-25.md) registram o que foi medido; prioridades futuras ainda dependem de novos A/B e da matriz de corpus.

---
**Uso atual:** a Seção 5 permanece como roteiro para as próximas ondas. Consulte os resultados já executados no [baseline](baseline-2026-09-25.md) antes de repetir trabalho; uma SRS pode ser produzida para qualquer recurso público novo que a investigação justificar.

**Atualização 2026-09-28:** a fatia EPUB/CBZ da sessão progressiva foi
implementada em Unseal e integrada ao Grimoire. O
[relatório A/B](../progressive-reading/ab-report-2026-09-26.md) distingue o
ganho medido até a primeira página no macOS do pico de memória ainda sem
A/B. Os emuladores Android/iOS passaram nos testes funcionais posteriores;
desempenho em aparelho físico continua pendente. As próximas duas
campanhas estão em [next-200-percent.md](next-200-percent.md), partindo
desses contratos sem repetir a implementação inicial.
