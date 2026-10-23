-- Rotina diária Berry → Central: acha vendas high ticket pagas na Berry que não estão na Central.
-- A rotina (agente agendado) busca transações e produtos/ofertas na Berry e chama rotina_berry_processar.
-- Aqui fica a regra, para ser a mesma todo dia:
--   high ticket  = produto com alguma oferta de R$ 3.000 ou mais (inclusive oferta de parcela, ex.: Master Legacy + Mentoria)
--   compra       = pagamentos high ticket da mesma pessoa (CPF, senão e-mail) no mesmo dia, somados (entrada + resto)
--   já registrada = venda na Central da mesma pessoa (e-mail, CPF ou telefone) até 7 dias antes ou depois, ou já subida pela rotina
--   histórico    = a pessoa já tem venda na Central ou pagamento high ticket na Berry mais de 7 dias antes (até 400 dias)
--   parcela      = com histórico E (valor repetido de um pagamento anterior OU total = oferta com nome de parcela OU menos de R$ 3.000)
--   nova         = sem histórico, R$ 3.000 ou mais e o total não é oferta de parcela; ou com histórico de mais de 45 dias
--                  e total igual a uma oferta cheia (renovação). Compra anterior há menos de 45 dias = dúvida (pode ser complemento)
--   dúvida       = o resto: não sobe, vira aviso para conferir
-- Venda nova sobe sem closer e sem bônus (exceto a Black de Renovação, que tem bônus padrão), com import_ref = berry:<ids>.
-- Dúvidas e reembolsos de vendas subidas pela rotina viram aviso uma vez só (rotina_berry_avisos).
-- Acesso: chave própria da rotina (só o hash fica no banco), que não serve para mais nada.

create table if not exists public.rotina_chaves (
  nome text primary key,
  hash text not null,
  created_at timestamptz not null default now()
);
alter table public.rotina_chaves enable row level security;
revoke all on public.rotina_chaves from anon, authenticated;

create table if not exists public.rotina_berry_avisos (
  chave text primary key,
  tipo text not null,
  dados jsonb,
  created_at timestamptz not null default now()
);
alter table public.rotina_berry_avisos enable row level security;
revoke all on public.rotina_berry_avisos from anon, authenticated;

create table if not exists public.rotina_berry_execucoes (
  id bigint generated always as identity primary key,
  em timestamptz not null default now(),
  desde date,
  ate date,
  aplicar boolean,
  resultado jsonb
);
alter table public.rotina_berry_execucoes enable row level security;
revoke all on public.rotina_berry_execucoes from anon, authenticated;

create or replace function public.rotina_brl(c numeric)
returns text language sql immutable as $$
  select 'R$ ' || translate(to_char(c / 100.0, 'FM999,999,990.00'), ',.', '.,')
$$;

