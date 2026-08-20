# 0007 — Boot fail-fast e segredos por propósito

- **Status:** aceito
- **Data:** 2026-08-20

## Contexto

A aplicação assina tokens de sessão (JWT) e cifra em repouso segredos de
terceiros — senha de SMTP e token de gateway de pagamento de cada tenant —
usando chaves lidas de variáveis de ambiente. Até esta decisão, a ausência
dessas variáveis não impedia o processo de subir: ele caía silenciosamente
para um valor padrão embutido no próprio código. Qualquer pessoa com acesso
ao código-fonte ou ao binário distribuído conhecia esse valor, e conseguia
forjar uma sessão válida ou decifrar segredos de qualquer tenant sem
comprometer nada além disso.

Havia ainda uma segunda falha, mais grave: a **mesma** chave assinava tanto
os tokens de usuários comuns (escopo "tenant", um cliente vendo os próprios
dados) quanto os tokens do painel operacional interno (escopo "plataforma",
visão administrativa sobre todos os tenants — financeiro, logs, métricas
globais). Comprometer a chave de um único cliente comprometia, na prática, a
visão administrativa da base inteira.

## Decisão

No boot, antes de aceitar qualquer conexão, a aplicação agora:

1. **Valida força e presença de cada chave de segurança.** Mínimo de 32
   bytes, e rejeita uma lista de valores conhecidos/genéricos (os fallbacks
   antigos do próprio código, e placeholders comuns como "changeme",
   "admin", "test"). Falhando qualquer verificação, o processo termina
   imediatamente com uma mensagem que ensina como corrigir — nunca sobe "no
   modo inseguro" silenciosamente.
2. **Separa as chaves por propósito.** Uma chave assina tokens de tenant,
   outra — obrigatoriamente diferente — assina tokens do painel
   administrativo, uma terceira — também diferente das outras duas — deriva
   a chave de cifra dos segredos em repouso. Reaproveitar qualquer uma delas
   em dois lugares também derruba o boot.
3. **Documenta o custo assimétrico de rotação.** A chave de sessão pode ser
   trocada a qualquer momento — o pior efeito é deslogar todo mundo, e todo
   mundo faz login de novo. Já a chave que cifra segredos de terceiros, uma
   vez usada em produção, não pode mais ser trocada sem tornar esses dados
   permanentemente ilegíveis. Por isso ela é gerada com cuidado redobrado,
   uma única vez, antes do primeiro uso real — e o `.env.example` deixa esse
   aviso explícito ao lado da variável.

## Alternativas consideradas

**Fallback + log de aviso, em vez de recusar o boot.** Descartada: um aviso
em log não é lido em produção com a disciplina necessária. "Funciona mesmo
sem configurar direito" é exatamente o modo de falha que essa decisão
elimina.

**Fail-fast só em produção, checando uma variável de ambiente tipo
`APP_ENV`.** Descartada: cria um caminho de código que só é exercitado em
produção — o único ambiente onde ninguém testa antes do primeiro deploy real.
Uma variável mal configurada reabre o problema em silêncio.

**Uma chave só para os dois escopos, com checagem de "papel" dentro do
próprio token.** Descartada: o papel/role vive dentro dos dados que o token
carrega. Quem consegue forjar a assinatura escolhe também o papel que quiser
— separar por chave é a única defesa que sobrevive ao cenário "uma chave
vazou".

**Biblioteca de configuração de terceiros (ex. Viper).** Descartada por
proporção: a validação inteira cabe em poucas dezenas de linhas usando só a
biblioteca padrão da linguagem. Adicionar uma dependência pesada — e as
dezenas de transitivas que ela traz — não se paga para este problema.

## Consequências

**Ganhos:** impossível rodar em modo inseguro por esquecimento; vazar a
chave de um tenant não abre mais o painel administrativo; a mensagem de erro
no boot ensina a corrigir na hora, então configurar errado custa segundos de
leitura, não uma investigação.

**Custos:** subir o ambiente agora exige três variáveis de ambiente geradas
corretamente — antes bastava não configurar nada, e o sistema "funcionava"
com valores padrão, inseguros mas convenientes. Documentado no
`.env.example` com o comando exato para gerar cada uma
(`openssl rand -base64 32`).
