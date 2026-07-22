


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "unaccent" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."admin_metricas_gerais"() RETURNS TABLE("total_sessoes_realizadas" bigint, "faturamento_psicologos" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not exists (select 1 from admins a where a.email = auth.jwt() ->> 'email') then
    raise exception 'acesso negado';
  end if;

  return query
    select
      count(*) filter (where status = 'realizada'),
      coalesce(sum(valor_psicologo) filter (where status = 'realizada'), 0)
    from sessoes;
end;
$$;


ALTER FUNCTION "public"."admin_metricas_gerais"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."alocar_valor_sessao"("p_paciente_id" "uuid") RETURNS TABLE("valor_paciente" numeric, "valor_empresa" numeric, "valor_repasse_psicologo" numeric, "pacote_id" "uuid", "status_financeiro" "text")
    LANGUAGE "plpgsql"
    AS $$
declare
  v_config record;
  v_tem_vulnerabilidade boolean;
  v_pacote record;
begin
  select * into v_config from config_precos_sessao where id = 1;
  v_tem_vulnerabilidade := paciente_tem_vulnerabilidade_valida(p_paciente_id);

  -- sem aprovação de vulnerabilidade válida -> paga valor integral,
  -- não disputa vaga de pacote nenhum
  if not v_tem_vulnerabilidade then
    return query select
      v_config.valor_sessao_integral,
      0.00::numeric,
      v_config.valor_repasse_psicologo,
      null::uuid,
      'confirmado'::text;
    return;
  end if;

  select * into v_pacote
  from pacotes_empresa
  where sessoes_utilizadas < quantidade_sessoes
    and vigencia_fim >= current_date
  order by vigencia_fim asc
  for update skip locked
  limit 1;

  if v_pacote is null then
    -- nenhum pacote de empresa com saldo disponível agora
    return query select
      null::numeric,
      null::numeric,
      null::numeric,
      null::uuid,
      'aguardando_empresa'::text;
    return;
  end if;

  update pacotes_empresa
  set sessoes_utilizadas = sessoes_utilizadas + 1
  where id = v_pacote.id;

  return query select
    v_config.valor_copagamento_social,
    v_config.valor_subsidio_empresa,
    v_config.valor_repasse_psicologo,
    v_pacote.id,
    'confirmado'::text;
end;
$$;


ALTER FUNCTION "public"."alocar_valor_sessao"("p_paciente_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."aplicar_valor_social_paciente"("p_paciente_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_config record;
  v_valido boolean;
  v_paciente record;
  v_pacote record;
begin
  select * into v_config from config_precos_sessao where id = 1;
  v_valido := paciente_tem_vulnerabilidade_valida(p_paciente_id);

  select * into v_paciente from pacientes where id = p_paciente_id for update;

  -- caso 1: não tem (ou perdeu) aprovação válida -> libera a vaga, se tinha
  if not v_valido then
    if v_paciente.pacote_ativo_id is not null then
      update pacotes_empresa set vagas_ocupadas = vagas_ocupadas - 1
      where id = v_paciente.pacote_ativo_id;
    end if;

    update pacientes
    set pacote_ativo_id = null,
        status_financeiro_social = 'nenhum',
        aguardando_desde = null,
        valor_paciente = v_config.valor_sessao_integral
    where id = p_paciente_id;
    return;
  end if;

  -- caso 2: já tem vaga confirmada, e o pacote ainda está vigente -> nada a fazer
  if v_paciente.pacote_ativo_id is not null then
    select * into v_pacote from pacotes_empresa where id = v_paciente.pacote_ativo_id;

    if v_pacote.vigencia_fim >= current_date then
      return;
    end if;

    -- pacote expirou: libera antes de tentar realocar
    update pacotes_empresa set vagas_ocupadas = vagas_ocupadas - 1 where id = v_pacote.id;
    update pacientes set pacote_ativo_id = null where id = p_paciente_id;
  end if;

  -- caso 3: aprovado, sem vaga -> tenta reservar uma (prioriza pacote que vence primeiro)
  select * into v_pacote
  from pacotes_empresa
  where vagas_ocupadas < quantidade_vagas
    and vigencia_fim >= current_date
  order by vigencia_fim asc
  for update skip locked
  limit 1;

  if v_pacote is null then
    update pacientes
    set status_financeiro_social = 'aguardando_empresa',
        aguardando_desde = coalesce(aguardando_desde, now()),
        pacote_ativo_id = null
        -- valor_paciente não é mexido aqui de propósito: fica com o que
        -- já estava (normalmente o integral), até uma vaga liberar
    where id = p_paciente_id;
    return;
  end if;

  update pacotes_empresa set vagas_ocupadas = vagas_ocupadas + 1 where id = v_pacote.id;

  update pacientes
  set pacote_ativo_id = v_pacote.id,
      status_financeiro_social = 'confirmado',
      aguardando_desde = null,
      valor_paciente = v_config.valor_copagamento_social
  where id = p_paciente_id;
end;
$$;


ALTER FUNCTION "public"."aplicar_valor_social_paciente"("p_paciente_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calcular_pontuacao_vulnerabilidade"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_pontos int := 0;
  v_config record;
begin
  select * into v_config from config_geral_vulnerabilidade where id = 1;

  if new.possui_cadunico then
    v_pontos := v_pontos + coalesce(
      (select pontos from config_pontuacao_vulnerabilidade
       where criterio = 'possui_cadunico' and ativo), 0);
  end if;

  if new.beneficiario_bolsa_familia then
    v_pontos := v_pontos + coalesce(
      (select pontos from config_pontuacao_vulnerabilidade
       where criterio = 'beneficiario_bolsa_familia' and ativo), 0);
  end if;

  if new.renda_per_capita is not null
     and new.renda_per_capita < v_config.renda_per_capita_limite then
    v_pontos := v_pontos + coalesce(
      (select pontos from config_pontuacao_vulnerabilidade
       where criterio = 'renda_per_capita_baixa' and ativo), 0);
  end if;

  if new.situacao_emprego = 'desempregado' then
    v_pontos := v_pontos + coalesce(
      (select pontos from config_pontuacao_vulnerabilidade
       where criterio = 'desempregado' and ativo), 0);
  end if;

  if new.pessoa_deficiencia_familia then
    v_pontos := v_pontos + coalesce(
      (select pontos from config_pontuacao_vulnerabilidade
       where criterio = 'pessoa_deficiencia_familia' and ativo), 0);
  end if;

  new.pontuacao_calculada := v_pontos;
  new.atualizado_em := now();

  -- só decide automaticamente se ainda não passou por revisão manual
  if new.status not in ('aprovado_manual', 'rejeitado') then
    if v_pontos >= v_config.pontuacao_limite_aprovacao then
      new.status := 'aprovado_automatico';
    else
      new.status := 'pendente';
    end if;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."calcular_pontuacao_vulnerabilidade"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calcular_valor_sessao"("p_paciente_id" "uuid") RETURNS TABLE("valor_paciente" numeric, "valor_empresa" numeric, "valor_plataforma_subsidio" numeric, "valor_repasse_psicologo" numeric, "origem_subsidio" "text")
    LANGUAGE "plpgsql" STABLE
    AS $$
declare
  v_config record;
  v_tem_vulnerabilidade boolean;
  v_empresa_id uuid;
begin
  select * into v_config from config_precos_sessao where id = 1;
  v_tem_vulnerabilidade := paciente_tem_vulnerabilidade_valida(p_paciente_id);

  -- ajuste o nome da coluna abaixo se o vínculo paciente->empresa
  -- tiver outro nome no seu schema real
  select empresa_id into v_empresa_id from pacientes where id = p_paciente_id;

  if not v_tem_vulnerabilidade then
    -- cenário (a): valor integral
    return query select
      v_config.valor_sessao_integral,
      0.00::numeric,
      0.00::numeric,
      v_config.valor_repasse_psicologo,
      'nenhum'::text;

  elsif v_empresa_id is not null then
    -- cenário (b): split real com empresa patrocinadora
    return query select
      v_config.valor_copagamento_social,
      v_config.valor_subsidio_empresa,
      0.00::numeric,
      v_config.valor_repasse_psicologo,
      'empresa'::text;

  else
    -- cenário (c): plataforma cobre a parte que seria da empresa
    return query select
      v_config.valor_copagamento_social,
      0.00::numeric,
      v_config.valor_subsidio_empresa,
      v_config.valor_repasse_psicologo,
      'plataforma'::text;
  end if;
end;
$$;


ALTER FUNCTION "public"."calcular_valor_sessao"("p_paciente_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."checar_criar_sala"("p_sessao_id" "uuid", "p_request_id" bigint) RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_status   int;
  v_conteudo text;
  v_nome     text;
  v_url      text;
begin
  select status_code, content into v_status, v_conteudo from net._http_response where id = p_request_id;

  if v_status is null then
    return null; -- ainda não chegou — o front-end tenta de novo em breve
  end if;

  if v_status >= 400 then
    raise exception 'Erro da API do Daily.co (status %): %', v_status, v_conteudo;
  end if;

  v_url  := (v_conteudo::jsonb) ->> 'url';
  v_nome := (v_conteudo::jsonb) ->> 'name';

  update sessoes set video_room_url = v_url, video_room_name = v_nome, video_room_criado_em = now()
  where id = p_sessao_id;

  return v_url;
end;
$$;


ALTER FUNCTION "public"."checar_criar_sala"("p_sessao_id" "uuid", "p_request_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."checar_criar_token"("p_request_id" bigint) RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_status   int;
  v_conteudo text;
begin
  select status_code, content into v_status, v_conteudo from net._http_response where id = p_request_id;
  if v_status is null then return null; end if;
  if v_status >= 400 then raise exception 'Erro da API do Daily.co (status %): %', v_status, v_conteudo; end if;
  return (v_conteudo::jsonb) ->> 'token';
end;
$$;


ALTER FUNCTION "public"."checar_criar_token"("p_request_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."contar_atendimentos_psicologo"("p_psicologo_id" "uuid") RETURNS bigint
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select count(*) from sessoes where psicologo_id = p_psicologo_id and status = 'realizada';
$$;


ALTER FUNCTION "public"."contar_atendimentos_psicologo"("p_psicologo_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."copiar_valor_paciente_para_pagamento"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_paciente record;
  v_config record;
begin
  if new.valor_paciente is null then
    select * into v_paciente from pacientes where id = new.paciente_id;
    select * into v_config from config_precos_sessao where id = 1;

    new.valor_paciente := v_paciente.valor_paciente;
    new.valor_repasse_psicologo := v_config.valor_repasse_psicologo;

    if v_paciente.status_financeiro_social = 'confirmado' then
      new.valor_empresa := v_config.valor_subsidio_empresa;
      new.pacote_id := v_paciente.pacote_ativo_id;
    else
      new.valor_empresa := 0.00;
      new.pacote_id := null;
    end if;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."copiar_valor_paciente_para_pagamento"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."daily_chamada_api"("v_method" "text", "v_path" "text", "v_body" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'vault', 'extensions'
    AS $$
declare
  v_api_key    text;
  v_request_id bigint;
  v_status     int;
  v_conteudo   text;
  v_tentativas int := 0;
begin
  select decrypted_secret into v_api_key from vault.decrypted_secrets where name = 'daily_api_key';
  if v_api_key is null then
    raise exception 'daily_api_key não encontrada no Vault. Configure antes de usar o vídeo.';
  end if;

  if v_method = 'POST' then
    v_request_id := net.http_post(
      url := 'https://api.daily.co/v1' || v_path,
      headers := jsonb_build_object('Authorization', 'Bearer ' || v_api_key, 'Content-Type', 'application/json'),
      body := v_body
    );
  else
    v_request_id := net.http_get(
      url := 'https://api.daily.co/v1' || v_path,
      headers := jsonb_build_object('Authorization', 'Bearer ' || v_api_key)
    );
  end if;

  -- pg_net processa a chamada num worker assíncrono — espera até ~5s
  -- pela resposta aparecer, checando a cada 200ms.
  loop
    select status_code, content into v_status, v_conteudo from net._http_response where id = v_request_id;
    exit when v_status is not null or v_tentativas > 25;
    perform pg_sleep(0.2);
    v_tentativas := v_tentativas + 1;
  end loop;

  if v_status is null then
    raise exception 'Tempo esgotado esperando resposta da API do Daily.co.';
  end if;

  if v_status >= 400 then
    raise exception 'Erro da API do Daily.co (status %): %', v_status, v_conteudo;
  end if;

  return v_conteudo::jsonb;
end;
$$;


ALTER FUNCTION "public"."daily_chamada_api"("v_method" "text", "v_path" "text", "v_body" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enviar_lembretes_sessao"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r record;
  v_html text;
begin
  for r in
    select s.id, s.data_hora, p.nome as paciente_nome, p.email as paciente_email, ps.nome as psicologo_nome
    from sessoes s
    join pacientes p on p.id = s.paciente_id
    join psicologos ps on ps.id = s.psicologo_id
    where s.status = 'agendada'
      and s.lembrete_enviado is not true
      and s.data_hora between now() + interval '23 hours' and now() + interval '25 hours'
  loop
    v_html := format(
      '<div style="font-family:sans-serif;max-width:480px;margin:0 auto">
        <h2 style="color:#2D4A6B">Lembrete: sua sessão é amanhã</h2>
        <p>Olá, %s!</p>
        <p>Este é um lembrete de que sua sessão com <strong>%s</strong> está marcada para <strong>%s</strong>.</p>
        <p style="color:#6B7A8D;font-size:13px">Se precisar reagendar ou cancelar, entre em contato com seu psicólogo pela plataforma Puzzle.</p>
      </div>',
      r.paciente_nome, r.psicologo_nome, to_char(r.data_hora, 'DD/MM/YYYY "às" HH24:MI')
    );

    perform mind_enviar_email(r.paciente_email, 'Lembrete: sua sessão é amanhã — Puzzle', v_html);

    update sessoes set lembrete_enviado = true where id = r.id;
  end loop;
end;
$$;


ALTER FUNCTION "public"."enviar_lembretes_sessao"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."existe_autorizacao_ativa"("p_paciente_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from autorizacoes_suporte
    where paciente_id = p_paciente_id
      and status = 'ativa'
      and expira_em > now()
  );
$$;


ALTER FUNCTION "public"."existe_autorizacao_ativa"("p_paciente_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."gerar_slug_psicologo"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.slug is null and new.nome is not null then
    new.slug := lower(regexp_replace(unaccent(new.nome), '[^a-zA-Z0-9]+', '-', 'g')) || '-' || substring(new.id::text, 1, 4);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."gerar_slug_psicologo"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."iniciar_criar_sala"("p_sessao_id" "uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'vault', 'extensions'
    AS $$
declare
  v_sessao     record;
  v_api_key    text;
  v_video_nome text;
  v_request_id bigint;
begin
  select s.id, s.data_hora, s.video_room_url,
         ps.email as psi_email, p.email as pac_email
  into v_sessao
  from sessoes s
  join psicologos ps on ps.id = s.psicologo_id
  join pacientes p on p.id = s.paciente_id
  where s.id = p_sessao_id;

  if v_sessao.id is null then raise exception 'Sessão não encontrada.'; end if;
  if not (v_sessao.psi_email = auth.jwt() ->> 'email' or v_sessao.pac_email = auth.jwt() ->> 'email') then
    raise exception 'Acesso negado — você não faz parte desta sessão.';
  end if;

  select decrypted_secret into v_api_key from vault.decrypted_secrets where name = 'daily_api_key';
  if v_api_key is null then raise exception 'daily_api_key não encontrada no Vault.'; end if;

  v_video_nome := 'puzzle-' || replace(p_sessao_id::text, '-', '');

  v_request_id := net.http_post(
    url := 'https://api.daily.co/v1/rooms',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_api_key, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'name', v_video_nome,
      'privacy', 'private',
      'properties', jsonb_build_object(
        'exp', extract(epoch from greatest(now() + interval '30 minutes', v_sessao.data_hora + interval '3 hours'))::bigint,
        'enable_chat', true,
        'enable_recording', false,
        'eject_at_room_exp', true
      )
    )
  );

  return v_request_id;
end;
$$;


ALTER FUNCTION "public"."iniciar_criar_sala"("p_sessao_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."iniciar_criar_token"("p_sessao_id" "uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'vault', 'extensions'
    AS $$
declare
  v_sessao     record;
  v_api_key    text;
  v_sou_psi    boolean;
  v_meu_nome   text;
  v_request_id bigint;
begin
  select s.id, s.video_room_name,
         ps.email as psi_email, ps.nome as psi_nome,
         p.email as pac_email, p.nome as pac_nome
  into v_sessao
  from sessoes s
  join psicologos ps on ps.id = s.psicologo_id
  join pacientes p on p.id = s.paciente_id
  where s.id = p_sessao_id;

  if v_sessao.id is null then raise exception 'Sessão não encontrada.'; end if;

  v_sou_psi := v_sessao.psi_email = auth.jwt() ->> 'email';
  if not (v_sou_psi or v_sessao.pac_email = auth.jwt() ->> 'email') then
    raise exception 'Acesso negado — você não faz parte desta sessão.';
  end if;

  if v_sessao.video_room_name is null then
    raise exception 'A sala ainda não foi criada — chame iniciar_criar_sala primeiro.';
  end if;

  select decrypted_secret into v_api_key from vault.decrypted_secrets where name = 'daily_api_key';
  v_meu_nome := case when v_sou_psi then v_sessao.psi_nome else v_sessao.pac_nome end;

  v_request_id := net.http_post(
    url := 'https://api.daily.co/v1/meeting-tokens',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_api_key, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'properties', jsonb_build_object(
        'room_name', v_sessao.video_room_name,
        'is_owner', v_sou_psi,
        'user_name', v_meu_nome,
        'exp', extract(epoch from (now() + interval '3 hours'))::bigint
      )
    )
  );

  return v_request_id;
end;
$$;


ALTER FUNCTION "public"."iniciar_criar_token"("p_sessao_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."liberar_vagas_expiradas"() RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare
  v_paciente record;
  v_processados int := 0;
begin
  for v_paciente in
    select p.id
    from pacientes p
    join pacotes_empresa pe on pe.id = p.pacote_ativo_id
    where pe.vigencia_fim < current_date
  loop
    perform aplicar_valor_social_paciente(v_paciente.id);
    v_processados := v_processados + 1;
  end loop;

  return v_processados;
end;
$$;


ALTER FUNCTION "public"."liberar_vagas_expiradas"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mind_enviar_email"("v_to" "text", "v_assunto" "text", "v_html" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'vault', 'extensions'
    AS $$
declare
  v_api_key text;
begin
  select decrypted_secret into v_api_key from vault.decrypted_secrets where name = 'resend_api_key';

  if v_api_key is null then
    raise notice 'resend_api_key não encontrada no Vault — e-mail para % não enviado.', v_to;
    return;
  end if;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_api_key, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'from', 'Puzzle <onboarding@resend.dev>', -- ⚠️ troque pelo remetente do seu domínio verificado
      'to', jsonb_build_array(v_to),
      'subject', v_assunto,
      'html', v_html
    )
  );
end;
$$;


ALTER FUNCTION "public"."mind_enviar_email"("v_to" "text", "v_assunto" "text", "v_html" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mind_notificar_agendamento_aceito"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_paciente_nome text;
  v_paciente_email text;
  v_psicologo_nome text;
  v_html text;
begin
  if new.status = 'aceito' and old.status is distinct from 'aceito' then
    select nome, email into v_paciente_nome, v_paciente_email from pacientes where id = new.paciente_id;
    select nome into v_psicologo_nome from psicologos where id = new.psicologo_id;

    v_html := format(
      '<div style="font-family:sans-serif;max-width:480px;margin:0 auto">
        <h2 style="color:#5B8C6E">Sessão confirmada! 🎉</h2>
        <p>Olá, %s!</p>
        <p><strong>%s</strong> confirmou sua sessão para <strong>%s</strong>.</p>
        <p style="color:#6B7A8D;font-size:13px">Você vai receber um lembrete um dia antes.</p>
      </div>',
      v_paciente_nome, v_psicologo_nome, to_char(new.data_hora, 'DD/MM/YYYY "às" HH24:MI')
    );

    perform mind_enviar_email(v_paciente_email, 'Sua sessão foi confirmada — Puzzle', v_html);
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."mind_notificar_agendamento_aceito"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mover_para_revisao_ao_enviar_comprovante"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  update avaliacoes_socioeconomicas
  set status = 'em_revisao', atualizado_em = now()
  where id = new.avaliacao_id
    and status = 'pendente';
  return new;
end;
$$;


ALTER FUNCTION "public"."mover_para_revisao_ao_enviar_comprovante"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."paciente_tem_vulnerabilidade_valida"("p_paciente_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE
    AS $$
declare
  v_avaliacao record;
  v_meses int;
begin
  select validade_avaliacao_meses into v_meses from config_precos_sessao where id = 1;

  select status, coalesce(revisado_em, criado_em) as data_referencia
  into v_avaliacao
  from avaliacoes_socioeconomicas
  where paciente_id = p_paciente_id
    and status in ('aprovado_automatico', 'aprovado_manual')
  order by coalesce(revisado_em, criado_em) desc
  limit 1;

  if v_avaliacao is null then
    return false;
  end if;

  return v_avaliacao.data_referencia >= (now() - (v_meses || ' months')::interval);
end;
$$;


ALTER FUNCTION "public"."paciente_tem_vulnerabilidade_valida"("p_paciente_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."preencher_valores_pagamento"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_calculo record;
begin
  -- só recalcula se os valores não vierem preenchidos manualmente
  if new.valor_paciente is null then
    select * into v_calculo from calcular_valor_sessao(new.paciente_id);

    new.valor_paciente := v_calculo.valor_paciente;
    new.valor_empresa := v_calculo.valor_empresa;
    new.valor_plataforma_subsidio := v_calculo.valor_plataforma_subsidio;
    new.valor_repasse_psicologo := v_calculo.valor_repasse_psicologo;
    new.origem_subsidio := v_calculo.origem_subsidio;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."preencher_valores_pagamento"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reprocessar_fila_espera_social"() RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare
  v_paciente record;
  v_processados int := 0;
begin
  for v_paciente in
    select id from pacientes
    where status_financeiro_social = 'aguardando_empresa'
    order by aguardando_desde asc
  loop
    perform aplicar_valor_social_paciente(v_paciente.id);
    v_processados := v_processados + 1;
  end loop;

  return v_processados;
end;
$$;


ALTER FUNCTION "public"."reprocessar_fila_espera_social"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reprocessar_pagamentos_aguardando"() RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare
  v_pagamento record;
  v_calculo record;
  v_processados int := 0;
begin
  for v_pagamento in
    select id, paciente_id from pagamentos
    where status_financeiro = 'aguardando_empresa'
    order by criado_em asc
  loop
    select * into v_calculo from alocar_valor_sessao(v_pagamento.paciente_id);

    if v_calculo.status_financeiro = 'confirmado' then
      update pagamentos
      set valor_paciente = v_calculo.valor_paciente,
          valor_empresa = v_calculo.valor_empresa,
          valor_repasse_psicologo = v_calculo.valor_repasse_psicologo,
          pacote_id = v_calculo.pacote_id,
          status_financeiro = 'confirmado'
      where id = v_pagamento.id;

      v_processados := v_processados + 1;
    end if;
  end loop;

  return v_processados;
end;
$$;


ALTER FUNCTION "public"."reprocessar_pagamentos_aguardando"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fn_avaliacao_status_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.status in ('aprovado_automatico', 'aprovado_manual', 'rejeitado') then
    perform aplicar_valor_social_paciente(new.paciente_id);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."trg_fn_avaliacao_status_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_fn_pacote_alterado"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  perform reprocessar_fila_espera_social();
  return new;
end;
$$;


ALTER FUNCTION "public"."trg_fn_pacote_alterado"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."admins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "nome" "text",
    "criado_em" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."admins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agendamentos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "paciente_id" "uuid",
    "psicologo_id" "uuid",
    "data_hora" timestamp with time zone,
    "status" "text" DEFAULT 'pendente'::"text"
);


ALTER TABLE "public"."agendamentos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."anamneses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "paciente_id" "uuid" NOT NULL,
    "psicologo_id" "uuid" NOT NULL,
    "data_nascimento" "date",
    "telefone" "text",
    "estado_civil" "text",
    "profissao" "text",
    "queixa_principal" "text",
    "historia_clinica" "text",
    "historia_familiar" "text",
    "historia_laboral" "text",
    "rede_apoio" "text",
    "objetivos_terapeuticos" "text",
    "intercorrencias_iniciais" "text",
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "atualizado_em" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."anamneses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ausencias" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "psicologo_id" "uuid" NOT NULL,
    "data_inicio" "date" NOT NULL,
    "data_fim" "date" NOT NULL,
    "motivo" "text",
    "criado_em" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."ausencias" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."autorizacoes_suporte" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "psicologo_id" "uuid" NOT NULL,
    "paciente_id" "uuid" NOT NULL,
    "motivo" "text" NOT NULL,
    "status" "text" DEFAULT 'ativa'::"text",
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "expira_em" timestamp with time zone DEFAULT ("now"() + '7 days'::interval) NOT NULL,
    "revogada_em" timestamp with time zone
);


ALTER TABLE "public"."autorizacoes_suporte" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."avaliacoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "psicologo_id" "uuid" NOT NULL,
    "paciente_id" "uuid" NOT NULL,
    "nota" integer NOT NULL,
    "comentario" "text",
    "criado_em" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "avaliacoes_nota_check" CHECK ((("nota" >= 1) AND ("nota" <= 5)))
);


ALTER TABLE "public"."avaliacoes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."avaliacoes_socioeconomicas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "paciente_id" "uuid" NOT NULL,
    "renda_per_capita" numeric(10,2),
    "num_moradores" integer,
    "situacao_emprego" "text",
    "possui_cadunico" boolean DEFAULT false NOT NULL,
    "beneficiario_bolsa_familia" boolean DEFAULT false NOT NULL,
    "pessoa_deficiencia_familia" boolean DEFAULT false NOT NULL,
    "pontuacao_calculada" integer DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'pendente'::"text" NOT NULL,
    "revisado_por" "uuid",
    "revisado_em" timestamp with time zone,
    "observacoes_admin" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "avaliacoes_socioeconomicas_situacao_emprego_check" CHECK (("situacao_emprego" = ANY (ARRAY['empregado_clt'::"text", 'empregado_informal'::"text", 'autonomo'::"text", 'desempregado'::"text", 'aposentado'::"text", 'outro'::"text"]))),
    CONSTRAINT "avaliacoes_socioeconomicas_status_check" CHECK (("status" = ANY (ARRAY['pendente'::"text", 'aprovado_automatico'::"text", 'em_revisao'::"text", 'aprovado_manual'::"text", 'rejeitado'::"text"])))
);


ALTER TABLE "public"."avaliacoes_socioeconomicas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."checkins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "paciente_id" "uuid" NOT NULL,
    "valor" "text" NOT NULL,
    "data" "date" DEFAULT CURRENT_DATE NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."checkins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comprovantes_vulnerabilidade" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "avaliacao_id" "uuid" NOT NULL,
    "tipo_documento" "text" NOT NULL,
    "caminho_arquivo" "text" NOT NULL,
    "enviado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "comprovantes_vulnerabilidade_tipo_documento_check" CHECK (("tipo_documento" = ANY (ARRAY['cadunico'::"text", 'folha_resumo'::"text", 'cartao_nis'::"text", 'comprovante_bolsa_familia'::"text", 'outro'::"text"])))
);


ALTER TABLE "public"."comprovantes_vulnerabilidade" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."config_geral_vulnerabilidade" (
    "id" integer DEFAULT 1 NOT NULL,
    "renda_per_capita_limite" numeric(10,2) DEFAULT 300.00 NOT NULL,
    "pontuacao_limite_aprovacao" integer DEFAULT 60 NOT NULL,
    CONSTRAINT "singleton" CHECK (("id" = 1))
);


ALTER TABLE "public"."config_geral_vulnerabilidade" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."config_pontuacao_vulnerabilidade" (
    "criterio" "text" NOT NULL,
    "pontos" integer NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "descricao" "text"
);


ALTER TABLE "public"."config_pontuacao_vulnerabilidade" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."config_precos_sessao" (
    "id" integer DEFAULT 1 NOT NULL,
    "valor_sessao_integral" numeric(10,2) DEFAULT 100.00 NOT NULL,
    "valor_copagamento_social" numeric(10,2) DEFAULT 10.00 NOT NULL,
    "valor_subsidio_empresa" numeric(10,2) DEFAULT 40.00 NOT NULL,
    "valor_repasse_psicologo" numeric(10,2) DEFAULT 50.00 NOT NULL,
    "validade_avaliacao_meses" integer DEFAULT 6 NOT NULL,
    CONSTRAINT "singleton" CHECK (("id" = 1)),
    CONSTRAINT "soma_bate_com_repasse" CHECK ((("valor_copagamento_social" + "valor_subsidio_empresa") = "valor_repasse_psicologo"))
);


ALTER TABLE "public"."config_precos_sessao" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."disponibilidade_semanal" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "psicologo_id" "uuid" NOT NULL,
    "dia_semana" integer NOT NULL,
    "hora_inicio" time without time zone NOT NULL,
    "hora_fim" time without time zone NOT NULL,
    "duracao_sessao" integer DEFAULT 50 NOT NULL,
    "ativo" boolean DEFAULT true,
    "criado_em" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "disponibilidade_semanal_dia_semana_check" CHECK ((("dia_semana" >= 0) AND ("dia_semana" <= 6)))
);


ALTER TABLE "public"."disponibilidade_semanal" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."empresas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "nome" "text" NOT NULL,
    "cnpj" "text",
    "plano" "text" DEFAULT 'basico'::"text",
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "contato_rh" "text",
    "telefone" "text",
    "endereco_rua" "text",
    "endereco_numero" "text",
    "endereco_complemento" "text",
    "endereco_bairro" "text",
    "endereco_cidade" "text",
    "endereco_estado" "text",
    "endereco_cep" "text",
    "logo_url" "text"
);


ALTER TABLE "public"."empresas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hipoteses_diagnosticas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "paciente_id" "uuid" NOT NULL,
    "psicologo_id" "uuid" NOT NULL,
    "cid" "text",
    "descricao" "text",
    "ativa" boolean DEFAULT true,
    "criado_em" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."hipoteses_diagnosticas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."intercorrencias" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "paciente_id" "uuid" NOT NULL,
    "psicologo_id" "uuid" NOT NULL,
    "data" "date" DEFAULT CURRENT_DATE NOT NULL,
    "descricao" "text" NOT NULL,
    "gravidade" "text" DEFAULT 'leve'::"text",
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "visivel_paciente" boolean DEFAULT false
);


ALTER TABLE "public"."intercorrencias" OWNER TO "postgres";


COMMENT ON COLUMN "public"."intercorrencias"."visivel_paciente" IS 'Se true, este registro aparece na linha do tempo do próprio paciente. Padrão: false (nota interna do psicólogo).';



CREATE TABLE IF NOT EXISTS "public"."mensalidades_psicologos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "psicologo_id" "uuid" NOT NULL,
    "mes_referencia" "date" NOT NULL,
    "valor" numeric(10,2) DEFAULT 120.00 NOT NULL,
    "status_pagamento" "text" DEFAULT 'pendente'::"text" NOT NULL,
    "data_vencimento" "date",
    "data_pagamento" timestamp with time zone,
    "criado_em" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "mensalidades_psicologos_status_pagamento_check" CHECK (("status_pagamento" = ANY (ARRAY['pendente'::"text", 'pago'::"text", 'atrasado'::"text"])))
);


ALTER TABLE "public"."mensalidades_psicologos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pacientes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "nome" "text" NOT NULL,
    "empresa_id" "uuid",
    "psicologo_id" "uuid",
    "departamento" "text",
    "queixa_principal" "text",
    "diagnostico_cid" "text",
    "area_trabalho" integer DEFAULT 5,
    "area_social" integer DEFAULT 5,
    "area_saude" integer DEFAULT 5,
    "total_sessoes" integer DEFAULT 0,
    "valor_paciente" numeric(10,2) DEFAULT 10.00,
    "status" "text" DEFAULT 'ativo'::"text",
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "objetivos" "text",
    "historico" "text",
    "data_inicio" "date",
    "cpf" "text",
    "telefone" "text",
    "endereco_rua" "text",
    "endereco_numero" "text",
    "endereco_complemento" "text",
    "endereco_bairro" "text",
    "endereco_cidade" "text",
    "endereco_estado" "text",
    "endereco_cep" "text",
    "foto_url" "text",
    "pacote_ativo_id" "uuid",
    "status_financeiro_social" "text" DEFAULT 'nenhum'::"text",
    "aguardando_desde" timestamp with time zone,
    CONSTRAINT "pacientes_status_financeiro_social_check" CHECK (("status_financeiro_social" = ANY (ARRAY['nenhum'::"text", 'aguardando_empresa'::"text", 'confirmado'::"text"])))
);


ALTER TABLE "public"."pacientes" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."pacientes_agregado_empresa" AS
 SELECT "p"."id",
    "p"."empresa_id",
    "p"."departamento",
    "p"."total_sessoes",
    "p"."status",
    "p"."data_inicio"
   FROM ("public"."pacientes" "p"
     JOIN "public"."empresas" "e" ON (("e"."id" = "p"."empresa_id")))
  WHERE ("e"."email" = ("auth"."jwt"() ->> 'email'::"text"));


ALTER VIEW "public"."pacientes_agregado_empresa" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pacientes_meupsi" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "psicologo_id" "uuid",
    "nome" "text" NOT NULL,
    "data_nascimento" "date",
    "genero" "text",
    "estado_civil" "text",
    "telefone" "text",
    "email" "text",
    "profissao" "text",
    "escolaridade" "text",
    "queixa_principal" "text",
    "tempo_queixa" "text",
    "areas_impacto" "text"[] DEFAULT '{}'::"text"[],
    "terapia_anterior" "text",
    "terapia_detalhes" "text",
    "diagnosticos" "text"[] DEFAULT '{}'::"text"[],
    "diagnosticos_obs" "text",
    "medicacao" "text",
    "medicacao_detalhe" "text",
    "saude_fisica_nota" integer,
    "internacao" "text",
    "internacao_detalhe" "text",
    "substancias" "text"[] DEFAULT '{}'::"text"[],
    "familia_atual" "text",
    "historico_familiar" "text"[] DEFAULT '{}'::"text"[],
    "eventos_vida" "text"[] DEFAULT '{}'::"text"[],
    "historia_obs" "text",
    "obs_clinicas" "text",
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "atualizado_em" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "pacientes_meupsi_saude_fisica_nota_check" CHECK ((("saude_fisica_nota" >= 1) AND ("saude_fisica_nota" <= 10)))
);


ALTER TABLE "public"."pacientes_meupsi" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pacotes_empresa" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "empresa_id" "uuid" NOT NULL,
    "quantidade_vagas" integer NOT NULL,
    "vagas_ocupadas" integer DEFAULT 0 NOT NULL,
    "valor_pago" numeric(10,2),
    "vigencia_inicio" "date" DEFAULT CURRENT_DATE NOT NULL,
    "vigencia_fim" "date" NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "capacidade_valida" CHECK (("vagas_ocupadas" <= "quantidade_vagas")),
    CONSTRAINT "pacotes_empresa_quantidade_vagas_check" CHECK (("quantidade_vagas" > 0)),
    CONSTRAINT "pacotes_empresa_vagas_ocupadas_check" CHECK (("vagas_ocupadas" >= 0)),
    CONSTRAINT "vigencia_valida" CHECK (("vigencia_fim" >= "vigencia_inicio"))
);


