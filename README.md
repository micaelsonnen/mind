# Puzzle — Plataforma de Psicoterapia Acessível

> Antes chamado "Mind" — rebrand completo para **Puzzle** (logo, textos, e-mails, PDFs gerados). HealthTech com financiamento tripartite (empresa + paciente + psicólogo) e prontuário estruturado sem IA. Stack: HTML/CSS/JS vanilla + Supabase (Postgres + Auth + Storage + pg_cron + pg_net) + Chart.js + jsPDF + Daily.co (vídeo).

Este README reflete o estado do projeto até a integração de videochamada. Serve como ponto de partida para quem continuar o desenvolvimento.

---

## 1. Modelo de negócio (resumo)

- **Empresa** patrocina parte da sessão (R$40) via programa ESG, sem acesso a nenhum dado clínico individual — só indicadores agregados.
- **Paciente** paga coparticipação (R$10/sessão).
- **Psicólogo** recebe R$50/sessão e paga mensalidade (R$120) pela plataforma.
- **Prontuário inteligente** = estruturação dos registros feitos pelo próprio psicólogo. **Sem IA, sem NLP, sem processamento automático de linguagem** — decisão de produto deliberada, reforçada na política de privacidade.
- **Sessões clínicas** acontecem por videochamada embutida na própria plataforma (Daily.co por trás), não em app de terceiro separado.

---

## 2. Estrutura de páginas

| Página | Público | Função |
|---|---|---|
| `index.html` | Todos | Landing page, botão **"Faça parte"** (escolha paciente/psicólogo) + modal de login |
| `login.html` | Todos | Login único (detecta o papel pelo e-mail — inclusive admin) |
| `cadastro-paciente.html` | Paciente | Autocadastro / ativação de conta |
| `cadastro-psicologo.html` | Psicólogo | Cadastro completo (4 abas) + upload de documentos + idiomas + toggle de perfil público |
| `cadastro-status.html` | Psicólogo | Status da análise do cadastro (pendente/aprovado/rejeitado + motivo) |
| `contratos.html` / `contrato-prestacao-servicos.html` | Psicólogo | Contrato de prestação de serviço (3 documentos: termos, privacidade, contrato) |
| `psicologos.html` | Público | Vitrine/listagem de psicólogos, URLs com slug amigável |
| `psicologo.html` | Público | Perfil público + agendamento real com disponibilidade semanal + contador de atendimentos |
| `novo-paciente.html` | Psicólogo | Cadastro manual de paciente (com anamnese) |
| `paciente.html` | Psicólogo | Ficha clínica completa — anamnese, hipótese diagnóstica versionada, linha do tempo, autorização de suporte técnico |
| `dashboard-paciente.html` | Paciente | Progresso, linha do tempo, sessões (com botão de entrar na sessão de vídeo), pagamento |
| `dashboard-psicologo.html` | Psicólogo | Visão geral, pacientes, agenda, **atendimentos** (histórico consolidado), **horários** (disponibilidade semanal + ausências + visibilidade), financeiro (particular vs. corporativo) |
| `sala-video.html` | Psicólogo/Paciente | Sala de videochamada embutida (Daily.co) |
| `plano.html` | Psicólogo | Assinatura da plataforma |
| `empresa.html` | Empresa | Dashboard agregado + relatórios em PDF |
| `admin.html` | Admin (tabela `admins`) | 6 abas: Visão Geral, Psicólogos, Pacientes, Empresas, Aprovações (com gate de pagamento), Exclusões LGPD |
| `meus-dados.html` | Todos (inclusive admin) | Autoatendimento LGPD (baixar dados / pedir exclusão) |
| `politica-de-privacidade.html`, `termos-de-uso.html` | Público | Documentos legais, com seção de subprocessadores (Supabase/Daily.co/Resend) |

---

## 3. Migrações SQL — rodar NESTA ORDEM no SQL Editor do Supabase

