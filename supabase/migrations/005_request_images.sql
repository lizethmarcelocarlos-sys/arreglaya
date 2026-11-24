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
