-- Busenfreunde-App v1 – im Nest-Supabase-Projekt ausführen (SQL Editor → einfügen → Run).
-- Legt nur neue bf_-Tabellen und einen privaten Bild-Speicher an.
-- Keine Nest-Tabelle wird verändert. Läuft komplett oder gar nicht (eine Transaktion).

begin;

create table public.bf_gruppen (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 60),
  join_code text unique,
  header_path text,
  created_at timestamptz not null default now()
);
comment on table public.bf_gruppen is 'Busenfreunde: eine Gruppe (Freundeskreis). Beitritt per join_code.';

create table public.bf_mitglieder (
  gruppe_id uuid not null references public.bf_gruppen(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (gruppe_id, user_id)
);
create index bf_mitglieder_user_idx on public.bf_mitglieder (user_id);

create table public.bf_eintraege (
  id uuid primary key default gen_random_uuid(),
  gruppe_id uuid not null references public.bf_gruppen(id) on delete cascade,
  typ text not null default 'aktivitaet' check (typ in ('aktivitaet', 'kochen')),
  titel text not null check (char_length(btrim(titel)) between 1 and 120),
  beschreibung text check (beschreibung is null or char_length(beschreibung) <= 4000),
  ort text check (ort is null or char_length(ort) <= 200),
  datum date,
  uhrzeit time,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.bf_eintraege is 'Busenfreunde: Aktivität oder Kochen. Ohne datum = Idee, mit datum = Termin.';
create index bf_eintraege_gruppe_datum_idx on public.bf_eintraege (gruppe_id, datum);
create index bf_eintraege_created_by_idx on public.bf_eintraege (created_by);

create table public.bf_kommentare (
  id uuid primary key default gen_random_uuid(),
  eintrag_id uuid not null references public.bf_eintraege(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  text text not null check (char_length(btrim(text)) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index bf_kommentare_eintrag_idx on public.bf_kommentare (eintrag_id, created_at);
create index bf_kommentare_user_idx on public.bf_kommentare (user_id);

create table public.bf_join_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default now()
);
create index bf_join_attempts_user_idx on public.bf_join_attempts (user_id, attempted_at);

create or replace function public.bf_set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
create trigger trg_bf_eintraege_updated_at before update on public.bf_eintraege
  for each row execute function public.bf_set_updated_at();

-- Mitgliedschaft prüfen (security definer, damit die Regel auf bf_mitglieder sich nicht selbst aufruft)
create or replace function public.bf_is_member(target_gruppe_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.bf_mitglieder
    where gruppe_id = target_gruppe_id and user_id = auth.uid()
  );
$$;

-- Gruppe anlegen
create or replace function public.bf_create_gruppe(gruppen_name text)
returns table(id uuid, join_code text)
language plpgsql security definer set search_path = '' as $$
declare
  new_id uuid;
  new_code text;
begin
  if auth.uid() is null then
    raise exception 'Nicht angemeldet';
  end if;
  new_code := upper(substr(md5(gen_random_uuid()::text), 1, 8));
  insert into public.bf_gruppen (name, join_code) values (gruppen_name, new_code)
    returning bf_gruppen.id into new_id;
  insert into public.bf_mitglieder (gruppe_id, user_id) values (new_id, auth.uid());
  return query select new_id, new_code;
end;
$$;

-- Per Code beitreten, mit Bremse gegen Durchprobieren (10 Fehlversuche / 15 Min.)
create or replace function public.bf_join_by_code(code text)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  target_id uuid;
  recent integer;
begin
  if auth.uid() is null then
    raise exception 'Nicht angemeldet';
  end if;
  delete from public.bf_join_attempts where attempted_at < now() - interval '1 day';
  select count(*) into recent from public.bf_join_attempts
    where user_id = auth.uid() and attempted_at > now() - interval '15 minutes';
  if recent >= 10 then
    raise exception 'Zu viele Versuche. Bitte warte ein paar Minuten.';
  end if;
  select g.id into target_id from public.bf_gruppen g where g.join_code = upper(btrim(code));
  if target_id is null then
    insert into public.bf_join_attempts (user_id) values (auth.uid());
    raise exception 'Ungültiger Code';
  end if;
  insert into public.bf_mitglieder (gruppe_id, user_id) values (target_id, auth.uid())
    on conflict do nothing;
  delete from public.bf_join_attempts where user_id = auth.uid();
  return target_id;
end;
$$;

-- Mitglieder einer Gruppe mit Anzeigenamen (Profile sind sonst nur für einen selbst lesbar)
create or replace function public.bf_gruppen_mitglieder(target_gruppe_id uuid)
returns table(user_id uuid, display_name text, avatar_path text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.bf_is_member(target_gruppe_id) then
    raise exception 'Kein Zugriff auf diese Gruppe';
  end if;
  return query
    select m.user_id,
           coalesce(nullif(btrim(p.display_name), ''), split_part(u.email::text, '@', 1)),
           p.avatar_path
    from public.bf_mitglieder m
    join auth.users u on u.id = m.user_id
    left join public.profiles p on p.id = m.user_id
    where m.gruppe_id = target_gruppe_id
    order by m.joined_at;
end;
$$;

revoke execute on function public.bf_is_member(uuid) from public, anon;
revoke execute on function public.bf_create_gruppe(text) from public, anon;
revoke execute on function public.bf_join_by_code(text) from public, anon;
revoke execute on function public.bf_gruppen_mitglieder(uuid) from public, anon;
revoke execute on function public.bf_set_updated_at() from public, anon, authenticated;
grant execute on function public.bf_is_member(uuid) to authenticated;
grant execute on function public.bf_create_gruppe(text) to authenticated;
grant execute on function public.bf_join_by_code(text) to authenticated;
grant execute on function public.bf_gruppen_mitglieder(uuid) to authenticated;

-- Zugriffsregeln
alter table public.bf_gruppen enable row level security;
alter table public.bf_mitglieder enable row level security;
alter table public.bf_eintraege enable row level security;
alter table public.bf_kommentare enable row level security;
alter table public.bf_join_attempts enable row level security;
-- bf_join_attempts hat absichtlich keine Regel: kein Zugriff von außen, nur über die Funktion.

create policy "bf: Mitglieder sehen ihre Gruppe" on public.bf_gruppen
  for select to authenticated using (public.bf_is_member(id));
create policy "bf: Mitglieder ändern ihre Gruppe" on public.bf_gruppen
  for update to authenticated using (public.bf_is_member(id)) with check (public.bf_is_member(id));

create policy "bf: Mitglieder sehen Mitgliedschaften" on public.bf_mitglieder
  for select to authenticated using (public.bf_is_member(gruppe_id));
create policy "bf: Nutzer verlassen eine Gruppe" on public.bf_mitglieder
  for delete to authenticated using (user_id = (select auth.uid()));

create policy "bf: Mitglieder sehen Einträge" on public.bf_eintraege
  for select to authenticated using (public.bf_is_member(gruppe_id));
create policy "bf: Mitglieder legen Einträge an" on public.bf_eintraege
  for insert to authenticated with check (public.bf_is_member(gruppe_id) and created_by = (select auth.uid()));
create policy "bf: Mitglieder ändern Einträge" on public.bf_eintraege
  for update to authenticated using (public.bf_is_member(gruppe_id)) with check (public.bf_is_member(gruppe_id));
create policy "bf: Mitglieder löschen Einträge" on public.bf_eintraege
  for delete to authenticated using (public.bf_is_member(gruppe_id));

create policy "bf: Mitglieder sehen Kommentare" on public.bf_kommentare
  for select to authenticated using (
    exists (select 1 from public.bf_eintraege e where e.id = eintrag_id and public.bf_is_member(e.gruppe_id))
  );
create policy "bf: Mitglieder schreiben Kommentare" on public.bf_kommentare
  for insert to authenticated with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.bf_eintraege e where e.id = eintrag_id and public.bf_is_member(e.gruppe_id))
  );
create policy "bf: Nutzer löschen eigene Kommentare" on public.bf_kommentare
  for delete to authenticated using (user_id = (select auth.uid()));

-- Privater Bild-Speicher: Pfad <gruppe_id>/<datei>, nur für Gruppenmitglieder
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('busenfreunde', 'busenfreunde', false, 5242880, array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do nothing;

-- Vergleich als Text statt Cast nach uuid: Postgres garantiert keine Auswertungsreihenfolge,
-- ein Cast könnte sonst bei Nest-Bildpfaden ('households/...') einen Fehler werfen.
create or replace function public.bf_is_member_folder(folder text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.bf_mitglieder
    where gruppe_id::text = folder and user_id = auth.uid()
  );
$$;
revoke execute on function public.bf_is_member_folder(text) from public, anon;
grant execute on function public.bf_is_member_folder(text) to authenticated;

create policy "bf: Mitglieder verwalten Gruppenbilder" on storage.objects
  for all to authenticated
  using (bucket_id = 'busenfreunde' and public.bf_is_member_folder((storage.foldername(name))[1]))
  with check (bucket_id = 'busenfreunde' and public.bf_is_member_folder((storage.foldername(name))[1]));

commit;
