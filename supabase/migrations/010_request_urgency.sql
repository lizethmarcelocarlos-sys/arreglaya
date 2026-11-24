alter table public.service_requests
  add column if not exists urgency text not null default 'normal'
  check (urgency in ('normal', 'hoy', 'emergencia'));
