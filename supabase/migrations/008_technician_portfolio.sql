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
