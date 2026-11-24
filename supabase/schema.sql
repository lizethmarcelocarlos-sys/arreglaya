-- ArreglaYa · Esquema inicial para Supabase (PostgreSQL)
-- Pega este archivo completo en Supabase > SQL Editor > New query y ejecútalo.

create type public.user_role as enum ('cliente', 'tecnico');
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
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
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

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

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