ALTER TABLE "public"."pacotes_empresa" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pagamentos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "paciente_id" "uuid" NOT NULL,
    "valor_paciente" numeric(10,2) NOT NULL,
    "data_pagamento" "date" DEFAULT CURRENT_DATE NOT NULL,
    "status" "text" DEFAULT 'pendente'::"text",
    "metodo" "text",
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "sessao_id" "uuid",
    "valor_empresa" numeric(10,2) DEFAULT 40.00,
    "valor_psicologo" numeric(10,2) DEFAULT 50.00,
    "valor_total" numeric(10,2) DEFAULT 50.00,
    "status_pagamento" "text" DEFAULT 'pendente'::"text",
    "valor_repasse_psicologo" numeric(10,2),
    "pacote_id" "uuid",
    "valor_plataforma_subsidio" numeric(10,2),
    "origem_subsidio" "text"
);


ALTER TABLE "public"."pagamentos" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."pagamentos_agregado_empresa" AS
 SELECT "pg"."id",
    "pg"."paciente_id",
    "pg"."valor_empresa",
    "pg"."valor_total",
    "pg"."status_pagamento",
    "pg"."data_pagamento"
   FROM (("public"."pagamentos" "pg"
     JOIN "public"."pacientes" "p" ON (("p"."id" = "pg"."paciente_id")))
     JOIN "public"."empresas" "e" ON (("e"."id" = "p"."empresa_id")))
  WHERE ("e"."email" = ("auth"."jwt"() ->> 'email'::"text"));


