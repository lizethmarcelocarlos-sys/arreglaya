begin;
-- ArreglaYa · Esquema inicial para Supabase (PostgreSQL)
-- Pega este archivo completo en Supabase > SQL Editor > New query y ejecútalo.

create type public.user_role as enum ('cliente', 'tecnico', 'admin');
create type public.request_status as enum ('pendiente', 'aceptada', 'completada', 'cancelada');
create type public.offer_status as enum ('pendiente', 'aceptada', 'rechazada');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null check (char_length(trim(full_name)) >= 2),
  role public.user_role not null default 'cliente',
  phone text,
  created_at timestamptz not null default now()
);

create table public.service_requests (
  id bigint generated always as identity primary key,
  client_id uuid not null references public.profiles(id) on delete cascade,
  category text not null check (category in ('Electricidad', 'Plomería', 'Computadoras', 'Celulares', 'Electrodomésticos', 'Otro')),
  description text not null check (char_length(trim(description)) >= 10),
  zone text not null check (char_length(trim(zone)) >= 2),
  status public.request_status not null default 'pendiente',
  created_at timestamptz not null default now()
);

create table public.offers (
  id bigint generated always as identity primary key,
  request_id bigint not null references public.service_requests(id) on delete cascade,
  technician_id uuid not null references public.profiles(id) on delete cascade,
  price numeric(10, 2) not null check (price > 0),
  message text not null check (char_length(trim(message)) >= 3),
  status public.offer_status not null default 'pendiente',
  created_at timestamptz not null default now(),
  unique (request_id, technician_id)
);

create index service_requests_client_id_idx on public.service_requests(client_id);
create index service_requests_status_idx on public.service_requests(status);
create index offers_request_id_idx on public.offers(request_id);
create index offers_technician_id_idx on public.offers(technician_id);

-- Crea automáticamente el perfil al registrarse desde Flutter.
create or replace function public.arreglaya_handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  if new.raw_user_meta_data ->> 'app' is distinct from 'arreglaya' then return new; end if;
  insert into public.profiles (id, full_name, role, phone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', 'Usuario'),
    coalesce((new.raw_user_meta_data ->> 'role')::public.user_role, 'cliente'),
    nullif(new.raw_user_meta_data ->> 'phone', '')
  );
  return new;
end;
$$;

create trigger arreglaya_on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.arreglaya_handle_new_user();

alter table public.profiles enable row level security;
alter table public.service_requests enable row level security;
alter table public.offers enable row level security;

create policy "Usuarios autenticados ven perfiles"
  on public.profiles for select to authenticated using (true);
create policy "Usuario actualiza su perfil"
  on public.profiles for update to authenticated using (auth.uid() = id)
  with check (auth.uid() = id);

create policy "Usuarios autenticados ven solicitudes"
  on public.service_requests for select to authenticated using (true);
create policy "Cliente crea sus solicitudes"
  on public.service_requests for insert to authenticated
  with check (auth.uid() = client_id);
create policy "Cliente modifica sus solicitudes"
  on public.service_requests for update to authenticated using (auth.uid() = client_id)
  with check (auth.uid() = client_id);

create policy "Participantes ven ofertas"
  on public.offers for select to authenticated
  using (
    technician_id = auth.uid()
    or exists (
      select 1 from public.service_requests r
      where r.id = request_id and r.client_id = auth.uid()
    )
  );
create policy "Técnico crea una oferta"
  on public.offers for insert to authenticated
  with check (
    technician_id = auth.uid()
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'tecnico')
  );
create policy "Cliente responde sus ofertas"
  on public.offers for update to authenticated
  using (
    exists (
      select 1 from public.service_requests r
      where r.id = request_id and r.client_id = auth.uid()
    )
  );

-- Ejecuta este archivo una sola vez en Supabase > SQL Editor.
-- Actualiza el trigger de registro para guardar el número de WhatsApp.
create or replace function public.arreglaya_handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  if new.raw_user_meta_data ->> 'app' is distinct from 'arreglaya' then return new; end if;
  insert into public.profiles (id, full_name, role, phone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', 'Usuario'),
    coalesce((new.raw_user_meta_data ->> 'role')::public.user_role, 'cliente'),
    nullif(new.raw_user_meta_data ->> 'phone', '')
  );
  return new;
end;
$$;

-- ArreglaYa · Verificación de técnicos y administrador.
-- Ejecuta este archivo UNA VEZ en Supabase > SQL Editor.

alter type public.user_role add value if not exists 'admin';

