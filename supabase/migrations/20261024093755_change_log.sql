create table public.change_log (
  id bigserial primary key,
  table_name text not null,
  row_id text not null,
  action text not null check (action in ('insert','update','delete')),
  old_row jsonb,
  new_row jsonb,
  changed_by uuid,
  changed_by_email text,
  changed_at timestamptz not null default now()
);
create index change_log_row_idx on public.change_log (table_name, row_id, changed_at desc);
alter table public.change_log enable row level security;

create or replace function public.log_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.change_log (table_name, row_id, action, old_row, new_row, changed_by, changed_by_email)
  values (
    tg_table_name,
    case when tg_op = 'DELETE' then old.id::text else new.id::text end,
    lower(tg_op),
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end,
    auth.uid(),
    auth.jwt() ->> 'email'
  );
  return null;
end $$;
revoke execute on function public.log_change() from public, anon, authenticated;

create trigger phases_log after insert or update or delete on public.phases for each row execute function public.log_change();
create trigger steps_log after insert or update or delete on public.steps for each row execute function public.log_change();
create trigger projects_log after insert or update or delete on public.projects for each row execute function public.log_change();
create trigger progress_log after insert or update or delete on public.progress_entries for each row execute function public.log_change();

-- invoice: previously recognized = highest earlier final %, so a month left blank doesn't double-bill
create or replace view public.progress_summary with (security_invoker = true) as
select
  e.*,
  p.name as project_name,
  p.contract_value,
  p.cost_budget,
  round((e.posted_material_cost + e.posted_sub_cost) / nullif(p.cost_budget, 0) * 100, 2) as cost_pct,
  round(e.engineer_pct - (e.posted_material_cost + e.posted_sub_cost) / nullif(p.cost_budget, 0) * 100, 2) as gap_pts,
  abs(e.engineer_pct - (e.posted_material_cost + e.posted_sub_cost) / nullif(p.cost_budget, 0) * 100) > 10 as needs_review,
  case when e.final_pct is null then null else
    round((e.final_pct - coalesce(max(e.final_pct) over (partition by e.project_id order by e.period
      rows between unbounded preceding and 1 preceding), 0)) / 100 * p.contract_value, 2) end as invoice_amount
from public.progress_entries e
join public.projects p on p.id = e.project_id;
