# Decisões de arquitetura (ADRs)

Um **ADR** (Architecture Decision Record) é um registro curto de **uma** decisão
técnica: qual era o problema, o que foi decidido, o que foi descartado e qual o
preço pago. Um arquivo por decisão, numerado, nunca editado depois de aceito — se
a decisão mudar, cria-se um ADR novo que substitui o anterior.

Por que isso importa num portfólio de Platform/SRE: mostra que você **decide** em
vez de seguir tutorial. A pergunta que um entrevistador faz não é "o que você
usou", é "por que não a outra opção".

## Formato

Cada arquivo é `NNNN-titulo-em-kebab-case.md` com estas seções:

```markdown
# NNNN — Título da decisão

- **Status:** proposto | aceito | substituído por NNNN
- **Data:** AAAA-MM-DD

## Contexto
O problema. Fatos, restrições, o que existia antes.

## Decisão
O que foi decidido, em voz ativa: "Usamos X".

## Alternativas consideradas
Cada uma com o motivo real de ter sido descartada.

## Consequências
O que melhorou E o que piorou. Um ADR sem custo listado é propaganda,
não registro técnico.
```

## Índice

| # | Decisão | Status |
|---|---|---|
| [0001](0001-multi-stage-build.md) | Build multi-stage para a imagem de produção | aceito |

<!-- TODO: os próximos ADRs a escrever, em ordem de valor pra entrevista.
     O 0001 abaixo está escrito por inteiro como modelo — os outros são seus.

     0002 — Usuário não-root na imagem final
            (contexto: root do container = uid 0 do host; alternativas: rodar como
             root, usar user namespaces; consequência: precisou de mkdir+chown
             do uploads/, e COPY não obedece ao USER)

     0003 — Healthcheck + depends_on service_healthy em vez de depends_on simples
            (contexto: a corrida real que derrubava o app com log.Fatalf;
             alternativas: retry/backoff no código Go, script wait-for-it.sh;
             consequência: startup mais lento por design, ~10s de start_period)

     0004 — Volume nomeado para o Postgres
            (alternativas: bind mount de pasta local, sem volume;
             consequência: `down -v` apaga tudo, e o initdb.d só roda em volume vazio)

     0005 — Schema inicial via docker-entrypoint-initdb.d
            (contexto: a aplicação só faz ALTER TABLE incremental, não cria as
             tabelas base; consequência: re-testar exige down -v)

     0006 — Não instalar ca-certificates
            (este é o mais interessante de todos porque é uma decisão de NÃO
             fazer algo, sustentada por um teste comparativo que você rodou)

     0007 — Segredos via .env em vez de hardcoded no compose
            (alternativas: Docker secrets, secret manager na nuvem;
             consequência: .env não versionado exige .env.example + disciplina) -->
