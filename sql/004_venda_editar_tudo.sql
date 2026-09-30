-- Edição completa da venda: todo campo do formulário /nova-venda passa a ser editável depois do cadastro.
-- Só mexe nas chaves presentes em p. Quando p traz "acessos", a lista enviada vira a lista da venda:
-- item com id é atualizado, item sem id é criado e acesso que não veio é apagado.
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
begin
  select nome into v_nome from public.usuarios where email = p_email and senha = p_senha;
  if v_nome is null then raise exception 'não autorizado'; end if;
  if not exists (select 1 from public.vendas where id = p_venda_id) then raise exception 'venda não encontrada'; end if;

  if p ? 'aluno_nome' and coalesce(trim(p->>'aluno_nome'),'') = '' then raise exception 'nome obrigatório'; end if;
  if p ? 'aluno_email' and coalesce(trim(p->>'aluno_email'),'') !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then raise exception 'e-mail inválido'; end if;
  if p ? 'aluno_telefone' and nullif(p->>'aluno_telefone','') is not null
     and length(regexp_replace(p->>'aluno_telefone','\D','','g')) not between 12 and 13 then raise exception 'telefone inválido'; end if;

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
    bonus               = case when p ? 'bonus' then coalesce((select array_agg(left(trim(b),300)) from jsonb_array_elements_text(p->'bonus') b where trim(b) <> ''), '{}') else bonus end,
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

revoke all on function public.venda_editar(text, text, uuid, jsonb) from public;
grant execute on function public.venda_editar(text, text, uuid, jsonb) to anon, authenticated;
