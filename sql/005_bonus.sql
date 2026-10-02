-- Bônus como lista fechada.
-- bonus_catalogo: os bônus que existem. vendas.bonus continua text[], mas agora só com nomes do catálogo.
-- vendas.bonus_obs: detalhe do bônus naquela venda (ex.: "2 calls de 1h"), no formato {nome do bônus: detalhe}.
-- Bônus novo entra no catálogo quando a venda é salva (registrar_venda / venda_editar); a conferência de
-- "já existe um parecido" é feita na tela. Renomear, unificar e excluir: só administrador, pela Central.
-- Pode rodar mais de uma vez.

create table if not exists public.bonus_catalogo (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  chave text not null unique, -- nome sem acento, caixa e pontuação: é o que define "mesmo bônus"
  created_at timestamptz not null default now(),
  created_by text
);
alter table public.bonus_catalogo enable row level security;
revoke all on public.bonus_catalogo from anon, authenticated;

alter table public.vendas add column if not exists bonus_obs jsonb not null default '{}'::jsonb;

-- Nome de exibição: espaços colapsados, sem o prefixo "Bônus"/"Bônus de", primeira letra maiúscula, até 120.
create or replace function public.bonus_nome(t text)
returns text
language sql
immutable
as $$
  select upper(left(x, 1)) || substr(x, 2)
  from (
    select trim(left(regexp_replace(
      trim(regexp_replace(coalesce(t, ''), '\s+', ' ', 'g')),
      '^b[oôÔ]nus( ?(:|-|–) ?| )(d[aeo] )?', '', 'i'), 120)) as x
  ) s
$$;

create or replace function public.bonus_chave(t text)
returns text
language sql
immutable
as $$
  select trim(regexp_replace(
    translate(lower(public.bonus_nome(t)),
      'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
      'aaaaaeeeeiiiiooooouuuucnaaaaaeeeeiiiiooooouuuucn'),
    '[^a-z0-9]+', ' ', 'g'))
$$;

-- Recebe a lista de bônus da venda (e os detalhes) e devolve os nomes do catálogo, criando o que for novo.
create or replace function public.bonus_resolver(p_bonus jsonb, p_obs jsonb, p_quem text, out nomes text[], out obs jsonb)
language plpgsql
security definer
set search_path = public
as $$
declare
  b text;
  k text;
  v_chave text;
  v_nome text;
  v_obs text;
begin
  nomes := '{}';
  obs := '{}'::jsonb;
  if p_bonus is null or jsonb_typeof(p_bonus) <> 'array' then return; end if;

  for b in select value from jsonb_array_elements_text(p_bonus) loop
    v_chave := public.bonus_chave(b);
    if v_chave = '' then continue; end if;
    select c.nome into v_nome from public.bonus_catalogo c where c.chave = v_chave;
    if v_nome is null then
      insert into public.bonus_catalogo (nome, chave, created_by)
      values (public.bonus_nome(b), v_chave, left(nullif(trim(p_quem), ''), 120))
      on conflict (chave) do nothing;
      select c.nome into v_nome from public.bonus_catalogo c where c.chave = v_chave;
    end if;
    if not (v_nome = any(nomes)) then nomes := nomes || v_nome; end if;
  end loop;

  if p_obs is not null and jsonb_typeof(p_obs) = 'object' then
    for k, v_obs in select key, trim(value) from jsonb_each_text(p_obs) loop
      select c.nome into v_nome from public.bonus_catalogo c where c.chave = public.bonus_chave(k);
      if v_nome is not null and v_nome = any(nomes) and coalesce(v_obs, '') <> '' then
        obs := obs || jsonb_build_object(v_nome, left(v_obs, 300));
      end if;
    end loop;
  end if;
end;
$$;

-- Lista para o formulário (sem login): nome e em quantas vendas aparece.
create or replace function public.bonus_listar()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'nome', t.nome, 'usos', t.usos) order by t.usos desc, t.nome), '[]'::jsonb)
  from (
    select c.id, c.nome, (select count(*) from public.vendas v where c.nome = any(v.bonus)) as usos
    from public.bonus_catalogo c
  ) t
$$;

