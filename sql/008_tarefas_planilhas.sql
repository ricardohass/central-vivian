-- Tarefas vindas das planilhas de demandas da Power (Infra, Design e Vídeo), só as da Vivian.
-- A tela lê o CSV publicado de cada planilha, monta as linhas e chama tarefas_sincronizar.
-- Cada linha da planilha vira uma tarefa, identificada por planilha_chave (data do pedido + nome + material).
-- planilha: a última versão da linha que a Central viu. Um campo só é sobrescrito quando muda NA PLANILHA,
-- então quem move o cartão ou troca o prazo na Central não perde a mudança na sincronização seguinte.
-- Linha que some da planilha (apagada, renomeada ou trocada de cliente) sai da Central.
-- Pode rodar mais de uma vez.

alter table public.tarefas add column if not exists origem text not null default 'central';
alter table public.tarefas add column if not exists planilha_chave text;
alter table public.tarefas add column if not exists planilha jsonb;
create unique index if not exists tarefas_planilha_chave on public.tarefas (area, planilha_chave);

-- p_linhas: [{chave, titulo, descricao, status, prioridade, prazo, link, pedido_em, concluida_em, solicitante}]
create or replace function public.tarefas_sincronizar(p_email text, p_senha text, p_area text, p_linhas jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l jsonb;
  s jsonb;
  t public.tarefas;
  v_hist jsonb;
  v_agora timestamptz := now();
  v_novas int := 0;
  v_alteradas int := 0;
  v_removidas int := 0;
begin
  if not exists (select 1 from public.usuarios where email = p_email and senha = p_senha) then
    raise exception 'não autorizado';
  end if;
  if p_area not in ('design','infra','edicao') then raise exception 'Área inválida.'; end if;
  if jsonb_typeof(p_linhas) <> 'array' then raise exception 'Linhas inválidas.'; end if;

  -- duas pessoas abrindo a guia ao mesmo tempo: uma sincroniza de cada vez
  perform pg_advisory_xact_lock(hashtext('tarefas_sincronizar_' || p_area));

  for l in select value from jsonb_array_elements(p_linhas) loop
    if coalesce(l->>'chave', '') = '' or coalesce(trim(l->>'titulo'), '') = '' then continue; end if;

    select * into t from public.tarefas where area = p_area and planilha_chave = l->>'chave' for update;

    if not found then
      insert into public.tarefas (titulo, descricao, area, status, prioridade, prazo, link, concluida_em,
                                  historico, created_at, created_by, updated_at, updated_by,
                                  origem, planilha_chave, planilha)
      values (left(l->>'titulo', 200), left(nullif(l->>'descricao', ''), 5000), p_area,
              l->>'status', l->>'prioridade', nullif(l->>'prazo', '')::date, left(nullif(l->>'link', ''), 1000),
              case when l->>'status' = 'concluida'
                then coalesce(nullif(l->>'concluida_em', '')::timestamptz, nullif(l->>'pedido_em', '')::timestamptz, v_agora) end,
              jsonb_build_array(jsonb_build_object('em', coalesce(nullif(l->>'pedido_em', '')::timestamptz, v_agora),
                'por', coalesce(nullif(l->>'solicitante', ''), 'Planilha'), 'tipo', 'planilha')),
              coalesce(nullif(l->>'pedido_em', '')::timestamptz, v_agora), nullif(l->>'solicitante', ''),
              v_agora, 'Planilha', 'planilha', l->>'chave', l)
      on conflict (area, planilha_chave) do nothing;
      if found then v_novas := v_novas + 1; end if;
      continue;
    end if;

    s := coalesce(t.planilha, '{}'::jsonb);
    v_hist := '[]'::jsonb;

    if (l->'status') is distinct from (s->'status') and (l->>'status') is distinct from t.status then
      v_hist := v_hist || jsonb_build_object('em', v_agora, 'por', 'Planilha', 'tipo', 'status', 'de', t.status, 'para', l->>'status');
      t.status := l->>'status';
      t.concluida_em := case when t.status = 'concluida'
        then coalesce(nullif(l->>'concluida_em', '')::timestamptz, v_agora) end;
    end if;
    if (l->'prazo') is distinct from (s->'prazo') and nullif(l->>'prazo', '')::date is distinct from t.prazo then
      v_hist := v_hist || jsonb_build_object('em', v_agora, 'por', 'Planilha', 'tipo', 'prazo', 'de', t.prazo, 'para', nullif(l->>'prazo', ''));
      t.prazo := nullif(l->>'prazo', '')::date;
    end if;
    if ((l->'titulo') is distinct from (s->'titulo') and left(l->>'titulo', 200) is distinct from t.titulo)
       or ((l->'descricao') is distinct from (s->'descricao') and nullif(l->>'descricao', '') is distinct from t.descricao)
       or ((l->'prioridade') is distinct from (s->'prioridade') and (l->>'prioridade') is distinct from t.prioridade)
       or ((l->'link') is distinct from (s->'link') and nullif(l->>'link', '') is distinct from t.link) then
      if (l->'titulo') is distinct from (s->'titulo') then t.titulo := left(l->>'titulo', 200); end if;
      if (l->'descricao') is distinct from (s->'descricao') then t.descricao := left(nullif(l->>'descricao', ''), 5000); end if;
      if (l->'prioridade') is distinct from (s->'prioridade') then t.prioridade := l->>'prioridade'; end if;
      if (l->'link') is distinct from (s->'link') then t.link := left(nullif(l->>'link', ''), 1000); end if;
      v_hist := v_hist || jsonb_build_object('em', v_agora, 'por', 'Planilha', 'tipo', 'editou');
    end if;

    if jsonb_array_length(v_hist) > 0 then
      update public.tarefas set
        titulo = t.titulo, descricao = t.descricao, status = t.status, prioridade = t.prioridade,
        prazo = t.prazo, link = t.link, concluida_em = t.concluida_em,
        historico = historico || v_hist, planilha = l, updated_at = v_agora, updated_by = 'Planilha'
      where id = t.id;
      v_alteradas := v_alteradas + 1;
    elsif s is distinct from l then
      update public.tarefas set planilha = l where id = t.id;
    end if;
  end loop;

  -- planilha vazia pode ser erro de leitura: nesse caso não apaga nada
  if jsonb_array_length(p_linhas) > 0 then
    delete from public.tarefas
    where area = p_area and origem = 'planilha'
      and planilha_chave not in (select value->>'chave' from jsonb_array_elements(p_linhas) where value->>'chave' is not null);
    get diagnostics v_removidas = row_count;
  end if;

  return jsonb_build_object('novas', v_novas, 'alteradas', v_alteradas, 'removidas', v_removidas);
end;
$$;

-- Tarefa da planilha não se exclui pela Central: voltaria na sincronização seguinte.
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
  if exists (select 1 from public.tarefas where id = p_id and origem = 'planilha') then
    raise exception 'Essa tarefa vem da planilha de demandas. Para tirar da Central, apague a linha na planilha.';
  end if;
  delete from public.tarefas where id = p_id and (v_nivel = 'adm' or created_by = v_nome);
  if not found then raise exception 'Só quem criou a tarefa ou um administrador pode excluir.'; end if;
end;
$$;

grant execute on function public.tarefas_sincronizar(text, text, text, jsonb) to anon, authenticated;

notify pgrst, 'reload schema';
