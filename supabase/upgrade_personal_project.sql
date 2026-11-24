-- Actualizacion del proyecto existente prdzxcybmcxprzjsovuy; conserva cuentas y filas.
begin;
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

drop policy if exists "Usuarios ven imágenes de solicitudes" on public.request_images;
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

drop policy if exists "Cliente agrega imágenes a su solicitud" on public.request_images;
create policy "Cliente agrega imágenes a su solicitud"
  on public.request_images for insert to authenticated
  with check (
    exists (
      select 1 from public.service_requests r
      where r.id = request_id and r.client_id = auth.uid()
    )
  );

drop policy if exists "Usuarios autenticados descargan imágenes" on storage.objects;
create policy "Usuarios autenticados descargan imágenes"
  on storage.objects for select to authenticated
  using (bucket_id = 'request-media');

drop policy if exists "Usuario sube sus propias imágenes" on storage.objects;
create policy "Usuario sube sus propias imágenes"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'request-media' and owner_id = auth.uid()::text);

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

revoke all on public.profiles, public.service_requests, public.offers, public.request_images,
  public.service_reviews, public.technician_portfolio, public.verification_documents from anon;
grant select on public.profiles, public.service_requests, public.offers, public.request_images,
  public.service_reviews, public.technician_portfolio, public.verification_documents to authenticated;
grant insert on public.service_requests, public.offers, public.request_images,
  public.service_reviews, public.technician_portfolio, public.verification_documents to authenticated;
grant update on public.service_requests, public.verification_documents to authenticated;
grant delete on public.technician_portfolio to authenticated;
grant usage, select on sequence public.service_requests_id_seq, public.offers_id_seq,
  public.request_images_id_seq, public.service_reviews_id_seq,
  public.technician_portfolio_id_seq, public.verification_documents_id_seq to authenticated;

drop policy if exists "Técnico reemplaza sus documentos" on public.verification_documents;
create policy "Técnico reemplaza sus documentos" on public.verification_documents
  for update to authenticated using (technician_id=auth.uid()) with check (technician_id=auth.uid());
drop policy if exists "Usuario reemplaza sus archivos" on storage.objects;
create policy "Usuario reemplaza sus archivos" on storage.objects for update to authenticated
  using (bucket_id in ('profile-avatars','verification-documents') and owner_id=auth.uid()::text)
  with check (bucket_id in ('profile-avatars','verification-documents') and owner_id=auth.uid()::text);

do $$
declare target_table text;
begin
  foreach target_table in array array['profiles','service_requests','offers'] loop
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime'
      and schemaname='public' and tablename=target_table) then
      execute format('alter publication supabase_realtime add table public.%I',target_table);
    end if;
  end loop;
end $$;
revoke all on function public.handle_new_user() from public, anon, authenticated;
notify pgrst, 'reload schema';
commit;

