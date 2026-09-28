# Decisão: ordem de expansão de sessões — MOBI/AZW3 (sem DRM) e CHM

Data: 2026-09-28. Status: decisão registrada após o fechamento da onda
PDF/CBR (ver `ab-report-2026-09-28.md`). O objetivo da campanha era usar os
resultados de PDF e CBR para ordenar os próximos formatos. Critério: o
**modelo de compressão do container** determinou onde a sessão ganha tempo
ou memória; a ordem abaixo segue esse preditor, validado em dois formatos.

## O que PDF e CBR ensinaram

1. **Acesso aleatório ao container é o pré-requisito** e dita o custo: PDF
   já era um grafo de objetos endereçável por offset (o `PdfDocument` só
   precisou de uma fonte de bytes); o RAR precisou de um indexador novo
   (`RarRandomAccess`, varredura de cabeçalhos sem decodificar payloads).
2. **Compressão não-streaming mata o ganho de tempo de abertura**: entradas
   method-29 do RAR decodificam inteiras (a sessão precisa decodificar para
   cheirar cada página na abertura). Resultado medido: +34% no tempo de
   abertura do CBR method-29 — a sessão ganhou memória, não tempo. Stored
   (sem compressão) abre na paridade.
3. **Materialização por unidade de leitura** (página/seção) é o que produz
   as vitórias grandes: PDFs com extração pesada (texto denso) caíram
   72–82% no tempo até primeiro conteúdo na VM e 50–72% até primeira página
   visível no leitor real, com −81…−86% de RSS de abertura.
4. **Piso fixo de sessão** (isolate/engine + amostra de plano): ~15–20 MB —
   relevante só em livros pequenos (casos que pioraram, reportados).

## Ordem decidida

**1º MOBI (PalmDoc/mobipocket, sem DRM).**
- Container: PalmDB — tabela de offsets de registros no cabeçalho; acesso
  aleatório direto, sem varredura sequencial (mais simples que RAR).
- Compressão PalmDoc é por **registro individual** (LZ77 78-style com
  estado local, sem dicionário entre registros): decodificação sob demanda
  por registro é streamable — o caso oposto ao method-29; ganho de tempo de
  abertura esperado, não só de memória.
- Unidade de leitura natural: seções/registros de texto já modelados no
  parser eager e no wire (`documentText` por seção) — a sessão reusa o
  padrão do EPUB (paths por seção) sem inventar espaço de paths novo.
- Esforço estimado: equivalente à onda CBR (indexador + guardas + gate),
  sem a complexidade de imagens do PDF.

**2º AZW3 (KF8, sem DRM).**
- Mesmo container PalmDB (o indexador do MOBI serve), mas os fluxos HUFF/CDIC
  compartilham **dicionários entre registros**: decodificar um registro sob
  demanda exige carregar o estado dos dicionários — análogo ao
  method-29/micro-dicionário do RAR. Expectativa honesta: vitória de
  **memória**, com ganho de tempo limitado (o estado dos dicionários é
  proporcional ao livro, não ao registro).
- Só faz sentido depois do MOBI (mesma fundação de indexador; a sessão
  AZW3 reusa o header/wire do MOBI).

**3º CHM.**
- Compressão LZX: janela de 32 KB+ **compartilhada ao longo do fluxo** —
  decodificar uma entrada N exige o estado da janela deixado pelas entradas
  1..N−1. É estruturalmente o caso "solid" do RAR: sessão progressiva real
  exigiria reproduzir a janela sequencialmente (sem ganho de tempo) ou
  reordenar o formato. Ganho esperado: apenas eager-em-isolate (memória no
  chamador), nunca progressivo de verdade.
- Decisão: **não implementar sessão progressiva para CHM** nesta rodada;
  reavaliar apenas se a demanda por memória em CHM grande justificar o modo
  "eager-in-worker" (isProgressive=false) previsto no design original.

## Critério de reavaliação

Se o uso real mostrar livros MOBI/AZW3 grandes dominando a biblioteca dos
usuários, a ordem acima já entrega o maior ganho primeiro. CHM permanece
fora enquanto o custo LZX não mudar (ex.: um decodificador LZX com
snapshots de janela baratos mudaria o cálculo — marcado como gatilho de
reavaliação, não como promessa).
