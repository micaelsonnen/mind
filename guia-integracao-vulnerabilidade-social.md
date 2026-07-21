# Integração — Verificação de vulnerabilidade social e vagas por empresa

Resumo de como todas as peças construídas se encaixam no projeto Puzzle que já existe.

## O que foi construído

| Arquivo | O que faz | Quem usa |
|---|---|---|
| `migration_vulnerabilidade_social.sql` | Schema do questionário (tabelas, trigger de pontuação, RLS, bucket de comprovantes) | Roda uma vez no SQL Editor |
| `migration_precificacao_social.sql` | Tabela `config_precos_sessao` (valores editáveis) e função `paciente_tem_vulnerabilidade_valida` | Roda uma vez, **antes** de `migration_vaga_social_pacientes.sql` |
| `migration_vaga_social_pacientes.sql` | Pacotes de vaga por empresa + lógica que decide `pacientes.valor_paciente` | Roda uma vez, por último |
| `reprocessamento_retroativo.sql` | Aplica a lógica de vaga a avaliações já aprovadas antes da migration existir | Roda manualmente, uma vez, só se necessário |
| `avaliacao-vulnerabilidade.html` | Questionário + upload de comprovantes | Paciente |
| `admin-revisao-vulnerabilidade.html` | Fila de revisão + aprovação/rejeição manual | Admin |
| `admin-pacotes-empresa.html` | Cadastro e gestão de pacotes de vaga por empresa | Admin |
| `snippet-aviso-vaga-social.html` | Aviso de "aguardando vaga" pra colar em qualquer tela do paciente | Paciente |

**Atenção:** `migration_pacotes_empresa.sql` foi a primeira tentativa dessa parte e ficou **obsoleta** — ela partia da premissa errada de que o subsídio seria recalculado a cada sessão. `migration_vaga_social_pacientes.sql` a substitui inteira. Se você chegou a rodar a versão antiga, o topo do arquivo novo tem os `DROP` necessários pra desfazer.

## 1. Ordem de execução

1. `migration_vulnerabilidade_social.sql`
2. `migration_precificacao_social.sql`
3. `migration_vaga_social_pacientes.sql`
4. Se já existiam avaliações aprovadas antes do passo 3: `reprocessamento_retroativo.sql`
5. Configure `SUPABASE_URL` e `SUPABASE_ANON_KEY` nos arquivos HTML (ou importe o `supabaseClient.js` compartilhado, se o projeto já tiver um)

Não existe mais nenhuma suposição sobre coluna `user_id` — todo o vínculo entre `pacientes`/`empresas` e a conta logada é feito por **e-mail** (`auth.jwt() ->> 'email'`), confirmado direto no schema real do projeto.

## 2. Onde cada peça se encaixa no site que já existe

- **`avaliacao-vulnerabilidade.html`** → link em `dashboard-paciente.html`, algo como "Verificar se você tem direito ao valor social".
- **`admin-revisao-vulnerabilidade.html`** e **`admin-pacotes-empresa.html`** → duas novas abas dentro de `admin.html`, ao lado das que já existem (aprovação de psicólogo, fila de exclusão LGPD).
- **`snippet-aviso-vaga-social.html`** → colar em `dashboard-paciente.html`, chamando `carregarAvisoVagaSocial(pacienteId)` ao carregar a página. Só aparece algo na tela quando o paciente está de fato esperando uma vaga.
- **`empresa.html`** → pode consumir a view `resumo_pacotes_empresa` pra mostrar quantas vagas cada pacote tem disponíveis/ocupadas. Não construí essa tela ainda.

## 3. Como o valor da sessão é decidido, de ponta a ponta

1. Paciente responde o questionário → pontuação calculada no banco → aprovado, em revisão, ou pendente.
2. **No momento em que o status vira `aprovado_automatico` ou `aprovado_manual`**, uma trigger reserva automaticamente uma vaga no pacote de empresa que vence primeiro (entre os que têm saldo) e seta `pacientes.valor_paciente` para o valor de coparticipação social.
3. Se não houver nenhuma vaga disponível, o paciente fica com `status_financeiro_social = 'aguardando_empresa'` e continua pagando o valor que já estava vigente (normalmente o integral) até uma vaga abrir.
4. Quando um pacote novo é criado, ou tem a vigência estendida, a fila de espera é reprocessada automaticamente (em ordem de chegada).
5. Quando um pacote expira, os pacientes que ocupavam vaga nele **não são liberados sozinhos** — é preciso rodar `liberar_vagas_expiradas()` periodicamente (sugestão de agendamento via `pg_cron` já comentada na migration).
6. `pagamentos` não recalcula nada — ele só copia o `valor_paciente` (e o subsídio da empresa, se aplicável) no momento em que a sessão é criada, como um retrato histórico.

## 4. Coisas que ainda dependem de decisão sua

- **Vaga por paciente, não por sessão.** Um pacote de 20 vagas sustenta até 20 pacientes com valor social *simultaneamente*, independente de quantas sessões cada um faça. Se a intenção real for limitar por número de sessões (créditos), a lógica de alocação muda.
- **Agendamento do `pg_cron`.** A função `liberar_vagas_expiradas()` depende de agendamento manual — ela não roda sozinha sem o `cron.schedule(...)` ser executado uma vez.
- **Revalidação periódica da avaliação.** `validade_avaliacao_meses` (padrão 6 meses) já existe em `config_precos_sessao`, mas nada notifica o paciente pra refazer o questionário quando expira — hoje ele só perde a vaga silenciosamente na próxima vez que `aplicar_valor_social_paciente` rodar.
- **Auditoria amostral das aprovações automáticas** — ainda não implementada. Vale ter uma revisão manual de uma amostra pequena e aleatória, mesmo entre aprovações automáticas, pra garantir que ninguém está só marcando caixas pra bater o limite de pontos.
- **Edição de `quantidade_vagas` de um pacote já em uso** — não incluí na tela do admin de propósito (reduzir abaixo do que já está ocupado quebra uma constraint). Só criação de pacote novo e extensão de vigência estão implementadas.

## 5. Checklist de teste antes de produção

- [ ] Paciente sem CadÚnico e renda alta → cai em `pendente`, sem aprovação automática
- [ ] Paciente com CadÚnico + Bolsa Família → pontuação soma 80, acima do limite padrão de 60 → `aprovado_automatico`
- [ ] Paciente aprovado, com pacote de empresa disponível → `status_financeiro_social = 'confirmado'` e `valor_paciente` vira o valor social, imediatamente
- [ ] Paciente aprovado, sem nenhum pacote com saldo → `status_financeiro_social = 'aguardando_empresa'`, `valor_paciente` inalterado
- [ ] Admin cria um pacote novo pra uma empresa → paciente que estava esperando é promovido a `confirmado` automaticamente, sem nenhuma ação manual além de criar o pacote
- [ ] Admin consegue abrir o comprovante do paciente (signed URL funciona e expira depois de 5 min)
- [ ] Rejeição sem observação é bloqueada no front-end
- [ ] Paciente comum (não admin) tentando acessar `admin-revisao-vulnerabilidade.html` ou `admin-pacotes-empresa.html` não vê nenhum dado (RLS bloqueando, não só o front-end escondendo)
- [ ] Dois agendamentos simultâneos disputando a última vaga de um pacote não geram inconsistência (`for update skip locked` deve garantir isso — vale testar em carga, não só manualmente)