ALTER VIEW "public"."pagamentos_agregado_empresa" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."psicologos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "nome" "text" NOT NULL,
    "crp" "text",
    "especialidade" "text",
    "bio" "text",
    "foto_url" "text",
    "ativo" boolean DEFAULT true,
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "user_id" "uuid",
    "sobrenome" "text",
    "data_nascimento" "date",
    "cpf" "text",
    "celular" "text",
    "cidade" "text",
    "estado" "text",
    "uf_crp" "text",
    "crp_doc_url" "text",
    "diploma_doc_url" "text",
    "certidao_doc_url" "text",
    "resumo" "text",
    "sobre_mim" "text",
    "especialidades" "text"[],
    "temas" "text"[],
    "idade_minima" integer,
    "idade_maxima" integer,
    "banco" "text",
    "agencia" "text",
    "conta" "text",
    "tipo_conta" "text",
    "tipo_chave_pix" "text",
    "chave_pix" "text",
    "status_cadastro" "text" DEFAULT 'incompleto'::"text",
    "aceite_contrato" boolean DEFAULT false,
    "data_aceite_contrato" timestamp with time zone,
    "plano" "text" DEFAULT 'mensal'::"text",
    "status_assinatura" "text" DEFAULT 'ativa'::"text",
    "vigencia_ate" "date",
    "abordagem" "text",
    "formacao" "text",
    "pos_graduacao" "text",
    "disponibilidade" "text",
    "motivo_recusa" "text",
    "endereco_rua" "text",
    "endereco_numero" "text",
    "endereco_complemento" "text",
    "endereco_bairro" "text",
    "endereco_cep" "text",
    "perfil_publico" boolean DEFAULT true,
    "slug" "text",
    "idiomas" "text"[],
    "primeira_mensalidade_confirmada" boolean DEFAULT false,
    CONSTRAINT "psicologos_plano_check" CHECK (("plano" = ANY (ARRAY['mensal'::"text", 'anual'::"text"]))),
    CONSTRAINT "psicologos_status_assinatura_check" CHECK (("status_assinatura" = ANY (ARRAY['ativa'::"text", 'vencida'::"text", 'cancelada'::"text"]))),
    CONSTRAINT "psicologos_status_cadastro_check" CHECK (("status_cadastro" = ANY (ARRAY['incompleto'::"text", 'em_analise'::"text", 'aprovado'::"text", 'rejeitado'::"text"])))
);


