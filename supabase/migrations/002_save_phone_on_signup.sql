-- Ejecuta este archivo una sola vez en Supabase > SQL Editor.
-- Actualiza el trigger de registro para guardar el número de WhatsApp.
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
