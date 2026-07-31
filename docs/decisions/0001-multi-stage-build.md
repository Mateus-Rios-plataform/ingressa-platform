# 0001 — Build multi-stage para a imagem de produção

- **Status:** aceito
- **Data:** 2026-07-24

## Contexto

A aplicação é um binário Go 1.25 que serve API e frontend estático no mesmo
processo. Para **compilar** é necessário o toolchain completo do Go — a imagem
oficial `golang:1.25-alpine` traz o compilador, o cache de módulos e as
ferramentas de build. Para **executar**, nada disso é necessário: Go produz um
executável que roda sozinho.

Se a imagem de produção fosse construída sobre a base do compilador, ela
carregaria centenas de megabytes de ferramentas que nunca são usadas em runtime —
peso de transferência a cada deploy e, mais relevante, superfície de ataque
desnecessária (compilador, gerenciador de pacotes e shell completos dentro de um
container exposto à internet).

## Decisão

Usamos um Dockerfile **multi-stage** com dois estágios:

1. **`builder`** — `FROM golang:1.25-alpine`. Compila o binário com
   `CGO_ENABLED=0 go build -o /app/servidor ./cmd/api`.
2. **final** — `FROM alpine:3.20`. Copia do estágio anterior **apenas** o binário
   e o diretório `frontend/`, via `COPY --from=builder`.

O `CGO_ENABLED=0` é parte da decisão, não um detalhe: sem ele o binário pode
ficar dinamicamente ligado à libc (musl, no Alpine) e falhar na imagem final com
`exec /app/servidor: no such file or directory` — erro que engana, porque o
arquivo existe e o que falta é a biblioteca.

## Alternativas consideradas

**Imagem única sobre `golang:1.25-alpine`.** Mais simples de escrever e de
depurar (o toolchain fica disponível dentro do container). Descartada: imagem na
faixa de centenas de MB contra 39,4 MB, e entrega em produção um compilador e um
gerenciador de pacotes que não têm função ali.

**`FROM scratch` no estágio final.** Imagem ainda menor — zero bytes de base.
Descartada por duas razões concretas: sem shell não há como inspecionar o
container em produção (`docker exec ... sh`), o que atrapalha diagnóstico real; e
`scratch` não traz store de certificados raiz, então o TLS de saída (Mercado
Pago, Stripe, SMTP) exigiria copiar o bundle de CAs do builder à mão. O Alpine
custa ~7 MB e resolve os dois.

**Compilar fora do Docker e só copiar o binário.** Build mais rápido em máquina
local. Descartada porque quebra a reprodutibilidade: o build passaria a depender
da versão de Go instalada em cada máquina, e o mesmo Dockerfile deixaria de
funcionar sozinho num runner de CI.

## Consequências

**Positivas**

- Imagem final de **39,4 MB** (medido com `docker images`).
- O toolchain de build nunca chega ao ambiente de produção.
- O build é reprodutível a partir do repositório, sem Go instalado na máquina.

**Negativas / preço pago**

- O Dockerfile fica mais longo e exige entender `COPY --from`, que não é óbvio
  para quem lê pela primeira vez.
- Diagnosticar falha de compilação é menos direto: o erro acontece dentro de um
  estágio intermediário que não é o container final.
- A ordem das instruções passa a ser crítica para o cache. `COPY go.mod go.sum` +
  `go mod download` precisam vir **antes** de `COPY . .`, senão qualquer mudança
  de código refaz o download de todas as dependências. Isso é uma restrição
  permanente sobre como o arquivo pode ser reorganizado.
- O estágio `builder` roda como root deliberadamente (o usuário não-root só
  existe no estágio final) — caso contrário `go mod download` e `go build` não
  conseguem escrever em `/go/pkg`. Ver ADR 0002.
