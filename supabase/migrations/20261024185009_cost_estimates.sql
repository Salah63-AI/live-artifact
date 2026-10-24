-- Price list of materials and subcontractor items
create table public.cost_items (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code <> ''),
  name text not null check (name <> ''),
  kind text not null check (kind in ('material','subcontractor')),
  uom text not null default '',
  unit_price numeric(14,2) not null default 0 check (unit_price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create table public.estimates (
  id uuid primary key default gen_random_uuid(),
  project_id uuid references public.projects(id) on delete set null,
  name text not null check (name <> ''),
  customer text not null default '',
  overhead_pct numeric(5,2) not null default 15 check (overhead_pct >= 0),
  indirect_pct numeric(5,2) not null default 35 check (indirect_pct >= 0),
  margin_pct numeric(5,2) not null default 20 check (margin_pct >= 0 and margin_pct < 100),
  status text not null default 'draft' check (status in ('draft','final')),
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index estimates_project_idx on public.estimates (project_id);

-- one row per indoor unit type in an estimate; the lines below are the cost of ONE unit
create table public.estimate_units (
  id uuid primary key default gen_random_uuid(),
  estimate_id uuid not null references public.estimates(id) on delete cascade,
  name text not null default 'Indoor unit',
  quantity numeric(12,2) not null default 1 check (quantity >= 0),
  position int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index estimate_units_estimate_idx on public.estimate_units (estimate_id, position);

-- unit_price is copied from the price list when the line is added, so price list edits never move a saved estimate
create table public.estimate_lines (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.estimate_units(id) on delete cascade,
  item_id uuid not null references public.cost_items(id) on delete restrict,
  qty_per_unit numeric(12,3) not null default 1 check (qty_per_unit >= 0),
  unit_price numeric(14,2) not null default 0 check (unit_price >= 0),
  position int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index estimate_lines_unit_idx on public.estimate_lines (unit_id, position);
create index estimate_lines_item_idx on public.estimate_lines (item_id);

create trigger cost_items_updated before update on public.cost_items for each row execute function public.set_updated_at();
create trigger estimates_updated before update on public.estimates for each row execute function public.set_updated_at();
create trigger estimate_units_updated before update on public.estimate_units for each row execute function public.set_updated_at();
create trigger estimate_lines_updated before update on public.estimate_lines for each row execute function public.set_updated_at();

create trigger cost_items_log after insert or update or delete on public.cost_items for each row execute function public.log_change();
create trigger estimates_log after insert or update or delete on public.estimates for each row execute function public.log_change();
create trigger estimate_units_log after insert or update or delete on public.estimate_units for each row execute function public.log_change();
create trigger estimate_lines_log after insert or update or delete on public.estimate_lines for each row execute function public.log_change();

alter table public.cost_items enable row level security;
alter table public.estimates enable row level security;
alter table public.estimate_units enable row level security;
alter table public.estimate_lines enable row level security;

do $$
declare t text;
begin
  foreach t in array array['cost_items','estimates','estimate_units','estimate_lines'] loop
    execute format('create policy "editors read" on public.%I for select to authenticated using ((select private.is_editor()))', t);
    execute format('create policy "editors insert" on public.%I for insert to authenticated with check ((select private.is_editor()))', t);
    execute format('create policy "editors update" on public.%I for update to authenticated using ((select private.is_editor())) with check ((select private.is_editor()))', t);
    execute format('create policy "editors delete" on public.%I for delete to authenticated using ((select private.is_editor()))', t);
  end loop;
end $$;

-- cost of one unit: direct = material + subcontractor; overhead and indirect are % of direct
create view public.estimate_unit_summary with (security_invoker = true) as
with sums as (
  select u.id as unit_id,
    coalesce(sum(l.qty_per_unit * l.unit_price) filter (where i.kind = 'material'), 0) as material,
    coalesce(sum(l.qty_per_unit * l.unit_price) filter (where i.kind = 'subcontractor'), 0) as subcontractor
  from public.estimate_units u
  left join public.estimate_lines l on l.unit_id = u.id
  left join public.cost_items i on i.id = l.item_id
  group by u.id
)
select
  u.id as unit_id, u.estimate_id, u.name, u.quantity, u.position,
  round(s.material, 2) as material,
  round(s.subcontractor, 2) as subcontractor,
  round(s.material + s.subcontractor, 2) as direct,
  round((s.material + s.subcontractor) * e.overhead_pct / 100, 2) as overhead,
  round((s.material + s.subcontractor) * e.indirect_pct / 100, 2) as indirect,
  round((s.material + s.subcontractor) * (1 + (e.overhead_pct + e.indirect_pct) / 100), 2) as unit_cost,
  round((s.material + s.subcontractor) * (1 + (e.overhead_pct + e.indirect_pct) / 100) * u.quantity, 2) as total_cost
from public.estimate_units u
join sums s on s.unit_id = u.id
join public.estimates e on e.id = u.estimate_id;

-- whole estimate: project cost = sum of quantity x unit cost; sales price = cost / (1 - margin)
create view public.estimate_summary with (security_invoker = true) as
with t as (
  select e.id,
    coalesce(sum(us.quantity), 0) as units,
    coalesce(sum(us.material * us.quantity), 0) as material,
    coalesce(sum(us.subcontractor * us.quantity), 0) as subcontractor,
    coalesce(sum(us.direct * us.quantity), 0) as direct,
    coalesce(sum(us.overhead * us.quantity), 0) as overhead,
    coalesce(sum(us.indirect * us.quantity), 0) as indirect,
    coalesce(sum(us.total_cost), 0) as project_cost
  from public.estimates e
  left join public.estimate_unit_summary us on us.estimate_id = e.id
  group by e.id
)
select
  e.*,
  p.name as project_name,
  t.units, t.material, t.subcontractor, t.direct, t.overhead, t.indirect, t.project_cost,
  round(t.project_cost / (1 - e.margin_pct / 100), 2) as sales_price,
  round(t.project_cost / (1 - e.margin_pct / 100) - t.project_cost, 2) as margin_amount
from public.estimates e
join t on t.id = e.id
left join public.projects p on p.id = e.project_id;

revoke all on public.cost_items, public.estimates, public.estimate_units, public.estimate_lines,
  public.estimate_unit_summary, public.estimate_summary from anon;
