create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;

create table public.phases (
  id smallint primary key,
  name text not null,
  position int not null,
  is_loop boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create table public.steps (
  id uuid primary key default gen_random_uuid(),
  phase_id smallint not null references public.phases(id) on delete restrict,
  position int not null,
  title text not null,
  short_label text not null default '',
  what text not null default '',
  owner text not null default '',
  odoo text not null default '',
  control text not null default '',
  output text not null default '',
  money text not null check (money in ('Baseline','Commitment','Cash in','Cost','Control')),
  cadence text not null default '',
  basis text not null default 'Assumed' check (basis in ('Confirmed','Partly assumed','Assumed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index steps_phase_position_idx on public.steps (phase_id, position);

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  customer text not null default '',
  contract_value numeric(14,2) not null default 0 check (contract_value >= 0),
  cost_budget numeric(14,2) not null default 0 check (cost_budget >= 0),
  status text not null default 'active' check (status in ('active','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create table public.progress_entries (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  period date not null check (extract(day from period) = 1),
  engineer_pct numeric(5,2) check (engineer_pct between 0 and 100),
  posted_material_cost numeric(14,2) not null default 0,
  posted_sub_cost numeric(14,2) not null default 0,
  final_pct numeric(5,2) check (final_pct between 0 and 100),
  invoice_ref text not null default '',
  sub_bill_ref text not null default '',
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  unique (project_id, period)
);

create trigger phases_updated before update on public.phases for each row execute function public.set_updated_at();
create trigger steps_updated before update on public.steps for each row execute function public.set_updated_at();
create trigger projects_updated before update on public.projects for each row execute function public.set_updated_at();
create trigger progress_updated before update on public.progress_entries for each row execute function public.set_updated_at();

alter table public.phases enable row level security;
alter table public.steps enable row level security;
alter table public.projects enable row level security;
alter table public.progress_entries enable row level security;

create view public.progress_summary with (security_invoker = true) as
select
  e.*,
  p.name as project_name,
  p.contract_value,
  p.cost_budget,
  round((e.posted_material_cost + e.posted_sub_cost) / nullif(p.cost_budget, 0) * 100, 2) as cost_pct,
  round(e.engineer_pct - (e.posted_material_cost + e.posted_sub_cost) / nullif(p.cost_budget, 0) * 100, 2) as gap_pts,
  abs(e.engineer_pct - (e.posted_material_cost + e.posted_sub_cost) / nullif(p.cost_budget, 0) * 100) > 10 as needs_review,
  round(coalesce(e.final_pct, 0) / 100 * p.contract_value
    - coalesce(lag(e.final_pct) over (partition by e.project_id order by e.period), 0) / 100 * p.contract_value, 2) as invoice_amount
from public.progress_entries e
join public.projects p on p.id = e.project_id;
