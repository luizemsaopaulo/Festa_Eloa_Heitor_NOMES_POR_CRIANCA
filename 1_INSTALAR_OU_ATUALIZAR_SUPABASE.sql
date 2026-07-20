-- ============================================================================
-- ELOÁ E HEITOR — FORMULÁRIO SIMPLES + PAINEL SEM SENHA
--
-- Este arquivo pode ser executado tanto no projeto já configurado quanto em
-- um projeto novo. Ele NÃO apaga confirmações antigas. O painel novo exibe
-- apenas respostas com presença confirmada.
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.confirmacoes (
  id uuid primary key default gen_random_uuid(),
  evento text not null default 'Aniversário de Eloá e Heitor',
  nome text not null,
  telefone text,
  vai_comparecer boolean not null default true,
  quantidade_pessoas integer not null default 1,
  nomes_acompanhantes text,
  mensagem text,
  criado_em timestamptz not null default now()
);

alter table public.confirmacoes
  add column if not exists protocolo text,
  add column if not exists atualizado_em timestamptz not null default now(),
  add column if not exists criancas jsonb not null default '[]'::jsonb,
  add column if not exists restricoes text,
  add column if not exists nome_crianca_recusada text;

update public.confirmacoes
set protocolo = 'EH-' || upper(encode(extensions.gen_random_bytes(4), 'hex'))
where protocolo is null or btrim(protocolo) = '';

alter table public.confirmacoes
  alter column protocolo set default ('EH-' || upper(encode(extensions.gen_random_bytes(4), 'hex'))),
  alter column protocolo set not null;

create index if not exists confirmacoes_atualizado_em_idx on public.confirmacoes (atualizado_em desc);
alter table public.confirmacoes enable row level security;
revoke all on table public.confirmacoes from anon, authenticated;

create table if not exists public.configuracao_evento (
  id smallint primary key default 1 check (id = 1),
  event_title text not null default 'Aniversário de Eloá e Heitor',
  child1_name text not null default 'Eloá',
  child1_age integer default 7,
  child2_name text not null default 'Heitor',
  child2_age integer default 2,
  event_date date,
  event_time time,
  event_end_time time,
  location_name text,
  address text,
  event_note text not null default '',
  deadline date,
  invite_rule text not null default '',
  max_children_per_response integer not null default 10,
  atualizado_em timestamptz not null default now()
);

alter table public.configuracao_evento
  add column if not exists event_title text not null default 'Aniversário de Eloá e Heitor',
  add column if not exists child1_name text not null default 'Eloá',
  add column if not exists child1_age integer default 7,
  add column if not exists child2_name text not null default 'Heitor',
  add column if not exists child2_age integer default 2,
  add column if not exists event_date date,
  add column if not exists event_time time,
  add column if not exists event_end_time time,
  add column if not exists location_name text,
  add column if not exists address text,
  add column if not exists event_note text not null default '',
  add column if not exists deadline date,
  add column if not exists invite_rule text not null default '',
  add column if not exists max_children_per_response integer not null default 10,
  add column if not exists atualizado_em timestamptz not null default now();

insert into public.configuracao_evento (
  id, event_title, child1_name, child1_age, child2_name, child2_age,
  event_date, event_time, event_end_time, location_name, address,
  event_note, invite_rule, max_children_per_response, atualizado_em
) values (
  1, 'Aniversário de Eloá e Heitor', 'Eloá', 7, 'Heitor', 2,
  date '2026-08-01', time '14:00', time '18:00',
  'Casa da Lu e do Rodrigo', 'Rodovia Augusto Freire, 500 — Juncal',
  'Esperamos você para uma tarde muito especial!',
  'Informe quantas crianças irão e escreva o nome de cada uma.', 10, now()
)
on conflict (id) do update set
  event_title = excluded.event_title,
  child1_name = excluded.child1_name,
  child1_age = excluded.child1_age,
  child2_name = excluded.child2_name,
  child2_age = excluded.child2_age,
  event_date = excluded.event_date,
  event_time = excluded.event_time,
  event_end_time = excluded.event_end_time,
  location_name = excluded.location_name,
  address = excluded.address,
  event_note = excluded.event_note,
  invite_rule = excluded.invite_rule,
  max_children_per_response = excluded.max_children_per_response,
  atualizado_em = now();

alter table public.configuracao_evento enable row level security;
revoke all on table public.configuracao_evento from anon, authenticated;

create or replace function public.obter_configuracao_publica()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select jsonb_build_object(
    'ok', true,
    'config', jsonb_build_object(
      'eventTitle', event_title,
      'child1Name', child1_name,
      'child1Age', coalesce(child1_age::text, ''),
      'child2Name', child2_name,
      'child2Age', coalesce(child2_age::text, ''),
      'eventDate', coalesce(to_char(event_date, 'YYYY-MM-DD'), ''),
      'eventTime', coalesce(to_char(event_time, 'HH24:MI'), ''),
      'eventEndTime', coalesce(to_char(event_end_time, 'HH24:MI'), ''),
      'locationName', coalesce(location_name, ''),
      'address', coalesce(address, ''),
      'eventNote', coalesce(event_note, ''),
      'deadline', coalesce(to_char(deadline, 'YYYY-MM-DD'), ''),
      'inviteRule', coalesce(invite_rule, ''),
      'maxChildrenPerResponse', max_children_per_response
    )
  )
  from public.configuracao_evento where id = 1;
