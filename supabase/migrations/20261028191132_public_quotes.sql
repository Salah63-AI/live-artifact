-- Rates used for public quotes; one row, owner-only
create table public.quote_settings (
  id boolean primary key default true check (id),
  overhead_pct numeric(5,2) not null default 15 check (overhead_pct >= 0),
  indirect_pct numeric(5,2) not null default 25 check (indirect_pct >= 0),
  margin_pct numeric(5,2) not null default 20 check (margin_pct >= 0 and margin_pct < 100),
  marketing_amount numeric(14,2) not null default 0 check (marketing_amount >= 0),
  vat_pct numeric(5,2) not null default 14 check (vat_pct >= 0),
  max_discount_pct numeric(5,2) not null default 5 check (max_discount_pct >= 0 and max_discount_pct < 100),
  public_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into public.quote_settings default values;

-- Requests sent from the public page; visitors can only create them through submit_quote_request()
create table public.quote_requests (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  project_name text not null check (project_name <> '' and length(project_name) <= 200),
  customer text not null default '' check (length(customer) <= 200),
  contact_phone text not null default '' check (length(contact_phone) <= 50),
  contact_email text not null default '' check (length(contact_email) <= 200),
  sales_person text not null default '' check (length(sales_person) <= 200),
  location text not null default '' check (length(location) <= 300),
  zone text not null references public.location_zones(code) on update cascade,
  discount_pct numeric(5,2) not null default 0,
  payload jsonb not null,
  quoted jsonb not null,
  status text not null default 'new' check (status in ('new','converted','closed')),
  estimate_id uuid references public.estimates(id) on delete set null,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index quote_requests_created_idx on public.quote_requests (created_at desc);
create index quote_requests_estimate_idx on public.quote_requests (estimate_id);

create trigger quote_settings_updated before update on public.quote_settings for each row execute function public.set_updated_at();
create trigger quote_requests_updated before update on public.quote_requests for each row execute function public.set_updated_at();
create trigger quote_settings_log after insert or update or delete on public.quote_settings for each row execute function public.log_change();
create trigger quote_requests_log after insert or update or delete on public.quote_requests for each row execute function public.log_change();

alter table public.quote_settings enable row level security;
alter table public.quote_requests enable row level security;
create policy "editors read" on public.quote_settings for select to authenticated using ((select private.is_editor()));
create policy "editors update" on public.quote_settings for update to authenticated using ((select private.is_editor())) with check ((select private.is_editor()));
create policy "editors read" on public.quote_requests for select to authenticated using ((select private.is_editor()));
create policy "editors update" on public.quote_requests for update to authenticated using ((select private.is_editor())) with check ((select private.is_editor()));
create policy "editors delete" on public.quote_requests for delete to authenticated using ((select private.is_editor()));
revoke all on public.quote_settings, public.quote_requests from anon;

-- Public: active items without their prices
create function public.public_price_list()
returns table (id uuid, code text, name text, cost_group text, uom text)
language sql stable security definer set search_path = '' as $$
  select i.id, i.code, i.name, coalesce(i.material_group, i.kind), i.uom
  from public.cost_items i
  join public.quote_settings s on s.public_enabled
  where i.active
  order by case coalesce(i.material_group, i.kind) when 'installation' then 1 when 'accessories' then 2 when 'fittings' then 3 else 4 end, i.code;
$$;

-- Public: zones without their factor
create function public.public_zones()
returns table (code text, name text, description text)
language sql stable security definer set search_path = '' as $$
  select z.code, z.name, z.description from public.location_zones z order by z.position;
$$;

-- Public: price a project. Same math as estimate_summary, rates from quote_settings; returns prices only.
-- (Its discount error message is corrected in the next migration.)
create function public.public_quote(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s public.quote_settings;
  z public.location_zones;
  disc numeric := coalesce((p ->> 'discount_pct')::numeric, 0);
  units_count numeric := 0;
  base numeric := 0;
  u jsonb; l jsonb; unit_cost numeric; q numeric; lq numeric; price numeric;
  direct numeric; total numeric; sales numeric; discount numeric; net numeric; vat numeric;
begin
  select * into s from public.quote_settings;
  if not s.public_enabled then raise exception 'Public quotes are switched off.' using errcode = 'P0001'; end if;
  select * into z from public.location_zones where code = p ->> 'zone';
  if z.code is null then raise exception 'Choose a location zone.' using errcode = 'P0001'; end if;
  if disc < 0 or disc > s.max_discount_pct then
    raise exception 'Discount must be between 0%% and %%%.', s.max_discount_pct using errcode = 'P0001';
  end if;
  if jsonb_typeof(p -> 'units') <> 'array' or jsonb_array_length(p -> 'units') > 50 then
    raise exception 'Add between 1 and 50 indoor unit types.' using errcode = 'P0001';
  end if;
  for u in select * from jsonb_array_elements(p -> 'units') loop
    q := coalesce((u ->> 'quantity')::numeric, 0);
    if q < 0 or q > 100000 then raise exception 'Number of units must be between 0 and 100,000.' using errcode = 'P0001'; end if;
    if jsonb_typeof(u -> 'lines') <> 'array' or jsonb_array_length(u -> 'lines') > 200 then
      raise exception 'Each unit type can have up to 200 lines.' using errcode = 'P0001';
    end if;
    unit_cost := 0;
    for l in select * from jsonb_array_elements(u -> 'lines') loop
      lq := coalesce((l ->> 'qty')::numeric, 0);
      if lq < 0 or lq > 1000000 then raise exception 'Quantities must be between 0 and 1,000,000.' using errcode = 'P0001'; end if;
      select i.unit_price into price from public.cost_items i where i.id = (l ->> 'item_id')::uuid and i.active;
      if price is null then raise exception 'An item is no longer in the price list. Remove it and choose again.' using errcode = 'P0001'; end if;
      unit_cost := unit_cost + lq * price;
    end loop;
    units_count := units_count + q;
    base := base + round(unit_cost, 2) * q;
  end loop;
  direct := base * z.factor_pct / 100;
  total := direct * (1 + (s.overhead_pct + s.indirect_pct) / 100) + s.marketing_amount;
  sales := total / (1 - s.margin_pct / 100);
  discount := sales * disc / 100;
  net := sales - discount;
  vat := net * s.vat_pct / 100;
  return jsonb_build_object(
    'units', units_count, 'zone', z.code, 'zone_name', z.name,
    'sales_price', round(sales, 2), 'discount_pct', disc, 'discount_amount', round(discount, 2),
    'net_sales', round(net, 2), 'vat_pct', s.vat_pct, 'vat_amount', round(vat, 2), 'sales_with_vat', round(net + vat, 2),
    'max_discount_pct', s.max_discount_pct);
end $$;

-- Public: send a quote request. Prices are recalculated here, never trusted from the browser.
create function public.submit_quote_request(p jsonb)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare quoted jsonb; ref text;
begin
  if coalesce(trim(p ->> 'project_name'), '') = '' then raise exception 'Enter the project name.' using errcode = 'P0001'; end if;
  if coalesce(trim(p ->> 'contact_phone'), '') = '' and coalesce(trim(p ->> 'contact_email'), '') = '' then
    raise exception 'Enter a phone number or email so Tradex can reply.' using errcode = 'P0001';
  end if;
  quoted := public.public_quote(p);
  if (quoted ->> 'units')::numeric <= 0 then raise exception 'Add at least one indoor unit.' using errcode = 'P0001'; end if;
  insert into public.quote_requests (project_name, customer, contact_phone, contact_email, sales_person, location, zone, discount_pct, payload, quoted)
  values (left(trim(p ->> 'project_name'), 200), left(trim(coalesce(p ->> 'customer', '')), 200),
    left(trim(coalesce(p ->> 'contact_phone', '')), 50), left(trim(coalesce(p ->> 'contact_email', '')), 200),
    left(trim(coalesce(p ->> 'sales_person', '')), 200), left(trim(coalesce(p ->> 'location', '')), 300),
    p ->> 'zone', coalesce((p ->> 'discount_pct')::numeric, 0),
    jsonb_build_object('units', p -> 'units'), quoted)
  returning reference into ref;
  return ref;
end $$;

revoke execute on function public.public_price_list(), public.public_zones(), public.public_quote(jsonb), public.submit_quote_request(jsonb) from public;
grant execute on function public.public_price_list(), public.public_zones(), public.public_quote(jsonb), public.submit_quote_request(jsonb) to anon, authenticated;
