-- Onboarding: sai a coluna "Call realizada?" da tela (o onboarding já é a call) e entra
-- o envio do formulário das novas alunas da pós. A coluna call_status fica no banco, só não aparece mais.

alter table public.onboarding add column if not exists form_pos text;
alter table public.onboarding drop constraint if exists onboarding_form_pos_check;
alter table public.onboarding add constraint onboarding_form_pos_check
  check (form_pos in ('enviado','nao_enviado','nao_se_aplica'));

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
        'form_pos', o.form_pos,
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

create or replace function public.onboarding_atualizar(
  p_email text, p_senha text, p_venda_id uuid, p_campo text, p_valor text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome text;
  v_valor text := nullif(trim(p_valor), '');
begin
  select nome into v_nome from public.usuarios where email = p_email and senha = p_senha;
  if v_nome is null then raise exception 'não autorizado'; end if;
  if p_campo not in ('chamado','onboarding_status','form_pos','observacao') then
    raise exception 'campo inválido';
  end if;

  insert into public.onboarding (venda_id) values (p_venda_id) on conflict (venda_id) do nothing;

  update public.onboarding set
    chamado           = case when p_campo = 'chamado' then v_valor else chamado end,
    onboarding_status = case when p_campo = 'onboarding_status' then v_valor else onboarding_status end,
    form_pos          = case when p_campo = 'form_pos' then v_valor else form_pos end,
    observacao        = case when p_campo = 'observacao' then left(v_valor, 2000) else observacao end,
    updated_at = now(),
    updated_by = v_nome
  where venda_id = p_venda_id;
end;
$$;
