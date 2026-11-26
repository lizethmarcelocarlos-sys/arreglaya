-- ArreglaYa · Pagos con QR del Banco Económico (los usa la Edge Function «pagos»).
-- Ejecutar UNA VEZ en Supabase > SQL Editor, después de las migraciones 002 a 010.
-- Solo AGREGA una tabla: no cambia ni borra nada de lo que ya existe.

create table if not exists public.pagos_qr (
  id bigint generated always as identity primary key,
  offer_id bigint not null references public.offers(id) on delete restrict,
  request_id bigint not null references public.service_requests(id) on delete restrict,
  client_id uuid not null references public.profiles(id) on delete restrict,
  technician_id uuid not null references public.profiles(id) on delete restrict,
  -- Lo que se cobra en el QR (puede ser el monto de prueba) y el precio real de la oferta
  monto numeric(10, 2) not null check (monto > 0),
  precio_oferta numeric(10, 2) not null,
  estado text not null default 'pendiente'
    check (estado in ('pendiente', 'pagado', 'vencido', 'fallido', 'pagado_tarde')),
  transaction_id text not null unique,
  qr_id text unique,
  imagen text,
  creado timestamptz not null default now(),
  vence timestamptz not null,
  pagado_en timestamptz,
  confirmado_por text check (confirmado_por in ('pantalla', 'aviso', 'revision')),
  pagador_nombre text,
  ultima_consulta timestamptz
);

-- Una oferta se paga UNA sola vez, y no puede tener dos QR pendientes a la vez
-- (dos toques seguidos en «Pagar» no generan dos cobros).
create unique index if not exists pagos_qr_un_pagado_por_oferta
  on public.pagos_qr (offer_id) where estado = 'pagado';
create unique index if not exists pagos_qr_un_pendiente_por_oferta
  on public.pagos_qr (offer_id) where estado = 'pendiente';
create index if not exists pagos_qr_estado_idx on public.pagos_qr (estado);
create index if not exists pagos_qr_request_idx on public.pagos_qr (request_id);

-- Solo la Edge Function (con la clave de servicio) escribe pagos. El cliente y el técnico
-- de la solicitud pueden VER los suyos; nadie puede crearlos ni cambiarlos desde la app.
alter table public.pagos_qr enable row level security;

drop policy if exists "Cliente y técnico ven sus pagos" on public.pagos_qr;
create policy "Cliente y técnico ven sus pagos"
  on public.pagos_qr for select to authenticated
  using (client_id = auth.uid() or technician_id = auth.uid());

revoke insert, update, delete on public.pagos_qr from anon, authenticated;
