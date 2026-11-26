// Edge Function «pagos» de ArreglaYa: cobro del trabajo terminado con QR del Banco Económico.
// Se instala con:  npx supabase functions deploy pagos --no-verify-jwt
// (la sesión del usuario la revisa la propia función; el aviso del banco y el cron no traen sesión).
// Los datos del banco van como secretos:  npx supabase secrets set --env-file servidor-pagos/.env
// Ver supabase/functions/pagos/LEEME.md
import { configDesdeEnv, crearManejador } from './logica.ts';

Deno.serve(crearManejador(configDesdeEnv((k) => Deno.env.get(k))));
