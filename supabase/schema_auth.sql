-- ============================================================
-- Auth + ролі (для тих, хто вже виконував schema.sql)
-- 1) Спочатку: Authentication -> Sign In / Providers -> Email ON
-- 2) Виконати цей файл в SQL Editor
-- ============================================================

-- Видаляємо старі публічні read-політики (читання тепер тільки для залогінених)
drop policy if exists "public read evaluators" on public.evaluators;
drop policy if exists "public read tracks"    on public.tracks;
drop policy if exists "public read sessions"  on public.sessions;
drop policy if exists "public read ratings"   on public.ratings;

-- ---------- profiles ----------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  role         text not null default 'user' check (role in ('admin','user')),
  display_name text,
  created_at   timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "read own profile" on public.profiles
  for select to authenticated
  using (id = auth.uid());

-- ---------- is_admin() ----------
create or replace function public.is_admin()
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- ---------- тригер: новий юзер -> profile з роллю user ----------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, role)
  values (new.id, 'user')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- read для залогінених ----------
create policy "auth read evaluators" on public.evaluators for select to authenticated using (true);
create policy "auth read tracks"    on public.tracks    for select to authenticated using (true);
create policy "auth read sessions"  on public.sessions  for select to authenticated using (true);
create policy "auth read ratings"   on public.ratings   for select to authenticated using (true);

-- ---------- write тільки адмінам ----------
create policy "admin write evaluators" on public.evaluators for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "admin write tracks" on public.tracks for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "admin write sessions" on public.sessions for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "admin write ratings" on public.ratings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- storage ----------
create policy "auth read covers" on storage.objects for select to authenticated
  using (bucket_id = 'covers');
create policy "admin write covers" on storage.objects for insert to authenticated
  with check (bucket_id = 'covers' and public.is_admin());
create policy "admin update covers" on storage.objects for update to authenticated
  using (bucket_id = 'covers' and public.is_admin());
