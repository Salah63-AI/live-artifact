create or replace function public.public_quote(p jsonb)
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
    raise exception using errcode = 'P0001',
      message = format('Discount must be between 0%% and %s%%.', trim_scale(s.max_discount_pct));
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
revoke execute on function public.public_quote(jsonb) from public;
grant execute on function public.public_quote(jsonb) to anon, authenticated;
