begin;
do $$
declare c uuid:=gen_random_uuid(); t uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); r bigint; o bigint; o2 bigint; blocked boolean:=false;
begin
 insert into auth.users(id,email,raw_user_meta_data) values
 (c,c::text||'@example.invalid','{"app":"arreglaya","full_name":"Cliente de prueba","role":"cliente"}'),
 (t,t::text||'@example.invalid','{"app":"arreglaya","full_name":"Técnico de prueba","role":"tecnico"}'),
 (a,a::text||'@example.invalid','{"app":"arreglaya","full_name":"Admin de prueba","role":"cliente"}');
 if (select verification_status from public.profiles where id=t) <> 'pendiente' then raise exception 'Falló verificación inicial'; end if;
 update public.profiles set role='admin' where id=a;
 perform set_config('request.jwt.claim.sub',a::text,true);
 perform public.verify_technician(t,'verificado');
 insert into public.service_requests(client_id,category,description,zone) values(c,'Electricidad','Prueba temporal de servicio','Prueba') returning id into r;
 insert into public.offers(request_id,technician_id,price,message) values(r,t,100,'Oferta temporal') returning id into o;
 perform set_config('request.jwt.claim.sub',t::text,true);
 begin perform public.accept_offer(o); exception when insufficient_privilege then blocked:=true; end;
 if not blocked then raise exception 'Se permitió aceptar al técnico'; end if;
 perform set_config('request.jwt.claim.sub',c::text,true);
 perform public.accept_offer(o);
 if not exists(select 1 from public.service_requests where id=r and status='aceptada' and work_stage='aceptada') then raise exception 'Solicitud inconsistente'; end if;
 if not exists(select 1 from public.offers where id=o and status='aceptada') then raise exception 'Oferta inconsistente'; end if;
 blocked:=false;
 begin perform public.accept_offer(o); exception when raise_exception then blocked:=true; end;
 if not blocked then raise exception 'Se permitió aceptar otra vez'; end if;
 blocked:=false;
 begin perform public.verify_technician(t,'rechazado'); exception when insufficient_privilege then blocked:=true; end;
 if not blocked then raise exception 'Cliente pudo verificar'; end if;
 if has_column_privilege('authenticated','public.profiles','role','UPDATE') or has_column_privilege('authenticated','public.profiles','verification_status','UPDATE') or has_table_privilege('authenticated','public.offers','UPDATE') then raise exception 'Permisos inseguros'; end if;
 if not has_column_privilege('authenticated','public.profiles','phone','UPDATE') then raise exception 'Edición de contacto bloqueada'; end if;
 if has_function_privilege('anon','public.accept_offer(bigint)','EXECUTE') then raise exception 'Acceso anónimo'; end if;
end $$;
rollback;
select 'OK: registro, verificación, aceptación, permisos y rollback' as resultado;
select table_name from information_schema.tables where table_schema='public' order by table_name;