ALTER TABLE "public"."psicologos" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."psicologos_publico" AS
 SELECT "id",
    "nome",
    "crp",
    "abordagem",
    "foto_url",
    "bio",
    "sobre_mim",
    "resumo",
    "formacao",
    "pos_graduacao",
    "especialidades",
    "temas",
    "disponibilidade",
    "idade_minima",
    "idade_maxima",
    "slug",
    "idiomas"
   FROM "public"."psicologos"
  WHERE ((("status_cadastro" = 'aprovado'::"text") OR ("status_cadastro" IS NULL)) AND (COALESCE("perfil_publico", true) = true));


ALTER VIEW "public"."psicologos_publico" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."resumo_pacotes_empresa" AS
 SELECT "e"."id" AS "empresa_id",
    "p"."id" AS "pacote_id",
    "p"."quantidade_vagas",
    "p"."vagas_ocupadas",
    ("p"."quantidade_vagas" - "p"."vagas_ocupadas") AS "vagas_disponiveis",
    "p"."vigencia_inicio",
    "p"."vigencia_fim",
        CASE
            WHEN ("p"."vigencia_fim" < CURRENT_DATE) THEN 'expirado'::"text"
            WHEN ("p"."vagas_ocupadas" >= "p"."quantidade_vagas") THEN 'esgotado'::"text"
            ELSE 'ativo'::"text"
        END AS "status_pacote"
   FROM ("public"."pacotes_empresa" "p"
     JOIN "public"."empresas" "e" ON (("e"."id" = "p"."empresa_id")));


ALTER VIEW "public"."resumo_pacotes_empresa" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."resumo_subsidio_plataforma" AS
 SELECT "date_trunc"('month'::"text", "criado_em") AS "mes",
    "count"(*) AS "sessoes_subsidiadas",
    "sum"("valor_plataforma_subsidio") AS "total_subsidiado"
   FROM "public"."pagamentos"
  WHERE ("origem_subsidio" = 'plataforma'::"text")
  GROUP BY ("date_trunc"('month'::"text", "criado_em"))
  ORDER BY ("date_trunc"('month'::"text", "criado_em")) DESC;


ALTER VIEW "public"."resumo_subsidio_plataforma" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sessoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "paciente_id" "uuid" NOT NULL,
    "psicologo_id" "uuid" NOT NULL,
    "data_hora" timestamp with time zone NOT NULL,
    "status" "text" DEFAULT 'agendada'::"text",
    "resumo_sessao" "text",
    "tarefa_casa" "text",
    "valor_psicologo" numeric(10,2) DEFAULT 50.00,
    "status_pagamento" "text" DEFAULT 'pendente'::"text",
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "lembrete_enviado" boolean DEFAULT false,
    "video_room_url" "text",
    "video_room_name" "text",
    "video_room_criado_em" timestamp with time zone
);


ALTER TABLE "public"."sessoes" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."sessoes_agregado_empresa" AS
 SELECT "s"."id",
    "s"."paciente_id",
    "s"."status",
    "s"."data_hora"
   FROM (("public"."sessoes" "s"
     JOIN "public"."pacientes" "p" ON (("p"."id" = "s"."paciente_id")))
     JOIN "public"."empresas" "e" ON (("e"."id" = "p"."empresa_id")))
  WHERE ("e"."email" = ("auth"."jwt"() ->> 'email'::"text"));


ALTER VIEW "public"."sessoes_agregado_empresa" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sintomas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sessao_id" "uuid",
    "paciente_id" "uuid" NOT NULL,
    "ansiedade" integer,
    "sono" integer,
    "humor" integer,
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "foco" integer,
    "funcionamento_ocupacional" integer,
    "funcionamento_social" integer,
    "adesao" integer,
    CONSTRAINT "sintomas_adesao_check" CHECK ((("adesao" >= 0) AND ("adesao" <= 10))),
    CONSTRAINT "sintomas_ansiedade_check" CHECK ((("ansiedade" >= 1) AND ("ansiedade" <= 10))),
    CONSTRAINT "sintomas_foco_check" CHECK ((("foco" >= 0) AND ("foco" <= 10))),
    CONSTRAINT "sintomas_funcionamento_ocupacional_check" CHECK ((("funcionamento_ocupacional" >= 0) AND ("funcionamento_ocupacional" <= 10))),
    CONSTRAINT "sintomas_funcionamento_social_check" CHECK ((("funcionamento_social" >= 0) AND ("funcionamento_social" <= 10))),
    CONSTRAINT "sintomas_humor_check" CHECK ((("humor" >= 1) AND ("humor" <= 10))),
    CONSTRAINT "sintomas_sono_check" CHECK ((("sono" >= 1) AND ("sono" <= 10)))
);


