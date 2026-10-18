-- Busenfreunde-App v2 – Spitznamen pro Gruppe, getrennt vom Nest-Namen.
-- Im Nest-Supabase-Projekt ausführen (SQL Editor → einfügen → Run). Ändert keine Nest-Tabelle.

begin;

alter table public.bf_mitglieder
  add column spitzname text check (spitzname is null or char_length(btrim(spitzname)) between 1 and 40);
comment on column public.bf_mitglieder.spitzname is 'Name in dieser Gruppe. Leer = Name aus dem (mit Nest geteilten) Profil.';

-- Mitgliederliste: Spitzname vor Profilname vor E-Mail-Anfang
create or replace function public.bf_gruppen_mitglieder(target_gruppe_id uuid)
returns table(user_id uuid, display_name text, avatar_path text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.bf_is_member(target_gruppe_id) then
    raise exception 'Kein Zugriff auf diese Gruppe';
  end if;
  return query
    select m.user_id,
           coalesce(nullif(btrim(m.spitzname), ''), nullif(btrim(p.display_name), ''), split_part(u.email::text, '@', 1)),
           p.avatar_path
    from public.bf_mitglieder m
    join auth.users u on u.id = m.user_id
    left join public.profiles p on p.id = m.user_id
    where m.gruppe_id = target_gruppe_id
    order by m.joined_at;
end;
$$;

-- Eigenen Spitznamen setzen (leer = zurück zum Nest-Namen)
create or replace function public.bf_set_spitzname(target_gruppe_id uuid, name text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.bf_is_member(target_gruppe_id) then
    raise exception 'Kein Zugriff auf diese Gruppe';
  end if;
  update public.bf_mitglieder
    set spitzname = nullif(btrim(name), '')
    where gruppe_id = target_gruppe_id and user_id = auth.uid();
end;
$$;

revoke execute on function public.bf_set_spitzname(uuid, text) from public, anon;
grant execute on function public.bf_set_spitzname(uuid, text) to authenticated;

commit;