alter table public.profiles
  add column if not exists specialties text,
  add column if not exists work_zone text,
  add column if not exists experience_years integer check (experience_years >= 0),
  add column if not exists verification_status text not null default 'verificado'
    check (verification_status in ('pendiente', 'verificado', 'rechazado'));

-- Las cuentas nuevas de técnico siempre quedan pendientes.
-- El rol recibido de la app se limita a cliente/técnico: nadie puede registrarse como administrador.
create or replace function public.arreglaya_handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  selected_role public.user_role;
begin
  if new.raw_user_meta_data ->> 'app' is distinct from 'arreglaya' then return new; end if;
  selected_role := case
    when new.raw_user_meta_data ->> 'role' = 'tecnico' then 'tecnico'::public.user_role
    else 'cliente'::public.user_role
  end;

  insert into public.profiles (
    id, full_name, role, phone, specialties, work_zone, experience_years, verification_status
  ) values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', 'Usuario'),
    selected_role,
    nullif(new.raw_user_meta_data ->> 'phone', ''),
    nullif(new.raw_user_meta_data ->> 'specialties', ''),
    nullif(new.raw_user_meta_data ->> 'work_zone', ''),
    nullif(new.raw_user_meta_data ->> 'experience_years', '')::integer,
    case when selected_role = 'tecnico' then 'pendiente' else 'verificado' end
  );
  return new;
end;
$$;

-- Solo el administrador puede modificar perfiles de otros usuarios para verificarlos.
create policy "Administrador verifica técnicos"
  on public.profiles for update to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role::text = 'admin'))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role::text = 'admin'));

-- Un técnico pendiente no puede consultar ni ofertar trabajos.
drop policy if exists "Usuarios autenticados ven solicitudes" on public.service_requests;
create policy "Clientes y técnicos verificados ven solicitudes"
  on public.service_requests for select to authenticated
  using (
    client_id = auth.uid()
    or exists (
      select 1 from public.profiles p
      where p.id = auth.uid()
        and (p.role::text = 'admin' or (p.role = 'tecnico' and p.verification_status = 'verificado'))
    )
  );

drop policy if exists "Técnico crea una oferta" on public.offers;
create policy "Técnico verificado crea una oferta"
  on public.offers for insert to authenticated
  with check (
    technician_id = auth.uid()
    and exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'tecnico' and p.verification_status = 'verificado'
    )
  );

-- Después de crear tu primera cuenta, ejecútalo cambiando el correo por el tuyo:
-- update public.profiles set role = 'admin'
-- where id = (select id from auth.users where email = 'TU_CORREO@EJEMPLO.COM');

alter table public.service_requests
  add column if not exists requested_at timestamptz,
  add column if not exists latitude double precision check (latitude between -90 and 90),
  add column if not exists longitude double precision check (longitude between -180 and 180);

insert into storage.buckets (id, name, public)
values ('request-media', 'request-media', false)
on conflict (id) do nothing;

create table if not exists public.request_images (
  id bigint generated always as identity primary key,
  request_id bigint not null references public.service_requests(id) on delete cascade,
  path text not null unique,
  created_at timestamptz not null default now()
);

alter table public.request_images enable row level security;

create policy "Usuarios ven imágenes de solicitudes"
  on public.request_images for select to authenticated
  using (
    exists (
      select 1 from public.service_requests r
      where r.id = request_id and r.client_id = auth.uid()
    )
    or exists (
      select 1 from public.profiles p
      where p.id = auth.uid()
        and (p.role::text = 'admin' or (p.role = 'tecnico' and p.verification_status = 'verificado'))
    )
  );

create policy "Cliente agrega imágenes a su solicitud"
  on public.request_images for insert to authenticated
  with check (
    exists (
      select 1 from public.service_requests r
      where r.id = request_id and r.client_id = auth.uid()
    )
  );

create policy "Usuarios autenticados descargan imágenes"
  on storage.objects for select to authenticated
  using (bucket_id = 'request-media');

create policy "Usuario sube sus propias imágenes"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'request-media' and owner_id = auth.uid()::text);

alter table public.service_requests
  add column if not exists work_stage text,
  add column if not exists work_started_at timestamptz,
  add column if not exists completed_at timestamptz;

drop policy if exists "Técnico actualiza su servicio aceptado" on public.service_requests;

create policy "Técnico actualiza su servicio aceptado"
  on public.service_requests for update to authenticated
  using (
    exists (
      select 1 from public.offers o
      where o.request_id = public.service_requests.id and o.technician_id = auth.uid() and o.status = 'aceptada'
    )
  )
  with check (
    exists (
      select 1 from public.offers o
      where o.request_id = public.service_requests.id and o.technician_id = auth.uid() and o.status = 'aceptada'
    )
  );

