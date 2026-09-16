-- Registro de vendas (formulário /nova-venda)
-- vendas: uma linha por venda. venda_acessos: uma linha por produto, com início e fim do acesso.
-- A página só grava via registrar_venda(); anon não lê nem escreve nas tabelas direto.

create table if not exists public.vendas (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  vendedor text not null,
  tipo text not null check (tipo in ('nova','renovacao','upgrade')),
  data_venda date not null,
  aluno_nome text not null,
  aluno_email text not null,
  aluno_telefone text not null,
  aluno_documento text,
  aluno_instagram text,
  aluno_especialidade text,
  aluno_cidade text,
  valor_total numeric(12,2) not null check (valor_total > 0),
  forma_pagamento text not null check (forma_pagamento in ('pix','cartao','pix_recorrente','boleto_recorrente','cartao_recorrente')),
  plataforma text not null,
  cartao_parcelas int check (cartao_parcelas between 1 and 24),
  entrada_valor numeric(12,2),
  entrada_forma text check (entrada_forma in ('pix','cartao','boleto')),
  parcelas_qtd int check (parcelas_qtd between 1 and 60),
  parcela_valor numeric(12,2),
  primeiro_vencimento date,
  pagamento_detalhes text,
  bonus text[] not null default '{}',
  observacoes text,
  status text not null default 'ativa' check (status in ('ativa','cancelada','reembolsada'))
);

create table if not exists public.venda_acessos (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  venda_id uuid not null references public.vendas(id) on delete cascade,
  produto text not null check (produto in ('mentoria','posgrad','master','workshop','thunder','outro')),
  produto_detalhe text,
  inicio date not null,
  duracao_meses int check (duracao_meses between 1 and 120), -- null = evento
  fim date not null
);

create index if not exists vendas_data_venda_idx on public.vendas (data_venda);
create index if not exists vendas_email_idx on public.vendas (lower(aluno_email));
create index if not exists venda_acessos_venda_idx on public.venda_acessos (venda_id);
create index if not exists venda_acessos_fim_idx on public.venda_acessos (fim);

alter table public.vendas enable row level security;
alter table public.venda_acessos enable row level security;
revoke all on public.vendas, public.venda_acessos from anon, authenticated;

create or replace function public.registrar_venda(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  a jsonb;
  v_meses int;
  v_inicio date;
  v_forma text := p->>'forma_pagamento';
begin
  if coalesce(trim(p->>'vendedor'),'') = '' then raise exception 'vendedor obrigatório'; end if;
  if coalesce(trim(p->>'aluno_nome'),'') = '' then raise exception 'nome obrigatório'; end if;
  if coalesce(trim(p->>'aluno_email'),'') !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then raise exception 'e-mail inválido'; end if;
  if length(regexp_replace(coalesce(p->>'aluno_telefone',''),'\D','','g')) not between 12 and 13 then raise exception 'telefone inválido'; end if;
  if jsonb_typeof(p->'acessos') <> 'array' or jsonb_array_length(p->'acessos') = 0 then raise exception 'ao menos um produto'; end if;
  if jsonb_array_length(p->'acessos') > 10 then raise exception 'produtos demais'; end if;
  if coalesce(jsonb_array_length(p->'bonus'),0) = 0 and coalesce((p->>'sem_bonus')::boolean,false) = false then
    raise exception 'bônus ou "sem bônus" obrigatório';
  end if;
  if v_forma like '%_recorrente' and (p->>'parcelas_qtd' is null or p->>'parcela_valor' is null or p->>'primeiro_vencimento' is null) then
    raise exception 'recorrência incompleta';
  end if;

  insert into public.vendas (
    vendedor, tipo, data_venda, aluno_nome, aluno_email, aluno_telefone, aluno_documento,
    aluno_instagram, aluno_especialidade, aluno_cidade, valor_total, forma_pagamento, plataforma,
    cartao_parcelas, entrada_valor, entrada_forma, parcelas_qtd, parcela_valor, primeiro_vencimento,
    pagamento_detalhes, bonus, observacoes
  ) values (
    left(trim(p->>'vendedor'),120), p->>'tipo', (p->>'data_venda')::date,
    left(trim(p->>'aluno_nome'),200), lower(left(trim(p->>'aluno_email'),200)), left(p->>'aluno_telefone',20),
    left(nullif(p->>'aluno_documento',''),20), left(nullif(p->>'aluno_instagram',''),80),
    left(nullif(p->>'aluno_especialidade',''),120), left(nullif(p->>'aluno_cidade',''),120),
    (p->>'valor_total')::numeric, v_forma, left(trim(p->>'plataforma'),60),
    case when v_forma = 'cartao' then (p->>'cartao_parcelas')::int end,
    case when v_forma like '%_recorrente' then (p->>'entrada_valor')::numeric end,
    case when v_forma like '%_recorrente' then nullif(p->>'entrada_forma','') end,
    case when v_forma like '%_recorrente' then (p->>'parcelas_qtd')::int end,
    case when v_forma like '%_recorrente' then (p->>'parcela_valor')::numeric end,
    case when v_forma like '%_recorrente' then (p->>'primeiro_vencimento')::date end,
    left(nullif(p->>'pagamento_detalhes',''),2000),
    coalesce((select array_agg(left(b,300)) from jsonb_array_elements_text(p->'bonus') b where trim(b) <> ''), '{}'),
    left(nullif(p->>'observacoes',''),4000)
  ) returning id into v_id;

  for a in select * from jsonb_array_elements(p->'acessos') loop
    v_inicio := (a->>'inicio')::date;
    v_meses := nullif(a->>'duracao_meses','')::int;
    insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, duracao_meses, fim)
    values (
      v_id, a->>'produto', left(nullif(a->>'produto_detalhe',''),200), v_inicio, v_meses,
      case when v_meses is null then v_inicio else (v_inicio + make_interval(months => v_meses))::date end
    );
  end loop;

  return v_id;
end;
$$;

revoke all on function public.registrar_venda(jsonb) from public;
grant execute on function public.registrar_venda(jsonb) to anon, authenticated;