ALTER TABLE "public"."sintomas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."solicitacoes_exclusao" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "tipo_conta" "text",
    "motivo" "text",
    "status" "text" DEFAULT 'pendente'::"text",
    "resposta_admin" "text",
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "processado_em" timestamp with time zone
);


ALTER TABLE "public"."solicitacoes_exclusao" OWNER TO "postgres";


ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agendamentos"
    ADD CONSTRAINT "agendamentos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."anamneses"
    ADD CONSTRAINT "anamneses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ausencias"
    ADD CONSTRAINT "ausencias_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."autorizacoes_suporte"
    ADD CONSTRAINT "autorizacoes_suporte_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."avaliacoes"
    ADD CONSTRAINT "avaliacoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."avaliacoes"
    ADD CONSTRAINT "avaliacoes_psicologo_id_paciente_id_key" UNIQUE ("psicologo_id", "paciente_id");



ALTER TABLE ONLY "public"."avaliacoes_socioeconomicas"
    ADD CONSTRAINT "avaliacoes_socioeconomicas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."checkins"
    ADD CONSTRAINT "checkins_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comprovantes_vulnerabilidade"
    ADD CONSTRAINT "comprovantes_vulnerabilidade_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."config_geral_vulnerabilidade"
    ADD CONSTRAINT "config_geral_vulnerabilidade_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."config_pontuacao_vulnerabilidade"
    ADD CONSTRAINT "config_pontuacao_vulnerabilidade_pkey" PRIMARY KEY ("criterio");



ALTER TABLE ONLY "public"."config_precos_sessao"
    ADD CONSTRAINT "config_precos_sessao_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."disponibilidade_semanal"
    ADD CONSTRAINT "disponibilidade_semanal_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."empresas"
    ADD CONSTRAINT "empresas_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."empresas"
    ADD CONSTRAINT "empresas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hipoteses_diagnosticas"
    ADD CONSTRAINT "hipoteses_diagnosticas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."intercorrencias"
    ADD CONSTRAINT "intercorrencias_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mensalidades_psicologos"
    ADD CONSTRAINT "mensalidades_psicologos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pacientes"
    ADD CONSTRAINT "pacientes_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."pacientes_meupsi"
    ADD CONSTRAINT "pacientes_meupsi_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pacientes"
    ADD CONSTRAINT "pacientes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pacotes_empresa"
    ADD CONSTRAINT "pacotes_empresa_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pagamentos"
    ADD CONSTRAINT "pagamentos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."psicologos"
    ADD CONSTRAINT "psicologos_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."psicologos"
    ADD CONSTRAINT "psicologos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."psicologos"
    ADD CONSTRAINT "psicologos_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."sessoes"
    ADD CONSTRAINT "sessoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sintomas"
    ADD CONSTRAINT "sintomas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."solicitacoes_exclusao"
    ADD CONSTRAINT "solicitacoes_exclusao_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_anamneses_paciente" ON "public"."anamneses" USING "btree" ("paciente_id");



CREATE INDEX "idx_ausencias_psicologo" ON "public"."ausencias" USING "btree" ("psicologo_id", "data_inicio", "data_fim");



CREATE INDEX "idx_autorizacoes_paciente" ON "public"."autorizacoes_suporte" USING "btree" ("paciente_id", "status", "expira_em");



CREATE INDEX "idx_avaliacoes_paciente" ON "public"."avaliacoes_socioeconomicas" USING "btree" ("paciente_id");



CREATE INDEX "idx_avaliacoes_psicologo" ON "public"."avaliacoes" USING "btree" ("psicologo_id", "criado_em" DESC);



CREATE INDEX "idx_avaliacoes_status" ON "public"."avaliacoes_socioeconomicas" USING "btree" ("status");



CREATE INDEX "idx_checkins_paciente" ON "public"."checkins" USING "btree" ("paciente_id");



CREATE INDEX "idx_comprovantes_avaliacao" ON "public"."comprovantes_vulnerabilidade" USING "btree" ("avaliacao_id");



CREATE INDEX "idx_disponibilidade_psicologo" ON "public"."disponibilidade_semanal" USING "btree" ("psicologo_id", "dia_semana");



CREATE INDEX "idx_hipoteses_paciente" ON "public"."hipoteses_diagnosticas" USING "btree" ("paciente_id");



CREATE INDEX "idx_intercorrencias_paciente" ON "public"."intercorrencias" USING "btree" ("paciente_id");



CREATE INDEX "idx_mensalidades_psicologo" ON "public"."mensalidades_psicologos" USING "btree" ("psicologo_id", "mes_referencia" DESC);



CREATE INDEX "idx_pacientes_empresa" ON "public"."pacientes" USING "btree" ("empresa_id");



CREATE INDEX "idx_pacientes_psicologo" ON "public"."pacientes" USING "btree" ("psicologo_id");



CREATE INDEX "idx_pacotes_empresa_disponivel" ON "public"."pacotes_empresa" USING "btree" ("vigencia_fim") WHERE ("vagas_ocupadas" < "quantidade_vagas");



CREATE INDEX "idx_pagamentos_paciente" ON "public"."pagamentos" USING "btree" ("paciente_id");



CREATE INDEX "idx_sessoes_data" ON "public"."sessoes" USING "btree" ("data_hora");



CREATE INDEX "idx_sessoes_paciente" ON "public"."sessoes" USING "btree" ("paciente_id");



CREATE INDEX "idx_sessoes_psicologo" ON "public"."sessoes" USING "btree" ("psicologo_id");



CREATE INDEX "idx_sintomas_paciente" ON "public"."sintomas" USING "btree" ("paciente_id");



CREATE OR REPLACE TRIGGER "trg_avaliacao_status_change" AFTER INSERT OR UPDATE OF "status" ON "public"."avaliacoes_socioeconomicas" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fn_avaliacao_status_change"();



CREATE OR REPLACE TRIGGER "trg_calcular_pontuacao" BEFORE INSERT OR UPDATE OF "possui_cadunico", "beneficiario_bolsa_familia", "renda_per_capita", "situacao_emprego", "pessoa_deficiencia_familia" ON "public"."avaliacoes_socioeconomicas" FOR EACH ROW EXECUTE FUNCTION "public"."calcular_pontuacao_vulnerabilidade"();



CREATE OR REPLACE TRIGGER "trg_copiar_valor_pagamento" BEFORE INSERT ON "public"."pagamentos" FOR EACH ROW EXECUTE FUNCTION "public"."copiar_valor_paciente_para_pagamento"();



CREATE OR REPLACE TRIGGER "trg_gerar_slug_psicologo" BEFORE INSERT ON "public"."psicologos" FOR EACH ROW EXECUTE FUNCTION "public"."gerar_slug_psicologo"();



CREATE OR REPLACE TRIGGER "trg_mover_para_revisao" AFTER INSERT ON "public"."comprovantes_vulnerabilidade" FOR EACH ROW EXECUTE FUNCTION "public"."mover_para_revisao_ao_enviar_comprovante"();



CREATE OR REPLACE TRIGGER "trg_notificar_agendamento_aceito" AFTER UPDATE ON "public"."agendamentos" FOR EACH ROW EXECUTE FUNCTION "public"."mind_notificar_agendamento_aceito"();



CREATE OR REPLACE TRIGGER "trg_pacote_alterado" AFTER INSERT OR UPDATE OF "quantidade_vagas", "vigencia_fim" ON "public"."pacotes_empresa" FOR EACH ROW EXECUTE FUNCTION "public"."trg_fn_pacote_alterado"();



CREATE OR REPLACE TRIGGER "trg_preencher_valores_pagamento" BEFORE INSERT ON "public"."pagamentos" FOR EACH ROW EXECUTE FUNCTION "public"."preencher_valores_pagamento"();



ALTER TABLE ONLY "public"."agendamentos"
    ADD CONSTRAINT "agendamentos_paciente_id_fkey" FOREIGN KEY ("paciente_id") REFERENCES "public"."pacientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agendamentos"
    ADD CONSTRAINT "agendamentos_psicologo_id_fkey" FOREIGN KEY ("psicologo_id") REFERENCES "public"."psicologos"("id");



ALTER TABLE ONLY "public"."anamneses"
    ADD CONSTRAINT "anamneses_paciente_id_fkey" FOREIGN KEY ("paciente_id") REFERENCES "public"."pacientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."anamneses"
    ADD CONSTRAINT "anamneses_psicologo_id_fkey" FOREIGN KEY ("psicologo_id") REFERENCES "public"."psicologos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ausencias"
    ADD CONSTRAINT "ausencias_psicologo_id_fkey" FOREIGN KEY ("psicologo_id") REFERENCES "public"."psicologos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."autorizacoes_suporte"
    ADD CONSTRAINT "autorizacoes_suporte_paciente_id_fkey" FOREIGN KEY ("paciente_id") REFERENCES "public"."pacientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."autorizacoes_suporte"
    ADD CONSTRAINT "autorizacoes_suporte_psicologo_id_fkey" FOREIGN KEY ("psicologo_id") REFERENCES "public"."psicologos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."avaliacoes"
    ADD CONSTRAINT "avaliacoes_paciente_id_fkey" FOREIGN KEY ("paciente_id") REFERENCES "public"."pacientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."avaliacoes"
    ADD CONSTRAINT "avaliacoes_psicologo_id_fkey" FOREIGN KEY ("psicologo_id") REFERENCES "public"."psicologos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."avaliacoes_socioeconomicas"
    ADD CONSTRAINT "avaliacoes_socioeconomicas_paciente_id_fkey" FOREIGN KEY ("paciente_id") REFERENCES "public"."pacientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."avaliacoes_socioeconomicas"
    ADD CONSTRAINT "avaliacoes_socioeconomicas_revisado_por_fkey" FOREIGN KEY ("revisado_por") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."checkins"
    ADD CONSTRAINT "checkins_paciente_id_fkey" FOREIGN KEY ("paciente_id") REFERENCES "public"."pacientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comprovantes_vulnerabilidade"
    ADD CONSTRAINT "comprovantes_vulnerabilidade_avaliacao_id_fkey" FOREIGN KEY ("avaliacao_id") REFERENCES "public"."avaliacoes_socioeconomicas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."disponibilidade_semanal"
    ADD CONSTRAINT "disponibilidade_semanal_psicologo_id_fkey" FOREIGN KEY ("psicologo_id") REFERENCES "public"."psicologos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hipoteses_diagnosticas"
    ADD CONSTRAINT "hipoteses_diagnosticas_paciente_id_fkey" FOREIGN KEY ("paciente_id") REFERENCES "public"."pacientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hipoteses_diagnosticas"
    ADD CONSTRAINT "hipoteses_diagnosticas_psicologo_id_fkey" FOREIGN KEY ("psicologo_id") REFERENCES "public"."psicologos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."intercorrencias"
    ADD CONSTRAINT "intercorrencias_paciente_id_fkey" FOREIGN KEY ("paciente_id") REFERENCES "public"."pacientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."intercorrencias"
    ADD CONSTRAINT "intercorrencias_psicologo_id_fkey" FOREIGN KEY ("psicologo_id") REFERENCES "public"."psicologos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mensalidades_psicologos"
    ADD CONSTRAINT "mensalidades_psicologos_psicologo_id_fkey" FOREIGN KEY ("psicologo_id") REFERENCES "public"."psicologos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pacientes"
    ADD CONSTRAINT "pacientes_empresa_id_fkey" FOREIGN KEY ("empresa_id") REFERENCES "public"."empresas"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pacientes_meupsi"
    ADD CONSTRAINT "pacientes_meupsi_psicologo_id_fkey" FOREIGN KEY ("psicologo_id") REFERENCES "public"."psicologos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pacientes"
    ADD CONSTRAINT "pacientes_psicologo_id_fkey" FOREIGN KEY ("psicologo_id") REFERENCES "public"."psicologos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pacotes_empresa"
    ADD CONSTRAINT "pacotes_empresa_empresa_id_fkey" FOREIGN KEY ("empresa_id") REFERENCES "public"."empresas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pagamentos"
    ADD CONSTRAINT "pagamentos_paciente_id_fkey" FOREIGN KEY ("paciente_id") REFERENCES "public"."pacientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pagamentos"
    ADD CONSTRAINT "pagamentos_sessao_id_fkey" FOREIGN KEY ("sessao_id") REFERENCES "public"."sessoes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."psicologos"
    ADD CONSTRAINT "psicologos_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sessoes"
    ADD CONSTRAINT "sessoes_paciente_id_fkey" FOREIGN KEY ("paciente_id") REFERENCES "public"."pacientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sessoes"
    ADD CONSTRAINT "sessoes_psicologo_id_fkey" FOREIGN KEY ("psicologo_id") REFERENCES "public"."psicologos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sintomas"
    ADD CONSTRAINT "sintomas_paciente_id_fkey" FOREIGN KEY ("paciente_id") REFERENCES "public"."pacientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sintomas"
    ADD CONSTRAINT "sintomas_sessao_id_fkey" FOREIGN KEY ("sessao_id") REFERENCES "public"."sessoes"("id") ON DELETE CASCADE;



