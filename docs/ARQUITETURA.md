# Arquitetura do Ingressa

> Documento de orientação: o que o sistema é, como está montado hoje e por que
> as decisões foram tomadas assim. Serve como mapa antes de mexer em qualquer
> parte (e como base para o README/documentação de portfólio mencionados no
> plano de carreira).

## 1. O que é o Ingressa

Um **SaaS multi-tenant de inscrições para eventos** (público-alvo: igrejas e
associações). Cada "tenant" (empresa/associação) tem sua própria conta, seus
próprios eventos, inscritos, configurações de pagamento e de e-mail — tudo
isolado dos outros tenants no mesmo banco de dados.

Fluxo de negócio central:
1. Uma empresa se cadastra (`/api/v1/auth/register`) e ganha um `tenant_id`.
2. Ela cria eventos, define lotes de ingressos (preço, capacidade, datas).
3. Publica um link público do evento; qualquer pessoa se inscreve sem login.
4. A inscrição pode gerar cobrança (Mercado Pago/Stripe) e dispara e-mails.
5. No dia do evento, a equipe faz check-in por QR Code.
6. A empresa acompanha tudo em um painel administrativo (dashboard, lista de
   inscritos, relatórios).

Existe ainda uma **segunda aplicação dentro do mesmo binário**: a *Central
DevOps* (`/dev-*.html`, rotas `/api/v1/dev/*`), um painel de nível
"plataforma" (não por tenant) para quem opera o Ingressa em si — avisos
globais, financeiro da plataforma, erros/logs, estatísticas agregadas.

## 2. Visão macro

```
                         ┌───────────────────────────────┐
   Navegador ───────────▶│   Go net/http (1 processo)    │
   (HTML/JS puro,        │                               │
   sem framework)        │  mux "/"      → arquivos      │
                         │               estáticos       │
                         │  mux "/api/"  → API tenant    │
                         │               (AuthMiddleware)│
                         │  mux "/api/v1/dev/" → API     │
                         │               DevOps          │
                         │  mux "/media/"→ uploads       │ 
                         └─────────────┬─────────────────┘
                                       │ pgx pool
                                       ▼
                            ┌─────────────────────┐
                            │   PostgreSQL 16     │
                            │  (1 instância única,│
                            │  schema "main" +    │
                            │  schema "logs" nas  │
                            │  mesmas tabelas)    │
                            └─────────────────────┘
```

Tudo roda em **um único processo Go** que serve a API e o frontend estático ao
mesmo tempo (não há build step de frontend, não há servidor separado). Isso é
uma escolha deliberada de simplicidade: um binário, um deploy, sem
orquestração entre serviços — trade-off comum em projetos que ainda não
precisam escalar horizontalmente.

## 3. Backend (Go)

### 3.1 Layout de pastas

```
cmd/api/main.go         → ponto de entrada: monta as rotas e sobe o servidor
internal/handler/       → um arquivo por área de negócio (events.go, lots.go,
                           inscriptions.go, payments.go, company.go, dev.go...)
internal/middleware/    → AuthMiddleware, DevAuthMiddleware, TenantMiddleware
internal/auth/          → geração/validação de JWT
internal/crypto/        → AES-GCM para segredos por tenant (senha SMTP, token de gateway)
internal/payments/      → abstração de gateway (Mercado Pago, Stripe)
internal/mailer/        → envio de e-mail via SMTP configurado por tenant
internal/database/      → conexão (pgx pool), auto-migrations, e código gerado pelo sqlc
  ├── sql/               → schema_main.sql, schema_logs.sql, query_*.sql (fonte da verdade)
  ├── dbmain/             → código Go gerado pelo sqlc a partir de schema_main + query_main
  └── dblogs/             → código Go gerado pelo sqlc a partir de schema_logs + query_logs
```

O uso de `internal/` é proposital (ver `.agents/rules/regras.md`): esse
código não pode ser importado por outro módulo Go, então a lógica de negócio
fica "trancada" dentro do próprio projeto.

### 3.2 Roteamento

`main.go` usa só a biblioteca padrão (`net/http.ServeMux`), sem framework
(Gin/Echo/Chi). Ele monta **três sub-roteadores** e os pluga no roteador
principal com prefixos diferentes:

- `/api/*` → passa pelo `AuthMiddleware` (exige JWT de usuário comum) antes de
  chegar nos handlers de evento, inscrição, pagamento, etc.
- `/api/v1/dev/*` → passa pelo `DevAuthMiddleware` (exige JWT com `role ==
  "devops"`) — painel separado, mesmo processo.