$$;
revoke all on function public.obter_configuracao_publica() from public;
grant execute on function public.obter_configuracao_publica() to anon, authenticated;

-- Envio com a quantidade e o nome individual de cada criança.
-- Os nomes chegam como texto, um por linha, evitando problemas de JSON no navegador.
drop function if exists public.registrar_confirmacao_simples(text, integer, text);
create function public.registrar_confirmacao_simples(
  p_nomes_criancas text,
  p_quantidade integer,
  p_website text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_quantidade integer := coalesce(p_quantidade, 0);
  v_nomes text[];
  v_protocolo text;
  v_nome text;
begin
  if btrim(coalesce(p_website, '')) <> '' then
    return jsonb_build_object('ok', true);
  end if;

  if v_quantidade < 1 or v_quantidade > 20 then
    raise exception 'Informe entre 1 e 20 crianças.';
  end if;

  select coalesce(array_agg(left(btrim(item), 120) order by ordem), array[]::text[])
  into v_nomes
  from unnest(regexp_split_to_array(replace(coalesce(p_nomes_criancas, ''), E'\r', ''), E'\n'))
       with ordinality as nomes(item, ordem)
  where btrim(item) <> '';

  if cardinality(v_nomes) <> v_quantidade then
    raise exception 'Informe o nome de cada criança. A quantidade de nomes deve ser igual à quantidade selecionada.';
  end if;

  if exists (select 1 from unnest(v_nomes) as n(nome) where char_length(n.nome) < 2) then
    raise exception 'Cada nome deve ter pelo menos 2 caracteres.';
  end if;


  v_nome := v_nomes[1];
  v_protocolo := 'EH-' || upper(encode(extensions.gen_random_bytes(4), 'hex'));

  insert into public.confirmacoes (
    protocolo, evento, nome, telefone, vai_comparecer, quantidade_pessoas,
    nomes_acompanhantes, mensagem, criancas, restricoes,
    nome_crianca_recusada, criado_em, atualizado_em
  ) values (
    v_protocolo, 'Aniversário de Eloá e Heitor', v_nome, null, true,
    v_quantidade, array_to_string(v_nomes, E'\n'), null,
    to_jsonb(v_nomes), null, null, now(), now()
  );

  return jsonb_build_object(
    'ok', true,
    'childrenCount', v_quantidade,
    'childrenNamesText', array_to_string(v_nomes, E'\n')
  );
end;
$$;
revoke all on function public.registrar_confirmacao_simples(text, integer, text) from public;
grant execute on function public.registrar_confirmacao_simples(text, integer, text) to anon, authenticated;

-- Painel sem senha: mostra somente confirmações positivas.
create or replace function public.listar_confirmacoes_simples()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_respostas jsonb;
  v_registros integer;
  v_criancas integer;
begin
  select count(*), coalesce(sum(quantidade_pessoas), 0)
  into v_registros, v_criancas
  from public.confirmacoes
  where vai_comparecer is true;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'protocol', c.protocolo,
      'updatedAt', to_char(c.atualizado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
      'childName', c.nome,
      'childrenNamesText', coalesce(nullif(btrim(c.nomes_acompanhantes), ''), c.nome),
      'childrenCount', c.quantidade_pessoas
    ) order by c.atualizado_em desc, c.criado_em desc
  ), '[]'::jsonb)
  into v_respostas
  from public.confirmacoes c
  where c.vai_comparecer is true;

  return jsonb_build_object(
    'ok', true,
    'stats', jsonb_build_object('confirmedEntries', v_registros, 'confirmedChildren', v_criancas),
    'responses', v_respostas
  );
end;
$$;
revoke all on function public.listar_confirmacoes_simples() from public;
grant execute on function public.listar_confirmacoes_simples() to anon, authenticated;

-- Exclusão das confirmações selecionadas no painel.
drop function if exists public.excluir_confirmacoes_sem_senha(text);
create function public.excluir_confirmacoes_sem_senha(p_protocolos_csv text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public
as $$
declare
  v_protocolos text[];
  v_excluidas integer := 0;
begin
  select coalesce(array_agg(distinct upper(btrim(item))), array[]::text[])
  into v_protocolos
  from unnest(string_to_array(coalesce(p_protocolos_csv, ''), ',')) as item
  where upper(btrim(item)) ~ '^EH-[A-F0-9]{8}$';

  if coalesce(cardinality(v_protocolos), 0) = 0 then
    raise exception 'Nenhuma confirmação válida foi selecionada.';
  end if;

  delete from public.confirmacoes where upper(protocolo) = any(v_protocolos);
  get diagnostics v_excluidas = row_count;
  return jsonb_build_object('ok', true, 'deleted', v_excluidas);
end;
$$;
revoke all on function public.excluir_confirmacoes_sem_senha(text) from public;
grant execute on function public.excluir_confirmacoes_sem_senha(text) to anon, authenticated;

notify pgrst, 'reload schema';
