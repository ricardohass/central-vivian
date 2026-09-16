-- Acompanhamento de onboarding (aba Onboarding da Central)
-- Uma linha por venda, criada na primeira edição. Leitura e escrita só pelas funções,
-- que conferem e-mail + senha contra usuarios (mesmo login da Central).

create table if not exists public.onboarding (
  venda_id uuid primary key references public.vendas(id) on delete cascade,
  chamado text check (chamado in ('sim','nao','sem_resposta')),
  onboarding_status text check (onboarding_status in ('feito','agendado','nao')),
  call_status text check (call_status in ('feita','agendada','nao')),
  observacao text,
  updated_at timestamptz not null default now(),
  updated_by text
);

alter table public.onboarding enable row level security;
revoke all on public.onboarding from anon, authenticated;

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
            'produto', a.produto, 'produto_detalhe', a.produto_detalhe,
            'inicio', a.inicio, 'duracao_meses', a.duracao_meses, 'fim', a.fim
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
  if p_campo not in ('chamado','onboarding_status','call_status','observacao') then
    raise exception 'campo inválido';
  end if;

  insert into public.onboarding (venda_id) values (p_venda_id) on conflict (venda_id) do nothing;

  update public.onboarding set
    chamado           = case when p_campo = 'chamado' then v_valor else chamado end,
    onboarding_status = case when p_campo = 'onboarding_status' then v_valor else onboarding_status end,
    call_status       = case when p_campo = 'call_status' then v_valor else call_status end,
    observacao        = case when p_campo = 'observacao' then left(v_valor, 2000) else observacao end,
    updated_at = now(),
    updated_by = v_nome
  where venda_id = p_venda_id;
end;
$$;

revoke all on function public.onboarding_listar(text, text) from public;
revoke all on function public.onboarding_atualizar(text, text, uuid, text, text) from public;
grant execute on function public.onboarding_listar(text, text) to anon, authenticated;
grant execute on function public.onboarding_atualizar(text, text, uuid, text, text) to anon, authenticated;