- Um punhado de rotas fica **fora** de qualquer middleware porque são
  públicas por natureza: login/registro, listagem pública de evento por slug,
  criação de inscrição, consulta de inscrição, webhook de pagamento.

Por que sem framework: o Go 1.22+ já tem roteamento por método
(`"GET /v1/events/{id}"`) na biblioteca padrão, então um framework HTTP
adicionaria uma dependência sem resolver um problema que o `net/http` não
resolve sozinho aqui.

### 3.3 Autenticação e multi-tenancy — a decisão mais importante do projeto

Cada usuário logado carrega um JWT com `user_id`, `tenant_id` e `role`
(`internal/auth/jwt.go`). O `AuthMiddleware` **decodifica o tenant a partir do
próprio token**, nunca de um header enviado pelo cliente — isso existe porque
antes o tenant vinha do header `X-Association-ID`, que qualquer cliente podia
forjar para tentar ler dados de outra empresa. Hoje esse header ainda é
enviado pelo frontend (`api-auth.js`) por compatibilidade, mas o middleware
ignora e usa só o que está assinado no JWT — a fonte de verdade é
criptográfica, não um valor solto na requisição.

Isolamento entre empresas (multi-tenant) acontece em duas camadas, com uma
inconsistência conhecida entre elas:
1. **Filtro explícito por `tenant_id`** em toda query (`WHERE tenant_id = $1`)
   — é isso que garante o isolamento **de fato** hoje.
2. **Row-Level Security (RLS)** do Postgres, ativado nas tabelas
   `users/events/inscriptions/districts/churches/tenant_settings`. Na teoria,
   mesmo que uma query esquecesse o filtro, o próprio banco bloquearia. Na
   prática **essa camada está inerte**: a aplicação conecta como
   owner/superuser do Postgres (`admin`), e donos de tabela sempre pulam RLS
   por padrão no Postgres. Ou seja: a política existe no schema, mas não
   protege nada ainda — é uma dívida técnica conhecida, não um bug escondido.

### 3.4 Central DevOps — por que é um segundo "app" dentro do mesmo binário

As rotas `/api/v1/dev/*` deliberadamente **não** usam tenant/RLS: são a visão
"deus" de quem opera a plataforma (todos os tenants), autenticada com um
`role: "devops"` separado (`dev_users`, tabela própria, seed automático via
`DEV_ADMIN_USER`/`DEV_ADMIN_PASS`). Ficou no mesmo processo por simplicidade
de deploy (um único binário), mas o *schema* já foi desenhado pensando em
separar (`schema_logs.sql` tem um comentário explícito dizendo que deveria
rodar "preferencialmente em um database separado"). Hoje, na prática, tanto o
schema "main" quanto o "logs" moram na mesma instância de Postgres — a
separação lógica existe no design, a separação física ainda não foi feita.

### 3.5 Banco de dados

- **pgx/v5** como driver (pool de conexões, sem `database/sql` genérico).
- **sqlc** gera código Go tipado a partir de SQL puro (`internal/database/sql/*.sql`
  → `dbmain`/`dblogs`), em vez de um ORM — decisão de segurança e performance:
  SQL explícito é mais fácil de auditar contra SQL injection do que um ORM que
  permite query building dinâmico.
- **Auto-migrations idempotentes** rodam no boot (`db.go`, com `ALTER TABLE
  ... ADD COLUMN IF NOT EXISTS` e `CREATE TABLE IF NOT EXISTS`) em vez de um
  sistema de migração formal (ex.: `golang-migrate`). É rápido para iterar
  sozinho, mas não guarda histórico de versões do schema nem permite rollback
  — outra dívida técnica deliberada em troca de velocidade.
- Tabelas centrais: `tenants`, `users`, `events`, `ticket_lots`,
  `inscriptions`, `transactions` (schema principal) e `dev_users`,
  `system_logs`, `system_broadcasts`, `apm_errors`, `platform_expenses`
  (operação da plataforma).

### 3.6 Segurança aplicada

- Senhas de usuário e de DevOps: `bcrypt`.
- Segredos por tenant (senha SMTP, token do gateway de pagamento): **AES-256-GCM**
  (`internal/crypto`), com chave derivada de `SETTINGS_ENC_KEY`. Ao devolver
  configurações pro frontend, o valor é mascarado (`********`), nunca decifrado
  de volta pra tela — só a aplicação usa o valor real internamente.
- CPF é a "chave" do participante (não há senha do lado público) — por isso é
  sanitizado antes de qualquer consulta.
- `govulncheck`/auditoria de dependências é regra declarada
  (`backend_rules.md`), embora não esteja automatizada em CI ainda (não há
  pipeline de CI hoje — é justamente uma das próximas etapas do roadmap de
  carreira).

