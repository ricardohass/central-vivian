-- Tarefas (guia Tarefas da Central): o "trello" do time para demandas de Design, Infra e Edição.
-- Status guardado: pendente, andamento, concluida, adiada. "Atrasada" não é status: é a tarefa
-- pendente ou em andamento com prazo antes de hoje (calculado na tela).
-- Leitura e escrita só pelas funções, que conferem e-mail + senha contra usuarios (mesmo login da Central).
-- historico: lista de {em, por, tipo, de, para} com quem criou, mudou status, responsável ou prazo.
-- Pode rodar mais de uma vez.

create table if not exists public.tarefas (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  descricao text,
  area text not null check (area in ('design','infra','edicao')),
  status text not null default 'pendente' check (status in ('pendente','andamento','concluida','adiada')),
  prioridade text not null default 'normal' check (prioridade in ('baixa','normal','alta','urgente')),
  responsavel text,
  prazo date,
  link text,
  concluida_em timestamptz,
  historico jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  created_by text,
  updated_at timestamptz not null default now(),
  updated_by text
);
alter table public.tarefas enable row level security;
revoke all on public.tarefas from anon, authenticated;

create or replace function public.tarefas_listar(p_email text, p_senha text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.usuarios where email = p_email and senha = p_senha) then
    raise exception 'não autorizado';
  end if;

  return jsonb_build_object(
    'tarefas', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at desc) from public.tarefas t), '[]'::jsonb),
    'pessoas', coalesce((
      select jsonb_agg(trim(u.nome) order by u.created_at)
      from public.usuarios u where coalesce(trim(u.nome), '') <> ''
    ), '[]'::jsonb)
  );
end;
$$;

-- Cria (p_id nulo) ou altera uma tarefa. Só os campos presentes em p_dados mudam,
-- então arrastar no quadro manda só {"status": ...}. Devolve a tarefa como ficou.
create or replace function public.tarefa_salvar(p_email text, p_senha text, p_id uuid, p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome text;
  v_agora timestamptz := now();
  v_hist jsonb := '[]'::jsonb;
  t public.tarefas;
  n public.tarefas;
begin
  select nome into v_nome from public.usuarios where email = p_email and senha = p_senha;
  if v_nome is null then raise exception 'não autorizado'; end if;

  if p_id is not null then
    select * into t from public.tarefas where id = p_id for update;
    if not found then raise exception 'Essa tarefa não existe mais (alguém excluiu).'; end if;
    n := t;
  else
    n.status := 'pendente';
    n.prioridade := 'normal';
  end if;

  if p_dados ? 'titulo' then n.titulo := left(trim(regexp_replace(coalesce(p_dados->>'titulo', ''), '\s+', ' ', 'g')), 200); end if;
  if p_dados ? 'descricao' then n.descricao := left(nullif(trim(p_dados->>'descricao'), ''), 5000); end if;
  if p_dados ? 'area' then n.area := p_dados->>'area'; end if;
  if p_dados ? 'status' then n.status := p_dados->>'status'; end if;
  if p_dados ? 'prioridade' then n.prioridade := p_dados->>'prioridade'; end if;
  if p_dados ? 'responsavel' then n.responsavel := left(nullif(trim(p_dados->>'responsavel'), ''), 120); end if;
  if p_dados ? 'prazo' then n.prazo := nullif(p_dados->>'prazo', '')::date; end if;
  if p_dados ? 'link' then n.link := left(nullif(trim(p_dados->>'link'), ''), 1000); end if;

  if coalesce(n.titulo, '') = '' then raise exception 'Dê um título à tarefa.'; end if;
  if n.area is null or n.area not in ('design','infra','edicao') then raise exception 'Escolha a área da tarefa.'; end if;
  if n.status not in ('pendente','andamento','concluida','adiada') then raise exception 'Status inválido.'; end if;
  if n.prioridade not in ('baixa','normal','alta','urgente') then raise exception 'Prioridade inválida.'; end if;

  if p_id is null then
    insert into public.tarefas (titulo, descricao, area, status, prioridade, responsavel, prazo, link,
                                concluida_em, historico, created_by, updated_by)
    values (n.titulo, n.descricao, n.area, n.status, n.prioridade, n.responsavel, n.prazo, n.link,
            case when n.status = 'concluida' then v_agora end,
            jsonb_build_array(jsonb_build_object('em', v_agora, 'por', v_nome, 'tipo', 'criou')),
            v_nome, v_nome)
    returning * into n;
    return to_jsonb(n);
  end if;

  if n.status is distinct from t.status then
    v_hist := v_hist || jsonb_build_object('em', v_agora, 'por', v_nome, 'tipo', 'status', 'de', t.status, 'para', n.status);
    n.concluida_em := case when n.status = 'concluida' then v_agora end;
  end if;
  if n.responsavel is distinct from t.responsavel then
    v_hist := v_hist || jsonb_build_object('em', v_agora, 'por', v_nome, 'tipo', 'responsavel', 'de', t.responsavel, 'para', n.responsavel);
  end if;
  if n.prazo is distinct from t.prazo then
    v_hist := v_hist || jsonb_build_object('em', v_agora, 'por', v_nome, 'tipo', 'prazo', 'de', t.prazo, 'para', n.prazo);
  end if;
  if (n.titulo, n.descricao, n.area, n.prioridade, n.link) is distinct from (t.titulo, t.descricao, t.area, t.prioridade, t.link) then
    v_hist := v_hist || jsonb_build_object('em', v_agora, 'por', v_nome, 'tipo', 'editou');
  end if;
  if jsonb_array_length(v_hist) = 0 then return to_jsonb(t); end if;

  update public.tarefas set
    titulo = n.titulo, descricao = n.descricao, area = n.area, status = n.status, prioridade = n.prioridade,
    responsavel = n.responsavel, prazo = n.prazo, link = n.link, concluida_em = n.concluida_em,
    historico = historico || v_hist,
    updated_at = v_agora, updated_by = v_nome
  where id = p_id
  returning * into n;
  return to_jsonb(n);
end;
$$;

-- Excluir: quem criou a tarefa ou administrador.
create or replace function public.tarefa_excluir(p_email text, p_senha text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome text;
  v_nivel text;
begin
  select nome, nivel into v_nome, v_nivel from public.usuarios where email = p_email and senha = p_senha;
  if v_nome is null then raise exception 'não autorizado'; end if;
  delete from public.tarefas where id = p_id and (v_nivel = 'adm' or created_by = v_nome);
  if not found then raise exception 'Só quem criou a tarefa ou um administrador pode excluir.'; end if;
end;
$$;

grant execute on function public.tarefas_listar(text, text) to anon, authenticated;
grant execute on function public.tarefa_salvar(text, text, uuid, jsonb) to anon, authenticated;
grant execute on function public.tarefa_excluir(text, text, uuid) to anon, authenticated;