CREATE POLICY "admin_confirma_proprio_status" ON "public"."admins" FOR SELECT USING (("email" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "admin_edita_config_geral" ON "public"."config_geral_vulnerabilidade" USING ((("auth"."jwt"() ->> 'email'::"text") = 'micaelsonnen@gmail.com'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'email'::"text") = 'micaelsonnen@gmail.com'::"text"));



CREATE POLICY "admin_edita_config_pontuacao" ON "public"."config_pontuacao_vulnerabilidade" USING ((("auth"."jwt"() ->> 'email'::"text") = 'micaelsonnen@gmail.com'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'email'::"text") = 'micaelsonnen@gmail.com'::"text"));



CREATE POLICY "admin_edita_config_precos" ON "public"."config_precos_sessao" USING ((EXISTS ( SELECT 1
   FROM "public"."admins"
  WHERE ("admins"."email" = ("auth"."jwt"() ->> 'email'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."admins"
  WHERE ("admins"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "admin_edita_empresas" ON "public"."empresas" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "admin_edita_pacientes" ON "public"."pacientes" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "admin_edita_todos_psicologos" ON "public"."psicologos" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "admin_full_access_avaliacoes" ON "public"."avaliacoes_socioeconomicas" USING ((("auth"."jwt"() ->> 'email'::"text") = 'micaelsonnen@gmail.com'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'email'::"text") = 'micaelsonnen@gmail.com'::"text"));



CREATE POLICY "admin_full_access_comprovantes" ON "public"."comprovantes_vulnerabilidade" USING ((("auth"."jwt"() ->> 'email'::"text") = 'micaelsonnen@gmail.com'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'email'::"text") = 'micaelsonnen@gmail.com'::"text"));



CREATE POLICY "admin_full_access_pacotes" ON "public"."pacotes_empresa" USING ((EXISTS ( SELECT 1
   FROM "public"."admins"
  WHERE ("admins"."email" = ("auth"."jwt"() ->> 'email'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."admins"
  WHERE ("admins"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "admin_gerencia_solicitacoes_exclusao" ON "public"."solicitacoes_exclusao" USING ((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "admin_ve_anamneses_autorizadas" ON "public"."anamneses" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))) AND "public"."existe_autorizacao_ativa"("paciente_id")));



CREATE POLICY "admin_ve_autorizacoes" ON "public"."autorizacoes_suporte" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "admin_ve_hipoteses_autorizadas" ON "public"."hipoteses_diagnosticas" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))) AND "public"."existe_autorizacao_ativa"("paciente_id")));



CREATE POLICY "admin_ve_intercorrencias_autorizadas" ON "public"."intercorrencias" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))) AND "public"."existe_autorizacao_ativa"("paciente_id")));



CREATE POLICY "admin_ve_sessoes_autorizadas" ON "public"."sessoes" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))) AND "public"."existe_autorizacao_ativa"("paciente_id")));



CREATE POLICY "admin_ve_sintomas_autorizados" ON "public"."sintomas" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))) AND "public"."existe_autorizacao_ativa"("paciente_id")));



