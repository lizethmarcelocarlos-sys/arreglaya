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