create or replace function public.rotina_berry_processar(
  p_chave text, p_desde date, p_ate date, p_transacoes jsonb, p_produtos jsonb, p_aplicar boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  g record;
  a record;
  v_ja int := 0;
  v_novas jsonb := '[]';
  v_duvidas jsonb := '[]';
  v_parcelas jsonb := '[]';
  v_reemb jsonb := '[]';
  v_ref text;
  v_hist boolean;
  v_recorrente boolean;
  v_oferta_parcela boolean;
  v_oferta_cheia boolean;
  v_recente boolean;
  v_classe text;
  v_motivo text;
  v_item jsonb;
  v_id uuid;
  v_forma text;
  v_black boolean;
  v_res jsonb;
begin
  if not exists (
    select 1 from public.rotina_chaves
    where nome = 'berry' and hash = encode(sha256(convert_to(coalesce(p_chave, ''), 'UTF8')), 'hex')
  ) then
    raise exception 'não autorizado';
  end if;
  if p_desde is null or p_ate is null or p_desde > p_ate then raise exception 'período inválido'; end if;

  drop table if exists _rb_prod, _rb_tx, _rb_ht;

  create temp table _rb_prod on commit drop as
  select p->>'id' as id, p->>'name' as nome,
    coalesce((select max((o->>'amount')::bigint) from jsonb_array_elements(coalesce(p->'offers', '[]')) o
              where coalesce(o->>'name', '') !~* '(parcela|sinal|entrada|restante|saldo)'), 0) as preco_cheio,
    coalesce((select max((o->>'amount')::bigint) from jsonb_array_elements(coalesce(p->'offers', '[]')) o), 0) as preco_max,
    coalesce(p->'offers', '[]'::jsonb) as ofertas
  from jsonb_array_elements(p_produtos) p;

  create temp table _rb_tx on commit drop as
  select t->>'id' as id, t->>'status' as status,
    coalesce(t->>'paid_at', t->>'created_at')::timestamptz as pago_em,
    (coalesce(t->>'paid_at', t->>'created_at')::timestamptz at time zone 'America/Sao_Paulo')::date as dia,
    lower(trim(t#>>'{customer,email}')) as email,
    nullif(regexp_replace(coalesce(t#>>'{customer,document}', ''), '\D', '', 'g'), '') as doc,
    nullif(regexp_replace(coalesce(t#>>'{customer,phone}', ''), '\D', '', 'g'), '') as tel,
    trim(t#>>'{customer,name}') as nome,
    t->>'payment_method' as metodo,
    coalesce((t->>'installments')::int, 1) as parcelas,
    coalesce((t#>>'{amounts,subtotal}')::bigint, 0) as subtotal,
    coalesce((t#>>'{amounts,gross_total}')::bigint, 0) as bruto,
    coalesce(t->'items', '[]'::jsonb) as itens
  from jsonb_array_elements(p_transacoes) t;

  -- só pagamentos com algum produto high ticket
  create temp table _rb_ht on commit drop as
  select x.*, coalesce(x.doc, x.email) as comprador, right(coalesce(x.tel, ''), 8) as tel8,
    (select string_agg(distinct i->>'product_name', ' + ') from jsonb_array_elements(x.itens) i
       join _rb_prod p on p.id = i->>'product_id' where p.preco_max >= 300000) as produtos
  from _rb_tx x
  where exists (select 1 from jsonb_array_elements(x.itens) i join _rb_prod p on p.id = i->>'product_id'
                where p.preco_max >= 300000);

  for g in
    select comprador, dia,
      array_agg(id order by pago_em) as ids,
      array_agg(distinct email) filter (where email is not null) as emails,
      array_agg(distinct doc) filter (where doc is not null) as docs,
      array_agg(distinct tel8) filter (where tel8 <> '') as tels,
      array_agg(subtotal) as valores,
      sum(subtotal) as total,
      sum(bruto) as total_bruto,
      (array_agg(nome order by pago_em))[1] as nome,
      (array_agg(email order by pago_em))[1] as email,
      (array_agg(doc order by pago_em))[1] as doc,
      (array_agg(tel order by pago_em))[1] as tel,
      min(pago_em) as pago_em,
      string_agg(distinct produtos, ' + ') as produtos,
      bool_and(metodo in ('card', 'credit_card')) as tudo_cartao,
      bool_and(metodo = 'pix') as tudo_pix,
      max(parcelas) as max_parcelas,
      jsonb_agg(jsonb_build_object('id', id, 'metodo', metodo, 'parcelas', parcelas, 'subtotal', subtotal, 'bruto', bruto, 'itens', itens) order by pago_em) as txs
    from _rb_ht
    where status = 'paid' and dia between p_desde and p_ate
    group by comprador, dia
    order by dia, min(pago_em)
  loop
    v_ref := 'berry:' || array_to_string(g.ids, ',');

    -- já na Central: subida pela rotina, ou venda da mesma pessoa até 7 dias de distância
    if exists (select 1 from public.vendas v, unnest(g.ids) as i(id)
               where v.import_ref like 'berry:%' and position(i.id in v.import_ref) > 0)
       or exists (select 1 from public.vendas v
                  where abs(v.data_venda - g.dia) <= 7
                    and (lower(trim(v.aluno_email)) = any(g.emails)
                         or regexp_replace(coalesce(v.aluno_documento, ''), '\D', '', 'g') = any(g.docs)
                         or (length(regexp_replace(coalesce(v.aluno_telefone, ''), '\D', '', 'g')) >= 8
                             and right(regexp_replace(v.aluno_telefone, '\D', '', 'g'), 8) = any(g.tels)))) then
      v_ja := v_ja + 1;
      continue;
    end if;

    v_hist := exists (select 1 from public.vendas v
                      where v.data_venda < g.dia - 7 and v.data_venda >= g.dia - 400
                        and (lower(trim(v.aluno_email)) = any(g.emails)
                             or regexp_replace(coalesce(v.aluno_documento, ''), '\D', '', 'g') = any(g.docs)
                             or (length(regexp_replace(coalesce(v.aluno_telefone, ''), '\D', '', 'g')) >= 8
                                 and right(regexp_replace(v.aluno_telefone, '\D', '', 'g'), 8) = any(g.tels))))
           or exists (select 1 from _rb_ht h
                      where h.status = 'paid' and h.dia < g.dia - 7 and h.dia >= g.dia - 400
                        and (h.email = any(g.emails) or h.doc = any(g.docs)));
    v_recorrente := exists (select 1 from _rb_ht h
                            where h.status = 'paid' and h.dia < g.dia - 7 and h.dia >= g.dia - 400
                              and (h.email = any(g.emails) or h.doc = any(g.docs))
                              and h.subtotal = any(g.valores));
    v_oferta_parcela := exists (
      select 1 from jsonb_array_elements(g.txs) t, jsonb_array_elements(t->'itens') i
        join _rb_prod p on p.id = i->>'product_id', jsonb_array_elements(p.ofertas) o
      where (o->>'amount')::bigint = g.total
        and coalesce(o->>'name', '') ~* '(parcela|sinal|entrada|restante|saldo)');
    v_recente := exists (select 1 from public.vendas v
                         where v.data_venda < g.dia - 7 and v.data_venda >= g.dia - 45
                           and (lower(trim(v.aluno_email)) = any(g.emails)
                                or regexp_replace(coalesce(v.aluno_documento, ''), '\D', '', 'g') = any(g.docs)))
              or exists (select 1 from _rb_ht h
                         where h.status = 'paid' and h.dia < g.dia - 7 and h.dia >= g.dia - 45
                           and (h.email = any(g.emails) or h.doc = any(g.docs)));
    v_oferta_cheia := exists (
      select 1 from jsonb_array_elements(g.txs) t, jsonb_array_elements(t->'itens') i
        join _rb_prod p on p.id = i->>'product_id', jsonb_array_elements(p.ofertas) o
      where (o->>'amount')::bigint = g.total and (o->>'amount')::bigint >= 300000
        and coalesce(o->>'name', '') !~* '(parcela|sinal|entrada|restante|saldo)');

    if v_hist and (v_recorrente or v_oferta_parcela or g.total < 300000) then
      v_classe := 'parcela';
      v_motivo := case when v_recorrente then 'mesmo valor já pago antes por essa pessoa'
                       when v_oferta_parcela then 'valor de uma oferta de parcela/sinal'
                       else 'menos de R$ 3.000 de quem já tem compra anterior' end;
    elsif v_hist then
      if v_recente then
        v_classe := 'duvida'; v_motivo := 'pagou de novo menos de 45 dias depois de outra compra: pode ser complemento da compra anterior';
      elsif v_oferta_cheia then
        v_classe := 'nova'; v_motivo := 'já era aluna e pagou o valor cheio de uma oferta (renovação)';
      else
        v_classe := 'duvida'; v_motivo := 'já tem compra anterior e o valor não bate com nenhuma oferta: pode ser parcela ou renovação';
      end if;
    elsif g.total >= 300000 and not v_oferta_parcela then
      v_classe := 'nova'; v_motivo := 'primeira compra high ticket dessa pessoa';
    else
      v_classe := 'duvida';
      v_motivo := case when v_oferta_parcela then 'valor de uma oferta de parcela/sinal, mas não há compra anterior registrada'
                       else 'menos de R$ 3.000 e não há compra anterior registrada: pode ser entrada de uma venda que falta registrar' end;
    end if;

    v_item := jsonb_build_object('dia', g.dia, 'nome', g.nome, 'email', g.email, 'telefone', g.tel,
      'produtos', g.produtos, 'total', rotina_brl(g.total), 'total_cobrado', rotina_brl(g.total_bruto),
      'transacoes', to_jsonb(g.ids), 'motivo', v_motivo);

    if v_classe = 'parcela' then
      v_parcelas := v_parcelas || v_item;
    elsif v_classe = 'duvida' then
      if p_aplicar then
        insert into public.rotina_berry_avisos (chave, tipo, dados) values ('duvida:' || v_ref, 'duvida', v_item)
        on conflict (chave) do nothing;
        if found then v_duvidas := v_duvidas || v_item; end if;
      else
        v_duvidas := v_duvidas || v_item;
      end if;
    else
      v_black := g.produtos ~* 'black' and g.produtos ~* 'renova';
      v_forma := case when g.tudo_cartao then 'cartao' when g.tudo_pix then 'pix' end;
      if p_aplicar then
        insert into public.vendas (
          created_at, vendedor, tipo, data_venda, aluno_nome, aluno_email, aluno_telefone, aluno_documento,
          valor_total, forma_pagamento, plataforma, cartao_parcelas, pagamento_detalhes, bonus, bonus_obs,
          observacoes, import_ref
        ) values (
          g.pago_em, null, case when v_hist then 'renovacao' else 'nova' end, g.dia,
          coalesce(nullif(g.nome, ''), g.email), coalesce(g.email, ''), g.tel, g.doc,
          g.total / 100.0, v_forma, 'Berry', case when v_forma = 'cartao' then g.max_parcelas end,
          (select string_agg(
             case when t->>'metodo' in ('card', 'credit_card')
               then 'Cartão ' || (t->>'parcelas') || 'x'
               else upper(coalesce(t->>'metodo', '?')) end
             || ' · ' || rotina_brl((t->>'subtotal')::numeric)
             || case when (t->>'bruto')::bigint <> (t->>'subtotal')::bigint then ' (cobrado ' || rotina_brl((t->>'bruto')::numeric) || ')' else '' end
             || ' · transação ' || (t->>'id'), E'\n')
           from jsonb_array_elements(g.txs) t),
          case when v_black then array['Calls individuais com a Vivian','Calls individuais com a Cibele','Calls individuais com o time POWER','Ingresso Thunder 2027','2 anos de acompanhamento ao vivo + grupo','Acesso vitalício à plataforma'] else '{}' end,
          case when v_black then '{"Calls individuais com a Vivian":"2 calls","Calls individuais com a Cibele":"2 calls","Calls individuais com o time POWER":"2 calls"}'::jsonb else '{}'::jsonb end,
          'Registrada pela rotina diária da Berry em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY')
            || '. Venda sem closer no registro: conferir closer, bônus e tempo de acesso. Motivo: ' || v_motivo || '.',
          v_ref
        ) returning id into v_id;

        for a in
          select distinct i->>'product_name' as nome from jsonb_array_elements(g.txs) t, jsonb_array_elements(t->'itens') i
          join _rb_prod p on p.id = i->>'product_id' where p.preco_max >= 300000
        loop
          if a.nome ~* 'black' and a.nome ~* 'renova' then
            insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, duracao_meses, fim)
            values (v_id, 'mentoria', null, g.dia, 24, (g.dia + interval '24 months')::date),
                   (v_id, 'posgrad', null, g.dia, 6, (g.dia + interval '6 months')::date);
          elsif a.nome ~* 'mentoria' and a.nome ~* 'p[oó]s' then
            insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, a_confirmar)
            values (v_id, 'mentoria', a.nome, g.dia, true), (v_id, 'posgrad', a.nome, g.dia, true);
          elsif a.nome ~* 'master legacy' and a.nome ~* 'mentoria' then
            insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, a_confirmar)
            values (v_id, 'master', a.nome, g.dia, true), (v_id, 'mentoria', a.nome, g.dia, true);
          elsif a.nome ~* 'master legacy' then
            insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, a_confirmar)
            values (v_id, 'master', a.nome, g.dia, true);
          elsif a.nome ~* 'mentoria' and a.nome ~* '6 meses' then
            insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, duracao_meses, fim)
            values (v_id, 'mentoria', a.nome, g.dia, 6, (g.dia + interval '6 months')::date);
          elsif a.nome ~* 'mentoria' and a.nome ~* '1 ano' then
            insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, duracao_meses, fim)
            values (v_id, 'mentoria', a.nome, g.dia, 12, (g.dia + interval '12 months')::date);
          elsif a.nome ~* 'mentoria' then
            insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, a_confirmar)
            values (v_id, 'mentoria', a.nome, g.dia, true);
          elsif a.nome ~* 'p[oó]s' then
            insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, a_confirmar)
            values (v_id, 'posgrad', a.nome, g.dia, true);
          elsif a.nome ~* 'workshop' then
            insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, a_confirmar)
            values (v_id, 'workshop', a.nome, g.dia, true);
          elsif a.nome ~* 'thunder' then
            insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, a_confirmar)
            values (v_id, 'thunder', a.nome, g.dia, true);
          else
            insert into public.venda_acessos (venda_id, produto, produto_detalhe, inicio, a_confirmar)
            values (v_id, 'outro', a.nome, g.dia, true);
          end if;
        end loop;
        v_item := v_item || jsonb_build_object('venda_id', v_id, 'tipo', case when v_hist then 'renovacao' else 'nova' end);
      end if;
      v_novas := v_novas || v_item;
    end if;
  end loop;

  -- vendas subidas pela rotina que a Berry agora mostra como reembolso ou chargeback
  for g in
    select v.id as venda_id, v.aluno_nome, v.data_venda, x.id as tx, x.status
    from public.vendas v
    join _rb_tx x on v.import_ref like 'berry:%' and position(x.id in v.import_ref) > 0
    where v.status = 'ativa' and x.status in ('refunded', 'chargeback')
  loop
    v_item := jsonb_build_object('venda_id', g.venda_id, 'nome', g.aluno_nome, 'dia', g.data_venda, 'transacao', g.tx, 'status', g.status);
    if p_aplicar then
      insert into public.rotina_berry_avisos (chave, tipo, dados) values ('reembolso:' || g.tx, 'reembolso', v_item)
      on conflict (chave) do nothing;
      if found then v_reemb := v_reemb || v_item; end if;
    else
      v_reemb := v_reemb || v_item;
    end if;
  end loop;

  v_res := jsonb_build_object('desde', p_desde, 'ate', p_ate, 'aplicado', p_aplicar, 'ja_registradas', v_ja,
    'novas', v_novas, 'duvidas', v_duvidas, 'parcelas', v_parcelas, 'reembolsos', v_reemb);
  insert into public.rotina_berry_execucoes (desde, ate, aplicar, resultado) values (p_desde, p_ate, p_aplicar, v_res);
  return v_res;
end;
$$;

revoke all on function public.rotina_berry_processar(text, date, date, jsonb, jsonb, boolean) from public;
grant execute on function public.rotina_berry_processar(text, date, date, jsonb, jsonb, boolean) to anon, authenticated;

notify pgrst, 'reload schema';