create or replace function public.bonus_renomear(p_email text, p_senha text, p_id uuid, p_nome text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nivel text;
  v_antigo text;
  v_novo text := public.bonus_nome(p_nome);
  v_chave text := public.bonus_chave(p_nome);
begin
  select nivel into v_nivel from public.usuarios where email = p_email and senha = p_senha;
  if v_nivel is null then raise exception 'não autorizado'; end if;
  if v_nivel <> 'adm' then raise exception 'só administrador altera a lista de bônus'; end if;
  select nome into v_antigo from public.bonus_catalogo where id = p_id;
  if v_antigo is null then raise exception 'bônus não encontrado'; end if;
  if length(v_chave) < 3 then raise exception 'nome muito curto'; end if;
  if exists (select 1 from public.bonus_catalogo where chave = v_chave and id <> p_id) then
    raise exception 'já existe um bônus com esse nome; use Unificar';
  end if;

  update public.bonus_catalogo set nome = v_novo, chave = v_chave where id = p_id;
  if v_novo <> v_antigo then
    update public.vendas set
      bonus = array_replace(bonus, v_antigo, v_novo),
      bonus_obs = case when bonus_obs ? v_antigo
        then (bonus_obs - v_antigo) || jsonb_build_object(v_novo, bonus_obs -> v_antigo)
        else bonus_obs end
    where v_antigo = any(bonus);
  end if;
end;
$$;

-- Junta p_de em p_para: as vendas passam a ter p_para, e o texto antigo fica como detalhe da venda.
create or replace function public.bonus_unificar(p_email text, p_senha text, p_de uuid, p_para uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nivel text;
  v_de text;
  v_para text;
  n int;
begin
  select nivel into v_nivel from public.usuarios where email = p_email and senha = p_senha;
  if v_nivel is null then raise exception 'não autorizado'; end if;
  if v_nivel <> 'adm' then raise exception 'só administrador altera a lista de bônus'; end if;
  if p_de = p_para then raise exception 'escolha dois bônus diferentes'; end if;
  select nome into v_de from public.bonus_catalogo where id = p_de;
  select nome into v_para from public.bonus_catalogo where id = p_para;
  if v_de is null or v_para is null then raise exception 'bônus não encontrado'; end if;

  update public.vendas v set
    bonus = (
      select array_agg(t.x order by t.ord)
      from (
        select u.x, min(u.ord) as ord
        from unnest(array_replace(v.bonus, v_de, v_para)) with ordinality as u(x, ord)
        group by u.x
      ) t
    ),
    bonus_obs = (v.bonus_obs - v_de) || jsonb_build_object(
      v_para,
      concat_ws(' · ', nullif(v.bonus_obs ->> v_para, ''), coalesce(nullif(v.bonus_obs ->> v_de, ''), v_de))
    )
  where v_de = any(v.bonus);
  get diagnostics n = row_count;

  delete from public.bonus_catalogo where id = p_de;
  return n;
end;
$$;

create or replace function public.bonus_excluir(p_email text, p_senha text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nivel text;
  v_nome text;
begin
  select nivel into v_nivel from public.usuarios where email = p_email and senha = p_senha;
  if v_nivel is null then raise exception 'não autorizado'; end if;
  if v_nivel <> 'adm' then raise exception 'só administrador altera a lista de bônus'; end if;
  select nome into v_nome from public.bonus_catalogo where id = p_id;
  if v_nome is null then raise exception 'bônus não encontrado'; end if;
  if exists (select 1 from public.vendas where v_nome = any(bonus)) then
    raise exception 'bônus em uso; unifique com outro em vez de excluir';
  end if;
  delete from public.bonus_catalogo where id = p_id;
end;
$$;

-- registrar_venda: igual à de 001, com os bônus passando pelo catálogo.
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
  v_bonus text[];
  v_bobs jsonb;
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
  if jsonb_array_length(coalesce(p->'bonus','[]'::jsonb)) > 30 then raise exception 'bônus demais'; end if;
  if v_forma like '%_recorrente' and (p->>'parcelas_qtd' is null or p->>'parcela_valor' is null or p->>'primeiro_vencimento' is null) then
    raise exception 'recorrência incompleta';
  end if;

  select r.nomes, r.obs into v_bonus, v_bobs
  from public.bonus_resolver(p->'bonus', p->'bonus_obs', p->>'vendedor') r;

  insert into public.vendas (
    vendedor, tipo, data_venda, aluno_nome, aluno_email, aluno_telefone, aluno_documento,
    aluno_instagram, aluno_especialidade, aluno_cidade, valor_total, forma_pagamento, plataforma,
    cartao_parcelas, entrada_valor, entrada_forma, parcelas_qtd, parcela_valor, primeiro_vencimento,
    pagamento_detalhes, bonus, bonus_obs, observacoes
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
    v_bonus, v_bobs,
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

-- venda_editar: igual à de 004, com os bônus passando pelo catálogo.
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
  v_ids uuid[];
  v_bonus text[];
  v_bobs jsonb;
begin
  select nome into v_nome from public.usuarios where email = p_email and senha = p_senha;
  if v_nome is null then raise exception 'não autorizado'; end if;
  if not exists (select 1 from public.vendas where id = p_venda_id) then raise exception 'venda não encontrada'; end if;

  if p ? 'aluno_nome' and coalesce(trim(p->>'aluno_nome'),'') = '' then raise exception 'nome obrigatório'; end if;
  if p ? 'aluno_email' and coalesce(trim(p->>'aluno_email'),'') !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then raise exception 'e-mail inválido'; end if;
  if p ? 'aluno_telefone' and nullif(p->>'aluno_telefone','') is not null
     and length(regexp_replace(p->>'aluno_telefone','\D','','g')) not between 12 and 13 then raise exception 'telefone inválido'; end if;

  if p ? 'bonus' then
    if jsonb_typeof(p->'bonus') = 'array' and jsonb_array_length(p->'bonus') > 30 then raise exception 'bônus demais'; end if;
    select r.nomes, r.obs into v_bonus, v_bobs
    from public.bonus_resolver(p->'bonus', p->'bonus_obs', v_nome) r;
  end if;

  update public.vendas set
    vendedor            = case when p ? 'vendedor' then left(nullif(trim(p->>'vendedor'),''),120) else vendedor end,
    valor_total         = case when p ? 'valor_total' then nullif(p->>'valor_total','')::numeric else valor_total end,
    forma_pagamento     = case when p ? 'forma_pagamento' then nullif(p->>'forma_pagamento','') else forma_pagamento end,
    plataforma          = case when p ? 'plataforma' then left(nullif(trim(p->>'plataforma'),''),60) else plataforma end,
    data_venda          = case when p ? 'data_venda' then (p->>'data_venda')::date else data_venda end,
    tipo                = case when p ? 'tipo' then p->>'tipo' else tipo end,
    status              = case when p ? 'status' then p->>'status' else status end,
    aluno_nome          = case when p ? 'aluno_nome' then left(regexp_replace(trim(p->>'aluno_nome'),'\s+',' ','g'),200) else aluno_nome end,
    aluno_email         = case when p ? 'aluno_email' then lower(left(trim(p->>'aluno_email'),200)) else aluno_email end,
    aluno_telefone      = case when p ? 'aluno_telefone' then left(nullif(regexp_replace(p->>'aluno_telefone','\D','','g'),''),20) else aluno_telefone end,
    aluno_documento     = case when p ? 'aluno_documento' then left(nullif(regexp_replace(coalesce(p->>'aluno_documento',''),'\D','','g'),''),20) else aluno_documento end,
    aluno_instagram     = case when p ? 'aluno_instagram' then left(nullif(trim(p->>'aluno_instagram'),''),80) else aluno_instagram end,
    aluno_especialidade = case when p ? 'aluno_especialidade' then left(nullif(trim(p->>'aluno_especialidade'),''),120) else aluno_especialidade end,
    aluno_cidade        = case when p ? 'aluno_cidade' then left(nullif(trim(p->>'aluno_cidade'),''),120) else aluno_cidade end,
    cartao_parcelas     = case when p ? 'cartao_parcelas' then nullif(p->>'cartao_parcelas','')::int else cartao_parcelas end,
    entrada_valor       = case when p ? 'entrada_valor' then nullif(p->>'entrada_valor','')::numeric else entrada_valor end,
    entrada_forma       = case when p ? 'entrada_forma' then nullif(p->>'entrada_forma','') else entrada_forma end,
    parcelas_qtd        = case when p ? 'parcelas_qtd' then nullif(p->>'parcelas_qtd','')::int else parcelas_qtd end,
    parcela_valor       = case when p ? 'parcela_valor' then nullif(p->>'parcela_valor','')::numeric else parcela_valor end,
    primeiro_vencimento = case when p ? 'primeiro_vencimento' then nullif(p->>'primeiro_vencimento','')::date else primeiro_vencimento end,
    pagamento_detalhes  = case when p ? 'pagamento_detalhes' then left(nullif(trim(p->>'pagamento_detalhes'),''),2000) else pagamento_detalhes end,
    bonus               = case when p ? 'bonus' then v_bonus else bonus end,
    bonus_obs           = case when p ? 'bonus' then v_bobs else bonus_obs end,
    observacoes         = case when p ? 'observacoes' then left(nullif(trim(p->>'observacoes'),''),4000) else observacoes end,
    updated_at = now(),
    updated_by = v_nome
  where id = p_venda_id;

  if jsonb_typeof(p->'acessos') = 'array' then
    if jsonb_array_length(p->'acessos') = 0 then raise exception 'ao menos um produto'; end if;
    if jsonb_array_length(p->'acessos') > 10 then raise exception 'produtos demais'; end if;

    select coalesce(array_agg((x->>'id')::uuid), '{}') into v_ids
    from jsonb_array_elements(p->'acessos') x where nullif(x->>'id','') is not null;
    delete from public.venda_acessos where venda_id = p_venda_id and not (id = any(v_ids));

    for a in select * from jsonb_array_elements(p->'acessos') loop
      v_inicio := (a->>'inicio')::date;
      v_meses := nullif(a->>'duracao_meses','')::int;
      v_conf := coalesce((a->>'a_confirmar')::boolean, false);
      if v_inicio is null then raise exception 'início do acesso obrigatório'; end if;
      if v_meses is not null and v_meses not between 1 and 120 then raise exception 'duração inválida'; end if;
      if a->>'produto' = 'outro' and coalesce(trim(a->>'produto_detalhe'),'') = '' then raise exception 'descreva o produto "outro"'; end if;

      if nullif(a->>'id','') is not null then
        update public.venda_acessos set
          produto = coalesce(nullif(a->>'produto',''), produto),
          produto_detalhe = case when a ? 'produto_detalhe' then left(nullif(trim(a->>'produto_detalhe'),''),200) else produto_detalhe end,
          inicio = v_inicio,
          duracao_meses = case when v_conf then null else v_meses end,
          a_confirmar = v_conf,
          fim = case
            when v_conf then null
            when v_meses is null then v_inicio
            else (v_inicio + make_interval(months => v_meses))::date
          end
        where id = (a->>'id')::uuid and venda_id = p_venda_id;
      else
        insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, duracao_meses, a_confirmar, fim)
        values (
          p_venda_id, a->>'produto', left(nullif(trim(a->>'produto_detalhe'),''),200), v_inicio,
          case when v_conf then null else v_meses end, v_conf,
          case
            when v_conf then null
            when v_meses is null then v_inicio
            else (v_inicio + make_interval(months => v_meses))::date
          end
        );
      end if;
    end loop;
  end if;
end;
$$;

revoke all on function public.bonus_nome(text) from public;
revoke all on function public.bonus_chave(text) from public;
revoke all on function public.bonus_resolver(jsonb, jsonb, text) from public;
revoke all on function public.bonus_listar() from public;
revoke all on function public.bonus_renomear(text, text, uuid, text) from public;
revoke all on function public.bonus_unificar(text, text, uuid, uuid) from public;
revoke all on function public.bonus_excluir(text, text, uuid) from public;
revoke all on function public.registrar_venda(jsonb) from public;
revoke all on function public.venda_editar(text, text, uuid, jsonb) from public;
grant execute on function public.bonus_listar() to anon, authenticated;
grant execute on function public.bonus_renomear(text, text, uuid, text) to anon, authenticated;
grant execute on function public.bonus_unificar(text, text, uuid, uuid) to anon, authenticated;
grant execute on function public.bonus_excluir(text, text, uuid) to anon, authenticated;
grant execute on function public.registrar_venda(jsonb) to anon, authenticated;
grant execute on function public.venda_editar(text, text, uuid, jsonb) to anon, authenticated;

-- Os bônus que já estavam escritos nas vendas viram a lista inicial: um item por texto diferente
-- (ignorando acento, caixa e o prefixo "Bônus"). Nomes diferentes do mesmo bônus se juntam depois,
-- em Vendas > Bônus > Unificar.
insert into public.bonus_catalogo (nome, chave, created_by)
select distinct on (public.bonus_chave(u.b)) public.bonus_nome(u.b), public.bonus_chave(u.b), 'vendas já registradas'
from public.vendas v
cross join lateral unnest(v.bonus) as u(b)
where public.bonus_chave(u.b) <> ''
order by public.bonus_chave(u.b), v.created_at
on conflict (chave) do nothing;

-- As vendas passam a apontar para o nome do catálogo. Texto maior que 120 caracteres fica inteiro no detalhe.
update public.vendas v set
  bonus_obs = v.bonus_obs || coalesce((
    select jsonb_object_agg(c.nome, trim(u.b))
    from unnest(v.bonus) as u(b)
    join public.bonus_catalogo c on c.chave = public.bonus_chave(u.b)
    where length(trim(u.b)) > 120 and not (v.bonus_obs ? c.nome)
  ), '{}'::jsonb),
  bonus = coalesce((
    select array_agg(t.nome order by t.ord)
    from (
      select c.nome, min(u.ord) as ord
      from unnest(v.bonus) with ordinality as u(b, ord)
      join public.bonus_catalogo c on c.chave = public.bonus_chave(u.b)
      group by c.nome
    ) t
  ), '{}')
where cardinality(v.bonus) > 0;