### 3.7 Pagamentos e notificações — configuração por tenant, não global

Cada empresa configura **seu próprio** gateway (Mercado Pago ou Stripe) e
**seu próprio** SMTP em `configuracoes.html`, salvo criptografado em
`tenant_settings`. O motivo: é um SaaS multi-tenant — a empresa A não pode
usar a conta de pagamento da empresa B, nem enviar e-mail em nome dela.
`internal/payments` define uma interface `Gateway` mínima
(`CreateCheckout`) e cada provedor implementa a sua — trocar/adicionar um
gateway novo não exige tocar no handler HTTP.

O webhook de pagamento (`/api/v1/webhooks/payments`) é público de propósito —
o gateway externo não tem como mandar um JWT nosso — e atualiza a transação
pela referência do gateway, sem escopo de tenant (é uma operação de sistema).

## 4. Frontend

HTML/CSS/JS **estático e puro**, sem framework nem build step — servido
diretamente pelo `http.FileServer` do próprio Go (`frontend/src`). Cada tela
tem, deliberadamente, **duas versões** (`*-desktop.html` / `*-mobile.html`,
mais uma versão "roteadora" sem sufixo) em vez de um único layout responsivo —
convenção definida em `.agents/rules/regrasgerais.md`, seguindo os mockups da
pasta `inspiracao/`.

