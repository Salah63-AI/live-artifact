-- Location zones: the zone % multiplies the whole direct cost (material + subcontractor)
create table public.location_zones (
  code text primary key check (code ~ '^[a-z]+$'),
  name text not null,
  description text not null default '',
  factor_pct numeric(6,2) not null check (factor_pct > 0),
  position int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into public.location_zones (code, name, description, factor_pct, position) values
  ('central', 'Central', 'Cairo, Giza, Qalyubia', 100, 1),
  ('medium', 'Medium', 'Up to 200 km from Cairo', 125, 2),
  ('far', 'Far', 'More than 200 km from Cairo', 150, 3);

create trigger location_zones_updated before update on public.location_zones for each row execute function public.set_updated_at();
create trigger location_zones_log after insert or update or delete on public.location_zones for each row execute function public.log_change();
alter table public.location_zones enable row level security;
create policy "editors read" on public.location_zones for select to authenticated using ((select private.is_editor()));
create policy "editors update" on public.location_zones for update to authenticated using ((select private.is_editor())) with check ((select private.is_editor()));

-- log_change() keys rows by id; zones are keyed by code
create or replace function public.log_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  insert into public.change_log (table_name, row_id, action, old_row, new_row, changed_by, changed_by_email)
  values (
    tg_table_name,
    coalesce(r ->> 'id', r ->> 'code'),
    lower(tg_op),
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end,
    auth.uid(),
    auth.jwt() ->> 'email'
  );
  return null;
end $$;
revoke execute on function public.log_change() from public, anon, authenticated;

-- Material groups on the price list
alter table public.cost_items add column material_group text;
alter table public.cost_items add constraint cost_items_material_group_check check (
  (kind = 'material' and material_group in ('installation','accessories','fittings'))
  or (kind = 'subcontractor' and material_group is null));

-- Estimate header and pricing inputs
drop view public.estimate_summary;
drop view public.estimate_unit_summary;

alter table public.estimates
  add column sales_person text not null default '',
  add column location text not null default '',
  add column zone text not null default 'central' references public.location_zones(code) on update cascade,
  add column marketing_amount numeric(14,2) not null default 0 check (marketing_amount >= 0),
  add column discount_pct numeric(5,2) not null default 0 check (discount_pct >= 0 and discount_pct < 100),
  add column vat_pct numeric(5,2) not null default 14 check (vat_pct >= 0),
  alter column indirect_pct set default 25;
create index estimates_zone_idx on public.estimates (zone);

-- cost of ONE unit at base (central) prices, by group
create view public.estimate_unit_summary with (security_invoker = true) as
with sums as (
  select u.id as unit_id,
    coalesce(sum(l.qty_per_unit * l.unit_price) filter (where i.material_group = 'installation'), 0) as mat_installation,
    coalesce(sum(l.qty_per_unit * l.unit_price) filter (where i.material_group = 'accessories'), 0) as mat_accessories,
    coalesce(sum(l.qty_per_unit * l.unit_price) filter (where i.material_group = 'fittings'), 0) as mat_fittings,
    coalesce(sum(l.qty_per_unit * l.unit_price) filter (where i.kind = 'material'), 0) as material,
    coalesce(sum(l.qty_per_unit * l.unit_price) filter (where i.kind = 'subcontractor'), 0) as subcontractor
  from public.estimate_units u
  left join public.estimate_lines l on l.unit_id = u.id
  left join public.cost_items i on i.id = l.item_id
  group by u.id
)
select
  u.id as unit_id, u.estimate_id, u.name, u.quantity, u.position,
  round(s.mat_installation, 2) as mat_installation,
  round(s.mat_accessories, 2) as mat_accessories,
  round(s.mat_fittings, 2) as mat_fittings,
  round(s.material, 2) as material,
  round(s.subcontractor, 2) as subcontractor,
  round(s.material + s.subcontractor, 2) as direct_base,
  round((s.material + s.subcontractor) * u.quantity, 2) as direct_base_total
from public.estimate_units u
join sums s on s.unit_id = u.id;

-- whole estimate: zone, overhead, indirect, marketing, price, discount, VAT, margin
create view public.estimate_summary with (security_invoker = true) as
with t as (
  select e.id,
    coalesce(sum(us.quantity), 0) as units,
    coalesce(sum(us.mat_installation * us.quantity), 0) as mat_installation,
    coalesce(sum(us.mat_accessories * us.quantity), 0) as mat_accessories,
    coalesce(sum(us.mat_fittings * us.quantity), 0) as mat_fittings,
    coalesce(sum(us.material * us.quantity), 0) as material,
    coalesce(sum(us.subcontractor * us.quantity), 0) as subcontractor
  from public.estimates e
  left join public.estimate_unit_summary us on us.estimate_id = e.id
  group by e.id
), c as (
  select t.*, z.name as zone_name, z.factor_pct as zone_factor_pct,
    t.material + t.subcontractor as direct_base,
    (t.material + t.subcontractor) * z.factor_pct / 100 as direct
  from t
  join public.estimates e on e.id = t.id
  join public.location_zones z on z.code = e.zone
), k as (
  select c.*,
    c.direct * e.overhead_pct / 100 as overhead,
    c.direct * e.indirect_pct / 100 as indirect,
    e.marketing_amount as marketing,
    c.direct * (1 + (e.overhead_pct + e.indirect_pct) / 100) + e.marketing_amount as total_cost
  from c join public.estimates e on e.id = c.id
), p as (
  select k.*,
    k.total_cost / (1 - e.margin_pct / 100) as sales_price,
    k.total_cost / (1 - e.margin_pct / 100) * e.discount_pct / 100 as discount_amount,
    k.total_cost / (1 - e.margin_pct / 100) * (1 - e.discount_pct / 100) as net_sales
  from k join public.estimates e on e.id = k.id
)
select
  e.*,
  pr.name as project_name,
  p.units,
  round(p.mat_installation, 2) as mat_installation,
  round(p.mat_accessories, 2) as mat_accessories,
  round(p.mat_fittings, 2) as mat_fittings,
  round(p.material, 2) as material,
  round(p.subcontractor, 2) as subcontractor,
  round(p.direct_base, 2) as direct_base,
  p.zone_name,
  p.zone_factor_pct,
  round(p.direct - p.direct_base, 2) as zone_uplift,
  round(p.direct, 2) as direct,
  round(p.overhead, 2) as overhead,
  round(p.indirect, 2) as indirect,
  round(p.marketing, 2) as marketing,
  round(p.total_cost, 2) as total_cost,
  round(p.sales_price, 2) as sales_price,
  round(p.discount_amount, 2) as discount_amount,
  round(p.net_sales, 2) as net_sales,
  round(p.net_sales * e.vat_pct / 100, 2) as vat_amount,
  round(p.net_sales * (1 + e.vat_pct / 100), 2) as sales_with_vat,
  round(p.net_sales - p.total_cost, 2) as margin_amount,
  case when p.net_sales > 0 then round((p.net_sales - p.total_cost) / p.net_sales * 100, 2) end as margin_pct_actual
from public.estimates e
join p on p.id = e.id
left join public.projects pr on pr.id = e.project_id;

revoke all on public.location_zones, public.estimate_unit_summary, public.estimate_summary from anon;