| # | Arquivo | O que faz |
|---|---|---|
| 1 | `migration_seguranca_critica.sql` | RLS em todas as tabelas + views agregadas anônimas para empresa |
| 2 | `migration_paciente_selfservice.sql` | Paciente pode criar a própria ficha |
| 3 | `migration_prontuario_inteligente.sql` | Cria `anamneses`, `hipoteses_diagnosticas`, `intercorrencias` + colunas de funcionamento em `sintomas` |
| 4 | `migration_visibilidade_intercorrencia.sql` | Campo `visivel_paciente` — intercorrência nasce privada |
| 5 | `migration_varredura_geral.sql` | Cria `avaliacoes`, `mensalidades_psicologos` + ~25 colunas que faltavam em `psicologos` |
| 6 | `seed_dados_fantasia.sql` | *(opcional)* dados fictícios ligados a uma conta real existente |
| 7 | `seed_login_demo.sql` | *(opcional)* trio de demo com login: empresa + psicóloga + paciente |
| 8 | `migration_admin_aprovacao.sql` | Bucket privado de documentos + policies de admin (e-mail fixo, superado pela 11) |
| 9 | `migration_exclusao_lgpd.sql` | Fila de solicitações de exclusão de conta |
| 10 | `migration_lembretes_email.sql` | Lembrete de sessão (24h antes) + confirmação de agendamento via Resend |
| 11 | `migration_admin_role.sql` | Cria tabela `admins` de verdade — substitui o e-mail fixo nas policies |
| 12 | `migration_admin_metricas.sql` | *(parcialmente superada pela 13)* primeira tentativa de métricas agregadas pro admin |
| 13 | `migration_acesso_clinico_autorizado.sql` | **Corrige** a 12: admin só vê prontuário clínico com autorização explícita do psicólogo, por paciente, com prazo. Métricas viram função agregada sem expor linha clínica |
| 14 | `migration_endereco_foto.sql` | Endereço completo + foto/logo pras 3 entidades + bucket público `fotos-perfil` |
| 15 | `migration_rebrand_puzzle_emails.sql` | Atualiza os e-mails automáticos (já publicados) de "Mind" pra "Puzzle" |
| 16 | `migration_agenda_perfil_slug.sql` | Disponibilidade semanal real, toggle de perfil público/oculto, slug de URL amigável |
| 17 | `migration_atendimentos_idiomas.sql` | Contador público de atendimentos (função segura) + campo idiomas |
| 18 | `migration_confirmacao_pagamento.sql` | Confirmação manual de pagamento antes da aprovação do psicólogo |
| 19 | `migration_video_daily.sql` | **Primeira versão** da integração de vídeo — tinha bug de arquitetura (ver seção 5), **superada pela 20** |
| 20 | `migration_video_daily_fix.sql` | **Versão corrigida** da integração de vídeo — usar esta, não a 19 |

⚠️ Todas idempotentes na parte de schema, exceto os **seeds (6 e 7)** — rodar duas vezes duplica dados fictícios.

---

## 4. O que foi implementado, por área

### Rebranding (Mind → Puzzle)
Nome, logo (`puzzle-logo.webp`), textos, PDFs gerados, e-mails automáticos — em todos os arquivos HTML e nas funções SQL já publicadas.

### Prontuário inteligente
Anamnese editável, hipótese diagnóstica versionada, linha do tempo consolidada (sessões + hipóteses + intercorrências), visível ao psicólogo (completo) e ao paciente (leitura, com nota interna vs. compartilhada).

### Agendamento e agenda
- Conflito de horário checado no banco, não só no front-end
- **Disponibilidade semanal real**: blocos por dia da semana + duração da sessão, horários gerados automaticamente
- **Ausências**: bloqueio de período (férias, licença)
- Fallback automático pro sistema antigo (manhã/tarde/noite) pra quem não configurou a agenda nova
- Solicitação → aceitar/recusar pelo psicólogo → vira sessão de verdade

### Perfil público do psicólogo
Slug de URL amigável (com fallback pro `?id=`), toggle público/oculto, contador de atendimentos (via função segura), idiomas/especialidades/temas como tags.

### Financeiro do psicólogo
Quebra particular vs. corporativo, filtro por mês/tipo. Aba **Atendimentos** nova: histórico consolidado de todas as sessões, com busca e filtros.

### Relatórios da empresa
4 PDFs reais (jsPDF), só com views agregadas, nunca dado clínico.

### Admin — de "e-mail fixo" pra papel de verdade
Tabela `admins` própria. Login reconhece o papel automaticamente. 6 abas, incluindo edição de perfil (endereço, foto/logo) e **gate de pagamento manual** na aprovação. **Acesso a prontuário clínico só com autorização explícita** do psicólogo, por paciente, com prazo de 7 dias — bloqueado por RLS, não só por regra de interface.