Dois scripts globais merecem destaque:
- `api-auth.js`: intercepta `window.fetch` e injeta automaticamente
  `Authorization: Bearer <token>` e `X-Association-ID` em toda chamada
  `/api/` protegida — nenhuma página individual precisa montar headers na
  mão. Também guarda o `id` do evento atual em `sessionStorage` ("id
  grudento") para não se perder ao navegar entre telas de gestão.
- `help-button.js`: injeta um botão flutuante de ajuda ligado à wiki
  `central-ajuda.html` em quase todas as páginas administrativas.

## 5. Docker hoje

O caminho principal é `docker compose up --build`: sobe a aplicação **e** o banco
do zero, sem nenhum passo manual.

### 5.1 Dockerfile

Build multi-stage: `golang:1.25-alpine` compila → `alpine:3.20` executa.

- **Estágio `builder`** — copia `go.mod`/`go.sum` e roda `go mod download`
  **antes** de copiar o código, para que editar o código não invalide o cache do
  download. Compila com `CGO_ENABLED=0`, gerando um binário estático que não
  depende da libc do sistema (sem isso, o binário pode falhar na imagem final
  com `exec: no such file or directory`).
- **Estágio final** — cria o usuário sem privilégio `ingressa` (uid 1000, grupo
  `ingressagroup`), define `WORKDIR /app` e, **antes** de trocar de usuário, cria
  `uploads/` já com o dono correto. Isso é necessário porque `COPY` sempre grava
  como `root:root` e ignora o `USER` — sem o `mkdir`+`chown`, o processo não
  conseguiria gravar as imagens de capa de evento em runtime.
- Só o binário e `frontend/` atravessam para a imagem final. O toolchain do Go
  fica para trás. **Imagem final: 39,4 MB.**
- **`ca-certificates` não é instalado, por decisão verificada**: a base
  `alpine:3.20` já traz `ca-certificates-bundle`, então o TLS de saída (Mercado
  Pago, Stripe, SMTP) valida sem instalar nada. Um build comparativo confirmou —
  a linha custava 1,8 MB e não resolvia nada. Ela é obrigatória em `FROM scratch`
  e nas imagens `-slim` do Debian, não nesta base.

### 5.2 `.dockerignore`

Mantém fora do build context o que é pesado (`.git/`, `inspiracao/`), o que não é
código-fonte (`uploads/`, `scripts/`, docs) e o que é segredo (`.env`, `*.env`).
O `.git/` importa por um motivo específico além do peso: todo commit o altera, o
que invalidaria a camada `COPY . .` e forçaria recompilação mesmo sem mudança em
Go.

### 5.3 docker-compose.yml

Dois serviços:

| Serviço | Imagem | Portas | Observações |
| ------- | ------ | ------ | ----------- |
| `app`   | build do Dockerfile local | `8090→8080` | recebe `DB_URL`, `JWT_SECRET` e `SETTINGS_ENC_KEY` do ambiente |
| `db`    | `postgres:16-alpine` | não publicada | acessível apenas pela rede interna do Compose |

Três decisões fazem a stack funcionar:

1. **Volume nomeado `db_data`** montado em `/var/lib/postgresql/data`. Os dados
   sobrevivem a `docker compose down` e ao restart do container; só são apagados
   com `down -v`, explicitamente.
2. **Healthcheck + `depends_on: condition: service_healthy`.** O `pg_isready`
   verifica se o Postgres aceita conexão antes de o Compose liberar a aplicação.
   Sem isso a aplicação subia primeiro, não achava o banco e morria com
   `log.Fatalf` — uma condição de corrida real. O `depends_on` curto não resolve:
   ele espera o container **iniciar**, não o serviço ficar **pronto**.
3. **Schema inicial via `/docker-entrypoint-initdb.d/`.** O `schema_main.sql` é
   montado read-only nessa pasta; a imagem oficial do Postgres executa scripts
   dali **apenas quando o volume está vazio** (primeiro boot). As tabelas base e
   as extensões (`uuid-ossp`, `pgcrypto`) nascem daí — a aplicação só aplica
   migrações incrementais (`ALTER TABLE`), ela não cria o schema do zero. Para
   re-testar a criação, é preciso `docker compose down -v` antes.

A aplicação encontra o banco pelo **nome do serviço** (`db`) e pela porta
**interna** (`5432`) — dentro da rede do Compose cada serviço tem DNS próprio.

### 5.4 Configuração e segredos

Nenhuma credencial no `docker-compose.yml`: ele referencia `${DB_USER}`,
`${DB_PASSWORD}`, `${JWT_SECRET}`, etc., resolvidas a partir de um `.env` local
que não é versionado. O `.env.example` documenta quais variáveis existem, com que
consequência, sem revelar valor nenhum.

A injeção de `JWT_SECRET` foi verificada de ponta a ponta por uma rotação de
segredo: token válido (`200`) → troca da chave e recriação do container (`401`
com o mesmo token) → restauração e login novo (`200`). O `401` prova que quem
assina é a variável de ambiente, e não o valor embutido no código.

> `docker compose restart` não relê o `.env`. Só `--force-recreate` aplica
> variáveis novas.

### 5.5 Consequência para o fluxo de desenvolvimento local

O serviço `db` **não publica porta para o host**. Isso é correto do ponto de vista
de superfície de exposição, mas quebrou o fluxo híbrido antigo (`docker compose up
-d db` + `go run ./cmd/api` na máquina), porque o `run.sh` espera o banco em
`localhost:15432`. Hoje há dois caminhos, e é preciso escolher conscientemente:

- **Tudo em container** (`docker compose up --build`) — o caminho documentado.
- **API na máquina** — exigiria publicar a porta do `db` no compose e apontar
  `DB_HOST`/`DB_PORT` para `localhost`. Ver seção 6.

## 6. O que falta / dívidas técnicas conhecidas

- RLS habilitado no schema mas inerte (conexão como owner do Postgres bypassa).
- Sem CI/CD, sem testes de integração com banco real, sem pipeline de deploy.
- `JWT_SECRET` e `SETTINGS_ENC_KEY` vêm do ambiente, mas a aplicação **aceita
  subir sem elas**, caindo num valor embutido no código em vez de recusar a
  inicialização. Compare com o `DB_URL`: configurado errado, ele derruba o
  processo em segundos e o erro é evidente. Uma chave de segurança ausente passa
  despercebida — tudo funciona, com um segredo conhecido.
- Fluxo de desenvolvimento com a API fora do container está quebrado: o `db` não
  publica porta e o `run.sh` procura `localhost:15432` (ver 5.5).
- `uploads/` é estado local do container. Com mais de uma réplica, um upload
  feito numa instância não existe nas outras — é o bloqueio real para escalar
  horizontalmente.
- Algumas telas de frontend são mockup estático, não conectadas à API:
  `gerenciamento-empresa*.html`, telas `dev-*` (exceto os endpoints que já
  existem no backend), falta página de check-in.
- WhatsApp não implementado (só e-mail).
- Fluxo público de pagamento na inscrição não conectado de ponta a ponta
  (checkout hoje é endpoint protegido, não plugado na tela pública de
  inscrição).
- Sem observabilidade real (Prometheus/Grafana) — hoje "métricas" são só as
  tabelas `apm_errors`/`system_logs` gravadas manualmente pela aplicação.

A ordem sugerida de evolução para os itens acima é
**Docker → IaC → CI/CD → Observabilidade**: containerizar primeiro (feito),
depois declarar a infraestrutura, automatizar o deploy e só então instrumentar.
Cada etapa depende da anterior — não há o que automatizar num deploy que ainda
não é reproduzível, nem o que monitorar num ambiente que muda a cada implantação
manual.

As decisões desta seção em formato longo, com alternativas descartadas e o preço
pago por cada escolha, estão em [`docs/decisions/`](./decisions/).