create table if not exists public.service_reviews (
  id bigint generated always as identity primary key,
  request_id bigint not null unique references public.service_requests(id) on delete cascade,
  client_id uuid not null references public.profiles(id) on delete cascade,
  technician_id uuid not null references public.profiles(id) on delete cascade,
  rating integer not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);

alter table public.service_reviews enable row level security;

create policy "Usuarios autenticados ven calificaciones"
  on public.service_reviews for select to authenticated using (true);

create policy "Cliente califica un servicio completado"
  on public.service_reviews for insert to authenticated
  with check (
    client_id = auth.uid()
    and exists (
      select 1 from public.service_requests r
      where r.id = request_id and r.client_id = auth.uid() and r.status = 'completada'
    )
    and exists (
      select 1 from public.offers o
      where o.request_id = request_id and o.technician_id = technician_id and o.status = 'aceptada'
    )
  );

insert into storage.buckets (id, name, public)
values ('technician-portfolio', 'technician-portfolio', false)
on conflict (id) do nothing;

create table if not exists public.technician_portfolio (
  id bigint generated always as identity primary key,
  technician_id uuid not null references public.profiles(id) on delete cascade,
  path text not null unique,
  created_at timestamptz not null default now()
);

alter table public.technician_portfolio enable row level security;

create policy "Usuarios autenticados ven portafolios"
  on public.technician_portfolio for select to authenticated using (true);

create policy "Técnico agrega su portafolio"
  on public.technician_portfolio for insert to authenticated
  with check (technician_id = auth.uid());

create policy "Técnico elimina su portafolio"
  on public.technician_portfolio for delete to authenticated
  using (technician_id = auth.uid());

create policy "Usuarios autenticados descargan portafolio"
  on storage.objects for select to authenticated
  using (bucket_id = 'technician-portfolio');

create policy "Técnico sube su portafolio"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'technician-portfolio' and owner_id = auth.uid()::text);

alter table public.profiles add column if not exists avatar_path text;

insert into storage.buckets (id, name, public) values
  ('profile-avatars', 'profile-avatars', false),
  ('verification-documents', 'verification-documents', false)
on conflict (id) do nothing;

create table if not exists public.verification_documents (
  id bigint generated always as identity primary key,
  technician_id uuid not null references public.profiles(id) on delete cascade,
  document_type text not null check (document_type in ('carnet_anverso', 'carnet_reverso', 'certificado')),
  path text not null unique,
  created_at timestamptz not null default now(),
  unique (technician_id, document_type)
);

alter table public.verification_documents enable row level security;

create policy "Técnico y admin ven documentos" on public.verification_documents for select to authenticated
  using (technician_id = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role::text = 'admin'));
create policy "Técnico sube sus documentos" on public.verification_documents for insert to authenticated
  with check (technician_id = auth.uid());
create policy "Usuarios ven avatares" on storage.objects for select to authenticated
  using (bucket_id = 'profile-avatars');
create policy "Usuario sube su avatar" on storage.objects for insert to authenticated
  with check (bucket_id = 'profile-avatars' and owner_id = auth.uid()::text);
create policy "Técnico y admin ven documentos privados" on storage.objects for select to authenticated
  using (bucket_id = 'verification-documents' and (owner_id = auth.uid()::text or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role::text = 'admin')));
create policy "Técnico sube documentos privados" on storage.objects for insert to authenticated
  with check (bucket_id = 'verification-documents' and owner_id = auth.uid()::text);

alter table public.service_requests
  add column if not exists urgency text not null default 'normal'
  check (urgency in ('normal', 'hoy', 'emergencia'));

-- Ejecutar DESPUÉS del esquema y las migraciones 002 a 010.
-- Aplicar antes de distribuir la nueva app. Todo se ejecuta en una transacción.

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- El cliente solo puede editar campos de presentación, nunca sus permisos.
revoke update on public.profiles from public, anon, authenticated;
grant update (full_name, phone, specialties, work_zone, experience_years, avatar_path)
  on public.profiles to authenticated;
drop policy if exists "Administrador verifica técnicos" on public.profiles;

