# Próximas duas campanhas de alto esforço

Estado em 2026-09-28. Estas são propostas para duas campanhas amplas de IA,
depois da auditoria da abertura progressiva. Cada campanha precisa produzir
código, corpus redistribuível, testes e evidência, não apenas um relatório.
As duas priorizam Unseal; Grimoire entra onde a experiência precisa ser
verificada na tela. Não há Galaxy S23 disponível nesta rodada: emuladores
Android e simulador iOS servem para testes funcionais, enquanto medições de
desempenho no Mac e Chrome têm conclusões limitadas a essas plataformas.

## Campanha 1: leitura progressiva para além de EPUB e CBZ

**Resultado para o usuário:** abrir livros grandes sem carregar e transferir
todo o conteúdo antes da primeira página, mantendo navegação, busca e
posições corretas. A sessão atual cobre EPUB e CBZ; PDF, CBR, MOBI e outros
formatos ainda precisam do caminho completo. A correção de concorrência de
sessões web desta auditoria é um pré-requisito.

1. Levantar corpus licenciado por formato e medir abertura, primeira página,
   transição, busca e memória. Priorizar PDF e CBR; usar a incidência no
   corpus para ordenar MOBI/AZW3 sem DRM e CHM. Não prometer ganho universal.
2. Definir acesso aleatório, ciclo de vida e cancelamento para cada formato;
   limitar bytes retidos por sessão, cache e mensagem. Permitir duas sessões
   simultâneas no mesmo processo e no worker web, com fechamento isolado.
3. Integrar com Grimoire sem materializar um `Book` completo para voltar ao
   leitor. Preservar ordem de leitura, links, recursos, locators, busca e
   resultados já expostos; falhas públicas devem continuar tipadas.
4. Adicionar testes de arquivos truncados, bombas de descompressão,
   cancelamento durante IO, alternância entre livros, recursos duplicados e
   regressão de memória. Verificar VM e Chrome, além do leitor real no Mac,
   Android emulado e iOS simulado.
5. Comparar baseline e candidato em rodadas alternadas no mesmo Mac e corpus,
   com série de RSS e pico retidos, tempo até página visível, p50/p95 e casos
   que pioraram. Usar emuladores para comportamento, não para reivindicar
   ganho de desempenho em celular físico.

**Entrega mínima aceitável:** PDF e CBR percorrendo uma sessão limitada em
memória, com busca e navegação reais no Grimoire, testes web/nativos,
contratos públicos documentados e A/B reproduzível. Se o corpus mostrar
outra ordem mais útil, registrar os números antes de trocar a prioridade.

## Campanha 2: acervo digitalizado em DjVu e TIFF

**Resultado para o usuário:** páginas digitalizadas que hoje não abrem ou
perdem texto e navegação passam a ser legíveis. O Unseal já lê um subconjunto
de DjVu, mas documenta lacunas em `Djbz`/`INCL`, documentos indiretos e
`TXTz`/`NAVM`; TIFF multipágina e BigTIFF seriam formatos novos.

1. Completar DjVu v3 em etapas: dicionários JB2 compartilhados, inclusão de
   componentes, texto e outline comprimidos, documentos indiretos e os
   codecs visuais restantes que aparecerem no corpus. Manter limites de
   pixels, memória, profundidade e trabalho antes da alocação.
2. Adicionar TIFF multipágina com diretórios, strips e tiles, orientação e
   compressões relevantes para livros digitalizados; estender a BigTIFF
   apenas com offsets de 64 bits seguros. Tornar páginas e texto acessíveis
   pelo modelo público e pelo leitor, sem biblioteca nativa obrigatória no
   núcleo Dart.
3. Construir corpus de origens independentes e licença clara, registrar hash
   e proveniência, comparar páginas e texto com renderizadores de referência
   sem copiar código incompatível. Incluir amostras malformadas e fuzz de
   estrutura com minimização que preserve a falha.
4. Verificar paridade visual observável em Grimoire, rotação, zoom, mudança
   de página e memória de arquivos grandes. Não confundir metadados de OCR
   com texto realmente encontrado e selecionável.

**Entrega mínima aceitável:** DjVu real com componentes compartilhados e
texto/navegação comprimidos, TIFF multipágina real, cobertura VM/Chrome e
leitura ponta a ponta. BigTIFF e codecs raros entram com uma matriz explícita
de suporte e evidência, mesmo se a cobertura total não couber na campanha.

As referências técnicas primárias são a [especificação DjVu v3](https://www.sndjvu.org/spec.html),
a [documentação de TIFF 6.0 da LibTIFF](https://libtiff.gitlab.io/libtiff/specification/)
e a [especificação BigTIFF](https://libtiff.gitlab.io/libtiff/specification/bigtiff.html).
O contrato implementado e as lacunas atuais estão em
[format-expansion.md](../../format-expansion.md) e no [README](../../../README.md).

## Alternativa para uma terceira campanha

No Grimoire, navegação por page-list/landmarks do EPUB e anotações portáveis
com reancoragem de citações são outra frente grande. Unseal já extrai a
estrutura EPUB 3; o leitor precisaria expor e testar o comportamento de
navegação e seleção. As referências são [EPUB 3.3](https://www.w3.org/TR/epub-33/)
e o [modelo de anotações W3C](https://www.w3.org/TR/annotation-model/).
