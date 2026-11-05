-- ============================================================
-- Три Вальта — схема Supabase
-- Виконати в SQL Editor на https://supabase.com/dashboard
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- evaluators ----------
create table if not exists public.evaluators (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  avatar_url  text,
  created_at  timestamptz not null default now()
);

-- ---------- tracks ----------
create table if not exists public.tracks (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  artist       text,
  cover_url    text,
  year         text,
  length       text,
  lyrics       text,
  youtube_url  text,
  created_at   timestamptz not null default now()
);

create index if not exists tracks_title_idx on public.tracks (title);

-- ---------- sessions (хвиля оцінювання) ----------
create table if not exists public.sessions (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now()
);

-- ---------- ratings ----------
create table if not exists public.ratings (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid references public.sessions(id) on delete set null,
  track_id      uuid not null references public.tracks(id) on delete cascade,
  evaluator_id  uuid not null references public.evaluators(id) on delete cascade,
  vibe          numeric(3,1) check (vibe between 0 and 10),
  text          numeric(3,1) check (text between 0 and 10),
  beat          numeric(3,1) check (beat between 0 and 10),
  created_at    timestamptz not null default now(),
  unique (session_id, track_id, evaluator_id)
);

create index if not exists ratings_track_idx on public.ratings (track_id);

-- ---------- storage bucket для обкладинок ----------
insert into storage.buckets (id, name, public)
values ('covers', 'covers', true)
on conflict (id) do nothing;

-- ---------- profiles (ролі користувачів) ----------
-- Виконується ПІСЛЯ того, як у Supabase увімкнено Email Auth
-- (Authentication -> Sign In / Providers -> Email).
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        text not null default 'user' check (role in ('admin','user')),
  display_name text,
  created_at  timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Кожен залогінений бачить свій профіль
-- (не можна select з тієї ж таблиці в USING — рекурсія RLS)
create policy "read own profile" on public.profiles
  for select to authenticated
  using (id = auth.uid());

create policy "admin insert profile" on public.profiles
  for insert to authenticated with check (false); -- профілі створює service_role/тригер

-- Допоміжна функція: чи поточний юзер адмін
create or replace function public.is_admin()
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- Тригер: при реєстрації створювати профіль з роллю 'user'
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

-- ---------- RLS ----------
alter table public.evaluators enable row level security;
alter table public.tracks    enable row level security;
alter table public.sessions  enable row level security;
alter table public.ratings   enable row level security;

-- Читання — усім залогіненим (user і admin)
create policy "auth read evaluators" on public.evaluators for select to authenticated using (true);
create policy "auth read tracks"    on public.tracks    for select to authenticated using (true);
create policy "auth read sessions"  on public.sessions  for select to authenticated using (true);
create policy "auth read ratings"   on public.ratings   for select to authenticated using (true);

-- Запис — лише адмінам
create policy "admin write evaluators" on public.evaluators for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "admin write tracks" on public.tracks for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "admin write sessions" on public.sessions for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "admin write ratings" on public.ratings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Storage: читання обкладинок залогіненим, запис — адмінам
create policy "auth read covers" on storage.objects for select to authenticated
  using (bucket_id = 'covers');
create policy "admin write covers" on storage.objects for insert to authenticated
  with check (bucket_id = 'covers' and public.is_admin());
create policy "admin update covers" on storage.objects for update to authenticated
  using (bucket_id = 'covers' and public.is_admin());

-- ---------- view: трек з усіма оцінками ----------
create or replace view public.track_scores as
select
  t.id,
  t.title,
  t.artist,
  t.cover_url,
  t.year,
  t.length,
  t.album,
  t.youtube_url,
  t.created_at,
  count(r.id) filter (where r.vibe is not null) as ratings_count,
  round(avg((r.vibe + r.text + r.beat) / 3.0) filter (where r.vibe is not null), 2) as final_score
from public.tracks t
left join public.ratings r on r.track_id = t.id
group by t.id;