create or replace function private.verify_technician(p_technician_id uuid, p_status text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.profiles where id = auth.uid() and role::text = 'admin'
  ) then
    raise exception 'Solo un administrador puede verificar técnicos.' using errcode = '42501';
  end if;
  if p_status not in ('verificado', 'rechazado') or p_status is null then
    raise exception 'Estado de verificación inválido.';
  end if;
  update public.profiles set verification_status = p_status
    where id = p_technician_id and role::text = 'tecnico';
  if not found then raise exception 'No se encontró el técnico.'; end if;
end;
$$;
revoke all on function private.verify_technician(uuid, text) from public, anon;
grant execute on function private.verify_technician(uuid, text) to authenticated;

create or replace function public.verify_technician(p_technician_id uuid, p_status text)
returns void language sql security invoker set search_path = '' as $$
  select private.verify_technician(p_technician_id, p_status);
$$;
revoke all on function public.verify_technician(uuid, text) from public, anon;
grant execute on function public.verify_technician(uuid, text) to authenticated;

-- Detiene el cambio completo si hay conflictos previos: no altera su historial.
create unique index if not exists offers_one_accepted_per_request
  on public.offers(request_id) where status = 'aceptada';
revoke update on public.offers from public, anon, authenticated;

drop policy if exists "Técnico verificado crea una oferta" on public.offers;
create policy "Técnico verificado crea una oferta" on public.offers
for insert to authenticated with check (
  technician_id = auth.uid() and status = 'pendiente'
  and exists (select 1 from public.profiles p where p.id = auth.uid()
    and p.role::text = 'tecnico' and p.verification_status = 'verificado')
  and exists (select 1 from public.service_requests r where r.id = request_id
    and r.status = 'pendiente' and r.client_id <> auth.uid())
);

create or replace function private.accept_offer(p_offer_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare
  selected_offer public.offers%rowtype;
  selected_request public.service_requests%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Inicia sesión para aceptar una oferta.' using errcode = '42501';
  end if;
  select * into selected_offer from public.offers where id = p_offer_id;
  if not found then raise exception 'La oferta ya no está disponible.'; end if;
  -- Todas las aceptaciones de una solicitud comparten este bloqueo.
  select * into selected_request from public.service_requests
    where id = selected_offer.request_id for update;
  if selected_request.client_id is distinct from auth.uid() then
    raise exception 'Solo el dueño de la solicitud puede aceptar ofertas.' using errcode = '42501';
  end if;
  if selected_request.status <> 'pendiente' then
    raise exception 'Esta solicitud ya fue asignada o cerrada.';
  end if;
  if selected_offer.status <> 'pendiente' then
    raise exception 'La oferta ya no está disponible.';
  end if;
  perform 1 from public.profiles where id = selected_offer.technician_id
    and role::text = 'tecnico' and verification_status = 'verificado' for share;
  if not found then raise exception 'El técnico ya no está verificado.'; end if;
  update public.offers set status = case when id = p_offer_id
    then 'aceptada'::public.offer_status else 'rechazada'::public.offer_status end
    where request_id = selected_request.id and status = 'pendiente';
  update public.service_requests set status = 'aceptada', work_stage = 'aceptada'
    where id = selected_request.id;
end;
$$;
revoke all on function private.accept_offer(bigint) from public, anon;
grant execute on function private.accept_offer(bigint) to authenticated;

create or replace function public.accept_offer(p_offer_id bigint)
returns void language sql security invoker set search_path = '' as $$
  select private.accept_offer(p_offer_id);
$$;
revoke all on function public.accept_offer(bigint) from public, anon;
grant execute on function public.accept_offer(bigint) to authenticated;


revoke all on public.profiles, public.service_requests, public.offers, public.request_images, public.service_reviews, public.technician_portfolio, public.verification_documents from anon;
grant select on public.profiles, public.service_requests, public.offers, public.request_images, public.service_reviews, public.technician_portfolio, public.verification_documents to authenticated;
grant insert on public.service_requests, public.offers, public.request_images, public.service_reviews, public.technician_portfolio, public.verification_documents to authenticated;
grant update on public.service_requests to authenticated;
grant delete on public.technician_portfolio to authenticated;
grant usage, select on sequence public.service_requests_id_seq, public.offers_id_seq, public.request_images_id_seq, public.service_reviews_id_seq, public.technician_portfolio_id_seq, public.verification_documents_id_seq to authenticated;
create policy "Técnico reemplaza sus documentos" on public.verification_documents for update to authenticated using (technician_id=auth.uid()) with check (technician_id=auth.uid());
alter publication supabase_realtime add table public.profiles, public.service_requests, public.offers;
revoke all on function public.arreglaya_handle_new_user() from public, anon, authenticated;
notify pgrst, 'reload schema';
commit;