### LGPD
`meus-dados.html` (baixar dados / solicitar exclusão), fila de exclusão revisada por humano (retenção obrigatória de 5 anos, Res. CFP 6/2019), seção de Subprocessadores na política de privacidade, contrato revisado contra Art. 7º da Res. CFP nº 09/2024.

### Videochamada interna (Daily.co)
Sala criada sob demanda, privada, gravação desligada por padrão, expira 3h após a sessão, só psicólogo e paciente daquela sessão específica entram. Botão "🎥 Entrar na sessão" nos dois dashboards.

### Segurança
XSS corrigido em 8 arquivos (~70 pontos), bucket de documentos privado com signed URL, chave `service_role` nunca exposta, chaves de API (Resend, Daily.co) no Vault do Supabase.

---

## 5. ⚠️ Lição de arquitetura importante (pra integrações futuras)

A primeira versão do vídeo (`migration_video_daily.sql`) tentava, numa única função SQL, disparar uma chamada HTTP via `pg_net` e **esperar a resposta num loop, tudo dentro da mesma transação**. Isso nunca funciona: o worker do `pg_net` só processa pedidos de transações já commitadas, e a transação da função só commita quando ela termina — que não acontecia até ver a resposta. Impasse circular, timeout garantido sempre, independente de rede/chave/conta.

**A correção** (`migration_video_daily_fix.sql`) separa em duas chamadas distintas, cada uma sua própria transação: uma que **dispara** (retorna na hora) e outra que o **navegador consulta repetidamente** até a resposta aparecer. Esse é o padrão a seguir para qualquer chamada HTTP futura via `pg_net` que precise do corpo da resposta de volta.

Detalhe operacional: depois de ativar `pg_net`, o worker às vezes só sobe de verdade depois de um **restart do projeto** (Project Settings → General → Restart project).

---

## 6. Contas de demonstração (se rodou `seed_login_demo.sql`)

| Papel | E-mail | Senha |
|---|---|---|
| Empresa | `empresa.demo-mind@example.com` | `MindDemo123!` |
| Psicóloga | `psicologa.demo-mind@example.com` | `MindDemo123!` |
| Paciente | `paciente.demo-mind@example.com` | `MindDemo123!` |

(Os e-mails mantêm o sufixo técnico `demo-mind` de propósito — são só identificadores internos, não renomeados no rebranding pra não quebrar contas já criadas.)

Admin: tabela `admins`, hoje inclui `admin.demo-mind@example.com`. Promover/remover é só `insert`/`delete` nessa tabela.

---

## 7. Setup pendente fora do código

- [ ] **Daily.co**: adicionar cartão de pagamento (`dashboard.daily.co` → Billing) — sem ele a chamada de vídeo não abre, mesmo a API de criar sala/token funcionando
- [ ] **Resend**: verificar domínio próprio, trocar `onboarding@resend.dev` pelo remetente real
- [ ] Confirmar se `pg_net`/`pg_cron` continuam ativos após qualquer restart — `select * from cron.job;`
- [ ] Rate limiting e backup — conferir no painel do Supabase
- [ ] "Confirm email" no Supabase Auth — nunca confirmado nesta conversa

## 8. Pendências de negócio

- Pagamento real com split (pós-CNPJ/conta PJ)
- DPAs formais com Supabase/Daily.co/Resend antes de dado real de produção
- RIPD e DPO formal
- Revisão jurídica final do contrato (foro) e dos subprocessadores

---

## 9. Modelo de dados (tabelas principais)

`psicologos` · `pacientes` · `empresas` · `sessoes` (+ `video_room_url/name`) · `sintomas` · `pagamentos` · `agendamentos` · `anamneses` · `hipoteses_diagnosticas` · `intercorrencias` · `avaliacoes` · `mensalidades_psicologos` · `solicitacoes_exclusao` · `admins` · `autorizacoes_suporte` · `disponibilidade_semanal` · `ausencias`

Todas com RLS habilitado. Psicólogo vê/edita seus próprios pacientes; paciente vê a própria ficha; empresa só vê views agregadas anônimas; admin vê dados de conta sempre, dado clínico só com autorização explícita por paciente.
