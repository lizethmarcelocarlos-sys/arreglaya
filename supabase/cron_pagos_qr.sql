-- ArreglaYa · Revisión de cada minuto de los pagos QR (confirma pagos aunque el cliente cierre la app
-- y anula los QR vencidos). Llama a la Edge Function «pagos» con pg_cron + pg_net.
-- Antes: guardar el mismo token en la función →  npx supabase secrets set REVISION_TOKEN=<token>
-- y poner ese token en «x-revision-token» (abajo). El token solo sirve para pedir la revisión
-- (no mueve plata); queda visible solo para los administradores de la base (tabla cron.job).

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- Tarea cada minuto (se reemplaza si ya existía)
select cron.unschedule(jobid) from cron.job where jobname = 'arreglaya-revisar-pagos-qr';
select cron.schedule(
  'arreglaya-revisar-pagos-qr',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://prdzxcybmcxprzjsovuy.supabase.co/functions/v1/pagos/revisar',
    headers := '{"Content-Type": "application/json", "x-revision-token": "PEGAR_EL_TOKEN"}'::jsonb,
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);
