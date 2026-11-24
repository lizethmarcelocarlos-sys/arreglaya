alter table public.service_requests
  add column if not exists requested_at timestamptz,
  add column if not exists latitude double precision check (latitude between -90 and 90),
  add column if not exists longitude double precision check (longitude between -180 and 180);
