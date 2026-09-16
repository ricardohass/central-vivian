-- Abas Vendas e Alunos + importação das planilhas antigas
-- vendas passa a aceitar registros importados (sem vendedor/valor), marcados em origem.
-- venda_acessos ganha a_confirmar: tempo de acesso desconhecido fica sem fim, em vez de chutado.
-- base_antiga guarda a planilha Clientes x Produtos como veio, sem virar venda: não é confiável.

alter table public.vendas
  add column if not exists origem text not null default 'formulario',
  add column if not exists import_ref text,
  add column if not exists produto_original text,
  add column if not exists tempo_acesso_original text,
  add column if not exists updated_at timestamptz,
  add column if not exists updated_by text;

alter table public.vendas drop constraint if exists vendas_origem_check;
alter table public.vendas add constraint vendas_origem_check check (origem in ('formulario','planilha_onboarding'));
alter table public.vendas drop constraint if exists vendas_import_ref_key;
alter table public.vendas add constraint vendas_import_ref_key unique (import_ref);

alter table public.vendas
  alter column vendedor drop not null,
  alter column valor_total drop not null,
  alter column forma_pagamento drop not null,
  alter column plataforma drop not null,
  alter column aluno_telefone drop not null;

alter table public.venda_acessos
  add column if not exists a_confirmar boolean not null default false,
  alter column fim drop not null;

create table if not exists public.base_antiga (
  id text primary key,
  nome text,
  telefone text,
  telefone_original text,
  grupo_mentoria text check (grupo_mentoria in ('ativo','removido')),
  localizado_via text,
  qtd_compras int,
  compras jsonb not null default '[]',
  colaborador boolean not null default false,
  alerta text,
  created_at timestamptz not null default now()
);
alter table public.base_antiga enable row level security;
revoke all on public.base_antiga from anon, authenticated;

-- onboarding_listar passa a devolver id e a_confirmar de cada acesso
create or replace function public.onboarding_listar(p_email text, p_senha text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.usuarios where email = p_email and senha = p_senha) then
    raise exception 'não autorizado';
  end if;

  return coalesce((
    select jsonb_agg(
      to_jsonb(v)
      || jsonb_build_object(
        'acessos', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', a.id, 'produto', a.produto, 'produto_detalhe', a.produto_detalhe,
            'inicio', a.inicio, 'duracao_meses', a.duracao_meses, 'fim', a.fim, 'a_confirmar', a.a_confirmar
          ) order by a.inicio, a.produto)
          from public.venda_acessos a where a.venda_id = v.id
        ), '[]'::jsonb),
        'chamado', o.chamado,
        'onboarding_status', o.onboarding_status,
        'call_status', o.call_status,
        'observacao', o.observacao,
        'ob_updated_at', o.updated_at,
        'ob_updated_by', o.updated_by
      )
      order by v.data_venda desc, v.created_at desc
    )
    from public.vendas v
    left join public.onboarding o on o.venda_id = v.id
  ), '[]'::jsonb);
end;
$$;

create or replace function public.base_antiga_listar(p_email text, p_senha text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.usuarios where email = p_email and senha = p_senha) then
    raise exception 'não autorizado';
  end if;
  return coalesce((select jsonb_agg(to_jsonb(b) order by b.id) from public.base_antiga b), '[]'::jsonb);
end;
$$;

-- Completa ou corrige uma venda: closer, valor, forma, data, tipo, status e o tempo de cada acesso.
-- Só mexe nas chaves presentes em p.
create or replace function public.venda_editar(p_email text, p_senha text, p_venda_id uuid, p jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome text;
  a jsonb;
  v_meses int;
  v_inicio date;
  v_conf boolean;
begin
  select nome into v_nome from public.usuarios where email = p_email and senha = p_senha;
  if v_nome is null then raise exception 'não autorizado'; end if;
  if not exists (select 1 from public.vendas where id = p_venda_id) then raise exception 'venda não encontrada'; end if;

  update public.vendas set
    vendedor        = case when p ? 'vendedor' then left(nullif(trim(p->>'vendedor'),''),120) else vendedor end,
    valor_total     = case when p ? 'valor_total' then nullif(p->>'valor_total','')::numeric else valor_total end,
    forma_pagamento = case when p ? 'forma_pagamento' then nullif(p->>'forma_pagamento','') else forma_pagamento end,
    plataforma      = case when p ? 'plataforma' then left(nullif(trim(p->>'plataforma'),''),60) else plataforma end,
    data_venda      = case when p ? 'data_venda' then (p->>'data_venda')::date else data_venda end,
    tipo            = case when p ? 'tipo' then p->>'tipo' else tipo end,
    status          = case when p ? 'status' then p->>'status' else status end,
    updated_at = now(),
    updated_by = v_nome
  where id = p_venda_id;

  if jsonb_typeof(p->'acessos') = 'array' then
    for a in select * from jsonb_array_elements(p->'acessos') loop
      v_inicio := (a->>'inicio')::date;
      v_meses := nullif(a->>'duracao_meses','')::int;
      v_conf := coalesce((a->>'a_confirmar')::boolean, false);
      if v_meses is not null and v_meses not between 1 and 120 then raise exception 'duração inválida'; end if;
      update public.venda_acessos set
        inicio = v_inicio,
        duracao_meses = case when v_conf then null else v_meses end,
        a_confirmar = v_conf,
        fim = case
          when v_conf then null
          when v_meses is null then v_inicio
          else (v_inicio + make_interval(months => v_meses))::date
        end
      where id = (a->>'id')::uuid and venda_id = p_venda_id;
    end loop;
  end if;
end;
$$;

revoke all on function public.base_antiga_listar(text, text) from public;
revoke all on function public.venda_editar(text, text, uuid, jsonb) from public;
grant execute on function public.base_antiga_listar(text, text) to anon, authenticated;
grant execute on function public.venda_editar(text, text, uuid, jsonb) to anon, authenticated;