CREATE POLICY "admin_ve_todas_empresas" ON "public"."empresas" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "admin_ve_todos_pacientes" ON "public"."pacientes" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "admin_ve_todos_psicologos" ON "public"."psicologos" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE ("a"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



ALTER TABLE "public"."admins" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."agendamentos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."anamneses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ausencias" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ausencias_leitura_publica" ON "public"."ausencias" FOR SELECT USING (true);



ALTER TABLE "public"."autorizacoes_suporte" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."avaliacoes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "avaliacoes_leitura_publica" ON "public"."avaliacoes" FOR SELECT USING (true);



ALTER TABLE "public"."avaliacoes_socioeconomicas" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "checkin_paciente" ON "public"."checkins" USING (("paciente_id" IN ( SELECT "pacientes"."id"
   FROM "public"."pacientes"
  WHERE ("pacientes"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



ALTER TABLE "public"."checkins" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comprovantes_vulnerabilidade" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."config_geral_vulnerabilidade" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."config_pontuacao_vulnerabilidade" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."config_precos_sessao" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "disponibilidade_leitura_publica" ON "public"."disponibilidade_semanal" FOR SELECT USING (true);



ALTER TABLE "public"."disponibilidade_semanal" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "empresa_gerencia_proprio_registro" ON "public"."empresas" USING (("email" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "empresa_own" ON "public"."empresas" USING (("email" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "empresa_ve_proprios_pacotes" ON "public"."pacotes_empresa" FOR SELECT USING (("empresa_id" IN ( SELECT "empresas"."id"
   FROM "public"."empresas"
  WHERE ("empresas"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "empresa_vê_colaboradores" ON "public"."pacientes" FOR SELECT USING (("empresa_id" IN ( SELECT "empresas"."id"
   FROM "public"."empresas"
  WHERE ("empresas"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



ALTER TABLE "public"."empresas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hipoteses_diagnosticas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."intercorrencias" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "leitura_publica_config_geral" ON "public"."config_geral_vulnerabilidade" FOR SELECT USING (true);



CREATE POLICY "leitura_publica_config_pontuacao" ON "public"."config_pontuacao_vulnerabilidade" FOR SELECT USING (true);



CREATE POLICY "leitura_publica_config_precos" ON "public"."config_precos_sessao" FOR SELECT USING (true);



ALTER TABLE "public"."mensalidades_psicologos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "paciente_apaga_propria_avaliacao" ON "public"."avaliacoes" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."pacientes" "p"
  WHERE (("p"."id" = "avaliacoes"."paciente_id") AND ("p"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "paciente_atualiza_proprio_registro" ON "public"."pacientes" FOR UPDATE USING (("email" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "paciente_avalia_apos_sessao_realizada" ON "public"."avaliacoes" FOR INSERT WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."pacientes" "p"
  WHERE (("p"."id" = "avaliacoes"."paciente_id") AND ("p"."email" = ("auth"."jwt"() ->> 'email'::"text"))))) AND (EXISTS ( SELECT 1
   FROM "public"."sessoes" "s"
  WHERE (("s"."paciente_id" = "avaliacoes"."paciente_id") AND ("s"."psicologo_id" = "avaliacoes"."psicologo_id") AND ("s"."status" = 'realizada'::"text"))))));



CREATE POLICY "paciente_avalia_seu_psicologo" ON "public"."avaliacoes" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."pacientes" "p"
  WHERE (("p"."id" = "avaliacoes"."paciente_id") AND ("p"."email" = ("auth"."jwt"() ->> 'email'::"text")) AND ("p"."psicologo_id" = "avaliacoes"."psicologo_id")))));



CREATE POLICY "paciente_cria_propria_ficha" ON "public"."pacientes" FOR INSERT WITH CHECK (("email" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "paciente_edita_propria_avaliacao" ON "public"."avaliacoes" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."pacientes" "p"
  WHERE (("p"."id" = "avaliacoes"."paciente_id") AND ("p"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "paciente_gerencia_proprios_agendamentos" ON "public"."agendamentos" USING ((EXISTS ( SELECT 1
   FROM "public"."pacientes" "p"
  WHERE (("p"."id" = "agendamentos"."paciente_id") AND ("p"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "paciente_gerencia_proprios_checkins" ON "public"."checkins" USING ((EXISTS ( SELECT 1
   FROM "public"."pacientes" "p"
  WHERE (("p"."id" = "checkins"."paciente_id") AND ("p"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "paciente_insert_propria_avaliacao" ON "public"."avaliacoes_socioeconomicas" FOR INSERT WITH CHECK (("paciente_id" IN ( SELECT "pacientes"."id"
   FROM "public"."pacientes"
  WHERE ("pacientes"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "paciente_insert_proprios_comprovantes" ON "public"."comprovantes_vulnerabilidade" FOR INSERT WITH CHECK (("avaliacao_id" IN ( SELECT "avaliacoes_socioeconomicas"."id"
   FROM "public"."avaliacoes_socioeconomicas"
  WHERE ("avaliacoes_socioeconomicas"."paciente_id" IN ( SELECT "pacientes"."id"
           FROM "public"."pacientes"
          WHERE ("pacientes"."email" = ("auth"."jwt"() ->> 'email'::"text")))))));



CREATE POLICY "paciente_select_propria_avaliacao" ON "public"."avaliacoes_socioeconomicas" FOR SELECT USING (("paciente_id" IN ( SELECT "pacientes"."id"
   FROM "public"."pacientes"
  WHERE ("pacientes"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "paciente_select_proprios_comprovantes" ON "public"."comprovantes_vulnerabilidade" FOR SELECT USING (("avaliacao_id" IN ( SELECT "avaliacoes_socioeconomicas"."id"
   FROM "public"."avaliacoes_socioeconomicas"
  WHERE ("avaliacoes_socioeconomicas"."paciente_id" IN ( SELECT "pacientes"."id"
           FROM "public"."pacientes"
          WHERE ("pacientes"."email" = ("auth"."jwt"() ->> 'email'::"text")))))));



CREATE POLICY "paciente_update_propria_avaliacao" ON "public"."avaliacoes_socioeconomicas" FOR UPDATE USING ((("paciente_id" IN ( SELECT "pacientes"."id"
   FROM "public"."pacientes"
  WHERE ("pacientes"."email" = ("auth"."jwt"() ->> 'email'::"text")))) AND ("status" = ANY (ARRAY['pendente'::"text", 'em_revisao'::"text"]))));



CREATE POLICY "paciente_ve_propria_anamnese" ON "public"."anamneses" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."pacientes" "p"
  WHERE (("p"."id" = "anamneses"."paciente_id") AND ("p"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "paciente_ve_proprias_hipoteses" ON "public"."hipoteses_diagnosticas" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."pacientes" "p"
  WHERE (("p"."id" = "hipoteses_diagnosticas"."paciente_id") AND ("p"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "paciente_ve_proprias_intercorrencias" ON "public"."intercorrencias" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."pacientes" "p"
  WHERE (("p"."id" = "intercorrencias"."paciente_id") AND ("p"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "paciente_ve_proprio_registro" ON "public"."pacientes" FOR SELECT USING (("email" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "paciente_ve_seus_pagamentos" ON "public"."pagamentos" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."pacientes" "p"
  WHERE (("p"."id" = "pagamentos"."paciente_id") AND ("p"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "paciente_ve_seus_sintomas" ON "public"."sintomas" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."pacientes" "p"
  WHERE (("p"."id" = "sintomas"."paciente_id") AND ("p"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "paciente_ve_suas_sessoes" ON "public"."sessoes" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."pacientes" "p"
  WHERE (("p"."id" = "sessoes"."paciente_id") AND ("p"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "paciente_vê_si_mesmo" ON "public"."pacientes" USING (("email" = ("auth"."jwt"() ->> 'email'::"text")));



ALTER TABLE "public"."pacientes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pacientes_meupsi" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pacotes_empresa" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "pagamento_empresa" ON "public"."pagamentos" FOR SELECT USING (("paciente_id" IN ( SELECT "p"."id"
   FROM ("public"."pacientes" "p"
     JOIN "public"."empresas" "e" ON (("e"."id" = "p"."empresa_id")))
  WHERE ("e"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "pagamento_paciente" ON "public"."pagamentos" USING (("paciente_id" IN ( SELECT "pacientes"."id"
   FROM "public"."pacientes"
  WHERE ("pacientes"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



ALTER TABLE "public"."pagamentos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "psicologo_cria_proprio_cadastro" ON "public"."psicologos" FOR INSERT WITH CHECK (("email" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "psicologo_delete" ON "public"."pacientes_meupsi" FOR DELETE USING (("psicologo_id" IN ( SELECT "psicologos"."id"
   FROM "public"."psicologos"
  WHERE ("psicologos"."user_id" = "auth"."uid"()))));



CREATE POLICY "psicologo_gerencia_agendamentos_recebidos" ON "public"."agendamentos" USING ((EXISTS ( SELECT 1
   FROM "public"."psicologos" "ps"
  WHERE (("ps"."id" = "agendamentos"."psicologo_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_gerencia_anamneses_dos_seus_pacientes" ON "public"."anamneses" USING ((EXISTS ( SELECT 1
   FROM "public"."psicologos" "ps"
  WHERE (("ps"."id" = "anamneses"."psicologo_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_gerencia_hipoteses_dos_seus_pacientes" ON "public"."hipoteses_diagnosticas" USING ((EXISTS ( SELECT 1
   FROM "public"."psicologos" "ps"
  WHERE (("ps"."id" = "hipoteses_diagnosticas"."psicologo_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_gerencia_intercorrencias_dos_seus_pacientes" ON "public"."intercorrencias" USING ((EXISTS ( SELECT 1
   FROM "public"."psicologos" "ps"
  WHERE (("ps"."id" = "intercorrencias"."psicologo_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_gerencia_propria_assinatura" ON "public"."mensalidades_psicologos" USING ((EXISTS ( SELECT 1
   FROM "public"."psicologos" "ps"
  WHERE (("ps"."id" = "mensalidades_psicologos"."psicologo_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_gerencia_propria_disponibilidade" ON "public"."disponibilidade_semanal" USING ((EXISTS ( SELECT 1
   FROM "public"."psicologos" "ps"
  WHERE (("ps"."id" = "disponibilidade_semanal"."psicologo_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_gerencia_proprias_ausencias" ON "public"."ausencias" USING ((EXISTS ( SELECT 1
   FROM "public"."psicologos" "ps"
  WHERE (("ps"."id" = "ausencias"."psicologo_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_gerencia_seus_pacientes" ON "public"."pacientes" USING ((EXISTS ( SELECT 1
   FROM "public"."psicologos" "ps"
  WHERE (("ps"."id" = "pacientes"."psicologo_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_gerencia_sintomas_dos_seus_pacientes" ON "public"."sintomas" USING ((EXISTS ( SELECT 1
   FROM ("public"."pacientes" "p"
     JOIN "public"."psicologos" "ps" ON (("ps"."id" = "p"."psicologo_id")))
  WHERE (("p"."id" = "sintomas"."paciente_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_gerencia_suas_autorizacoes" ON "public"."autorizacoes_suporte" USING ((EXISTS ( SELECT 1
   FROM "public"."psicologos" "ps"
  WHERE (("ps"."id" = "autorizacoes_suporte"."psicologo_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_gerencia_suas_sessoes" ON "public"."sessoes" USING ((EXISTS ( SELECT 1
   FROM "public"."psicologos" "ps"
  WHERE (("ps"."id" = "sessoes"."psicologo_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_insert" ON "public"."pacientes_meupsi" FOR INSERT WITH CHECK (("psicologo_id" IN ( SELECT "psicologos"."id"
   FROM "public"."psicologos"
  WHERE ("psicologos"."user_id" = "auth"."uid"()))));



CREATE POLICY "psicologo_lista_empresas" ON "public"."empresas" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."psicologos" "ps"
  WHERE ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "psicologo_own" ON "public"."psicologos" USING (("email" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "psicologo_select" ON "public"."pacientes_meupsi" FOR SELECT USING (("psicologo_id" IN ( SELECT "psicologos"."id"
   FROM "public"."psicologos"
  WHERE ("psicologos"."user_id" = "auth"."uid"()))));



CREATE POLICY "psicologo_update" ON "public"."pacientes_meupsi" FOR UPDATE USING (("psicologo_id" IN ( SELECT "psicologos"."id"
   FROM "public"."psicologos"
  WHERE ("psicologos"."user_id" = "auth"."uid"()))));



CREATE POLICY "psicologo_ve_checkins_dos_seus_pacientes" ON "public"."checkins" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ("public"."pacientes" "p"
     JOIN "public"."psicologos" "ps" ON (("ps"."id" = "p"."psicologo_id")))
  WHERE (("p"."id" = "checkins"."paciente_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_ve_e_edita_proprio_registro" ON "public"."psicologos" USING (("email" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "psicologo_ve_seus_pagamentos" ON "public"."pagamentos" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ("public"."pacientes" "p"
     JOIN "public"."psicologos" "ps" ON (("ps"."id" = "p"."psicologo_id")))
  WHERE (("p"."id" = "pagamentos"."paciente_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_ve_suas_mensalidades" ON "public"."mensalidades_psicologos" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."psicologos" "ps"
  WHERE (("ps"."id" = "mensalidades_psicologos"."psicologo_id") AND ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text"))))));



CREATE POLICY "psicologo_vê_pacientes" ON "public"."pacientes" FOR SELECT USING (("psicologo_id" IN ( SELECT "psicologos"."id"
   FROM "public"."psicologos"
  WHERE ("psicologos"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



ALTER TABLE "public"."psicologos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sessao_paciente" ON "public"."sessoes" FOR SELECT USING (("paciente_id" IN ( SELECT "pacientes"."id"
   FROM "public"."pacientes"
  WHERE ("pacientes"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "sessao_psicologo" ON "public"."sessoes" USING (("psicologo_id" IN ( SELECT "psicologos"."id"
   FROM "public"."psicologos"
  WHERE ("psicologos"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



ALTER TABLE "public"."sessoes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sintoma_paciente" ON "public"."sintomas" FOR SELECT USING (("paciente_id" IN ( SELECT "pacientes"."id"
   FROM "public"."pacientes"
  WHERE ("pacientes"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



CREATE POLICY "sintoma_psicologo" ON "public"."sintomas" USING (("paciente_id" IN ( SELECT "p"."id"
   FROM ("public"."pacientes" "p"
     JOIN "public"."psicologos" "ps" ON (("ps"."id" = "p"."psicologo_id")))
  WHERE ("ps"."email" = ("auth"."jwt"() ->> 'email'::"text")))));



ALTER TABLE "public"."sintomas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."solicitacoes_exclusao" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usuario_solicita_propria_exclusao" ON "public"."solicitacoes_exclusao" FOR INSERT WITH CHECK (("email" = ("auth"."jwt"() ->> 'email'::"text")));



CREATE POLICY "usuario_ve_propria_solicitacao" ON "public"."solicitacoes_exclusao" FOR SELECT USING (("email" = ("auth"."jwt"() ->> 'email'::"text")));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";








GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";











































































































































































REVOKE ALL ON FUNCTION "public"."admin_metricas_gerais"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_metricas_gerais"() TO "anon";
GRANT ALL ON FUNCTION "public"."admin_metricas_gerais"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_metricas_gerais"() TO "service_role";



GRANT ALL ON FUNCTION "public"."alocar_valor_sessao"("p_paciente_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."alocar_valor_sessao"("p_paciente_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."alocar_valor_sessao"("p_paciente_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."aplicar_valor_social_paciente"("p_paciente_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."aplicar_valor_social_paciente"("p_paciente_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."aplicar_valor_social_paciente"("p_paciente_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."calcular_pontuacao_vulnerabilidade"() TO "anon";
GRANT ALL ON FUNCTION "public"."calcular_pontuacao_vulnerabilidade"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."calcular_pontuacao_vulnerabilidade"() TO "service_role";



GRANT ALL ON FUNCTION "public"."calcular_valor_sessao"("p_paciente_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calcular_valor_sessao"("p_paciente_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calcular_valor_sessao"("p_paciente_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."checar_criar_sala"("p_sessao_id" "uuid", "p_request_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."checar_criar_sala"("p_sessao_id" "uuid", "p_request_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."checar_criar_sala"("p_sessao_id" "uuid", "p_request_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."checar_criar_token"("p_request_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."checar_criar_token"("p_request_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."checar_criar_token"("p_request_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."contar_atendimentos_psicologo"("p_psicologo_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."contar_atendimentos_psicologo"("p_psicologo_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."contar_atendimentos_psicologo"("p_psicologo_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."copiar_valor_paciente_para_pagamento"() TO "anon";
GRANT ALL ON FUNCTION "public"."copiar_valor_paciente_para_pagamento"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."copiar_valor_paciente_para_pagamento"() TO "service_role";



GRANT ALL ON FUNCTION "public"."daily_chamada_api"("v_method" "text", "v_path" "text", "v_body" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."daily_chamada_api"("v_method" "text", "v_path" "text", "v_body" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."daily_chamada_api"("v_method" "text", "v_path" "text", "v_body" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."enviar_lembretes_sessao"() TO "anon";
GRANT ALL ON FUNCTION "public"."enviar_lembretes_sessao"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enviar_lembretes_sessao"() TO "service_role";



GRANT ALL ON FUNCTION "public"."existe_autorizacao_ativa"("p_paciente_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."existe_autorizacao_ativa"("p_paciente_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."existe_autorizacao_ativa"("p_paciente_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."gerar_slug_psicologo"() TO "anon";
GRANT ALL ON FUNCTION "public"."gerar_slug_psicologo"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."gerar_slug_psicologo"() TO "service_role";



GRANT ALL ON FUNCTION "public"."iniciar_criar_sala"("p_sessao_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."iniciar_criar_sala"("p_sessao_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."iniciar_criar_sala"("p_sessao_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."iniciar_criar_token"("p_sessao_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."iniciar_criar_token"("p_sessao_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."iniciar_criar_token"("p_sessao_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."liberar_vagas_expiradas"() TO "anon";
GRANT ALL ON FUNCTION "public"."liberar_vagas_expiradas"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."liberar_vagas_expiradas"() TO "service_role";



GRANT ALL ON FUNCTION "public"."mind_enviar_email"("v_to" "text", "v_assunto" "text", "v_html" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."mind_enviar_email"("v_to" "text", "v_assunto" "text", "v_html" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mind_enviar_email"("v_to" "text", "v_assunto" "text", "v_html" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."mind_notificar_agendamento_aceito"() TO "anon";
GRANT ALL ON FUNCTION "public"."mind_notificar_agendamento_aceito"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."mind_notificar_agendamento_aceito"() TO "service_role";



GRANT ALL ON FUNCTION "public"."mover_para_revisao_ao_enviar_comprovante"() TO "anon";
GRANT ALL ON FUNCTION "public"."mover_para_revisao_ao_enviar_comprovante"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."mover_para_revisao_ao_enviar_comprovante"() TO "service_role";



GRANT ALL ON FUNCTION "public"."paciente_tem_vulnerabilidade_valida"("p_paciente_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."paciente_tem_vulnerabilidade_valida"("p_paciente_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."paciente_tem_vulnerabilidade_valida"("p_paciente_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."preencher_valores_pagamento"() TO "anon";
GRANT ALL ON FUNCTION "public"."preencher_valores_pagamento"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."preencher_valores_pagamento"() TO "service_role";



GRANT ALL ON FUNCTION "public"."reprocessar_fila_espera_social"() TO "anon";
GRANT ALL ON FUNCTION "public"."reprocessar_fila_espera_social"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reprocessar_fila_espera_social"() TO "service_role";



GRANT ALL ON FUNCTION "public"."reprocessar_pagamentos_aguardando"() TO "anon";
GRANT ALL ON FUNCTION "public"."reprocessar_pagamentos_aguardando"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reprocessar_pagamentos_aguardando"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fn_avaliacao_status_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fn_avaliacao_status_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fn_avaliacao_status_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_fn_pacote_alterado"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_fn_pacote_alterado"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_fn_pacote_alterado"() TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "service_role";
























GRANT ALL ON TABLE "public"."admins" TO "anon";
GRANT ALL ON TABLE "public"."admins" TO "authenticated";
GRANT ALL ON TABLE "public"."admins" TO "service_role";



GRANT ALL ON TABLE "public"."agendamentos" TO "anon";
GRANT ALL ON TABLE "public"."agendamentos" TO "authenticated";
GRANT ALL ON TABLE "public"."agendamentos" TO "service_role";



GRANT ALL ON TABLE "public"."anamneses" TO "anon";
GRANT ALL ON TABLE "public"."anamneses" TO "authenticated";
GRANT ALL ON TABLE "public"."anamneses" TO "service_role";



GRANT ALL ON TABLE "public"."ausencias" TO "anon";
GRANT ALL ON TABLE "public"."ausencias" TO "authenticated";
GRANT ALL ON TABLE "public"."ausencias" TO "service_role";



GRANT ALL ON TABLE "public"."autorizacoes_suporte" TO "anon";
GRANT ALL ON TABLE "public"."autorizacoes_suporte" TO "authenticated";
GRANT ALL ON TABLE "public"."autorizacoes_suporte" TO "service_role";



GRANT ALL ON TABLE "public"."avaliacoes" TO "anon";
GRANT ALL ON TABLE "public"."avaliacoes" TO "authenticated";
GRANT ALL ON TABLE "public"."avaliacoes" TO "service_role";



GRANT ALL ON TABLE "public"."avaliacoes_socioeconomicas" TO "anon";
GRANT ALL ON TABLE "public"."avaliacoes_socioeconomicas" TO "authenticated";
GRANT ALL ON TABLE "public"."avaliacoes_socioeconomicas" TO "service_role";



GRANT ALL ON TABLE "public"."checkins" TO "anon";
GRANT ALL ON TABLE "public"."checkins" TO "authenticated";
GRANT ALL ON TABLE "public"."checkins" TO "service_role";



GRANT ALL ON TABLE "public"."comprovantes_vulnerabilidade" TO "anon";
GRANT ALL ON TABLE "public"."comprovantes_vulnerabilidade" TO "authenticated";
GRANT ALL ON TABLE "public"."comprovantes_vulnerabilidade" TO "service_role";



GRANT ALL ON TABLE "public"."config_geral_vulnerabilidade" TO "anon";
GRANT ALL ON TABLE "public"."config_geral_vulnerabilidade" TO "authenticated";
GRANT ALL ON TABLE "public"."config_geral_vulnerabilidade" TO "service_role";



GRANT ALL ON TABLE "public"."config_pontuacao_vulnerabilidade" TO "anon";
GRANT ALL ON TABLE "public"."config_pontuacao_vulnerabilidade" TO "authenticated";
GRANT ALL ON TABLE "public"."config_pontuacao_vulnerabilidade" TO "service_role";



GRANT ALL ON TABLE "public"."config_precos_sessao" TO "anon";
GRANT ALL ON TABLE "public"."config_precos_sessao" TO "authenticated";
GRANT ALL ON TABLE "public"."config_precos_sessao" TO "service_role";



GRANT ALL ON TABLE "public"."disponibilidade_semanal" TO "anon";
GRANT ALL ON TABLE "public"."disponibilidade_semanal" TO "authenticated";
GRANT ALL ON TABLE "public"."disponibilidade_semanal" TO "service_role";



GRANT ALL ON TABLE "public"."empresas" TO "anon";
GRANT ALL ON TABLE "public"."empresas" TO "authenticated";
GRANT ALL ON TABLE "public"."empresas" TO "service_role";



GRANT ALL ON TABLE "public"."hipoteses_diagnosticas" TO "anon";
GRANT ALL ON TABLE "public"."hipoteses_diagnosticas" TO "authenticated";
GRANT ALL ON TABLE "public"."hipoteses_diagnosticas" TO "service_role";



GRANT ALL ON TABLE "public"."intercorrencias" TO "anon";
GRANT ALL ON TABLE "public"."intercorrencias" TO "authenticated";
GRANT ALL ON TABLE "public"."intercorrencias" TO "service_role";



GRANT ALL ON TABLE "public"."mensalidades_psicologos" TO "anon";
GRANT ALL ON TABLE "public"."mensalidades_psicologos" TO "authenticated";
GRANT ALL ON TABLE "public"."mensalidades_psicologos" TO "service_role";



GRANT ALL ON TABLE "public"."pacientes" TO "anon";
GRANT ALL ON TABLE "public"."pacientes" TO "authenticated";
GRANT ALL ON TABLE "public"."pacientes" TO "service_role";



GRANT ALL ON TABLE "public"."pacientes_agregado_empresa" TO "anon";
GRANT ALL ON TABLE "public"."pacientes_agregado_empresa" TO "authenticated";
GRANT ALL ON TABLE "public"."pacientes_agregado_empresa" TO "service_role";



GRANT ALL ON TABLE "public"."pacientes_meupsi" TO "anon";
GRANT ALL ON TABLE "public"."pacientes_meupsi" TO "authenticated";
GRANT ALL ON TABLE "public"."pacientes_meupsi" TO "service_role";



GRANT ALL ON TABLE "public"."pacotes_empresa" TO "anon";
GRANT ALL ON TABLE "public"."pacotes_empresa" TO "authenticated";
GRANT ALL ON TABLE "public"."pacotes_empresa" TO "service_role";



GRANT ALL ON TABLE "public"."pagamentos" TO "anon";
GRANT ALL ON TABLE "public"."pagamentos" TO "authenticated";
GRANT ALL ON TABLE "public"."pagamentos" TO "service_role";



GRANT ALL ON TABLE "public"."pagamentos_agregado_empresa" TO "anon";
GRANT ALL ON TABLE "public"."pagamentos_agregado_empresa" TO "authenticated";
GRANT ALL ON TABLE "public"."pagamentos_agregado_empresa" TO "service_role";



GRANT ALL ON TABLE "public"."psicologos" TO "anon";
GRANT ALL ON TABLE "public"."psicologos" TO "authenticated";
GRANT ALL ON TABLE "public"."psicologos" TO "service_role";



GRANT ALL ON TABLE "public"."psicologos_publico" TO "anon";
GRANT ALL ON TABLE "public"."psicologos_publico" TO "authenticated";
GRANT ALL ON TABLE "public"."psicologos_publico" TO "service_role";



GRANT ALL ON TABLE "public"."resumo_pacotes_empresa" TO "anon";
GRANT ALL ON TABLE "public"."resumo_pacotes_empresa" TO "authenticated";
GRANT ALL ON TABLE "public"."resumo_pacotes_empresa" TO "service_role";



GRANT ALL ON TABLE "public"."resumo_subsidio_plataforma" TO "anon";
GRANT ALL ON TABLE "public"."resumo_subsidio_plataforma" TO "authenticated";
GRANT ALL ON TABLE "public"."resumo_subsidio_plataforma" TO "service_role";



GRANT ALL ON TABLE "public"."sessoes" TO "anon";
GRANT ALL ON TABLE "public"."sessoes" TO "authenticated";
GRANT ALL ON TABLE "public"."sessoes" TO "service_role";



GRANT ALL ON TABLE "public"."sessoes_agregado_empresa" TO "anon";
GRANT ALL ON TABLE "public"."sessoes_agregado_empresa" TO "authenticated";
GRANT ALL ON TABLE "public"."sessoes_agregado_empresa" TO "service_role";



GRANT ALL ON TABLE "public"."sintomas" TO "anon";
GRANT ALL ON TABLE "public"."sintomas" TO "authenticated";
GRANT ALL ON TABLE "public"."sintomas" TO "service_role";



GRANT ALL ON TABLE "public"."solicitacoes_exclusao" TO "anon";
GRANT ALL ON TABLE "public"."solicitacoes_exclusao" TO "authenticated";
GRANT ALL ON TABLE "public"."solicitacoes_exclusao" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";



































