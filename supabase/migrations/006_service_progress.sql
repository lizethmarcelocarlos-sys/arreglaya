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
