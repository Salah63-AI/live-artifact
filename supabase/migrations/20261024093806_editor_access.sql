create schema if not exists private;
grant usage on schema private to authenticated;

create table public.editors (
  email text primary key check (email = lower(email)),
  added_at timestamptz not null default now()
);
alter table public.editors enable row level security;

create or replace function private.is_editor()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.editors where email = lower(auth.jwt() ->> 'email'));
$$;
revoke execute on function private.is_editor() from public, anon;
grant execute on function private.is_editor() to authenticated;

-- let a signed-in user check only their own editor status
create policy "own editor row" on public.editors for select to authenticated
  using (email = lower((select auth.jwt()) ->> 'email'));

do $$
declare t text;
begin
  foreach t in array array['phases','steps','projects','progress_entries'] loop
    execute format('create policy "editors read" on public.%I for select to authenticated using ((select private.is_editor()))', t);
    execute format('create policy "editors insert" on public.%I for insert to authenticated with check ((select private.is_editor()))', t);
    execute format('create policy "editors update" on public.%I for update to authenticated using ((select private.is_editor())) with check ((select private.is_editor()))', t);
    execute format('create policy "editors delete" on public.%I for delete to authenticated using ((select private.is_editor()))', t);
  end loop;
end $$;

create policy "editors read" on public.change_log for select to authenticated using ((select private.is_editor()));

revoke all on public.phases, public.steps, public.projects, public.progress_entries, public.change_log, public.editors, public.progress_summary from anon;

-- The live database also seeds the first editor here. The email is left out of this public copy;
-- add editors with: insert into public.editors (email) values ('name@example.com');
