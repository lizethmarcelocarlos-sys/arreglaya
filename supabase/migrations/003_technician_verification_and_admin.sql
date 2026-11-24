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
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  selected_role public.user_role;
begin
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
