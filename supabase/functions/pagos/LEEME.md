# Edge Function «pagos» (QR del Banco Económico)

Cobra el trabajo terminado con un QR del Banco Económico. Vive **en Supabase**, en internet. El APK le habla directo, así que funciona en cualquier celular y red, **sin ninguna laptop prendida**.

```
App (Flutter) ──token de sesión──▶ Edge Function «pagos» ──claves del banco──▶ Banco Económico
                                        │
                                        └──▶ tabla public.pagos_qr (con la clave de servicio)
```

- URL pública: `https://prdzxcybmcxprzjsovuy.supabase.co/functions/v1/pagos`. La app la usa por defecto (`lib/pago_qr.dart`).
- **Solo cobra si el trabajo está completado**: la oferta tiene que estar aceptada y la solicitud en `status = 'completada'` o `work_stage = 'completado'`.
- El monto lo pone la función, nunca la app. Con `MONTO_PRUEBA=1` cada QR sale por **Bs 1**. Para cobrar el precio real de la oferta, poné `MONTO_PRUEBA=0`.
- Cada pago se confirma **una sola vez**, por tres caminos:
  1. La pantalla de la app pregunta cada 3 segundos.
  2. El banco avisa a `/pagos/aviso-banco`, si se registra esa URL en el banco.
  3. Una revisión cada minuto la dispara `pg_cron`.
- La base no deja dos pagos de la misma oferta ni dos QR pendientes a la vez. Hay índices únicos en `011_pagos_qr.sql`.
- Los QR vencidos se anulan en el banco. Si igual se cobra uno de más, queda `pagado_tarde` para devolverlo.

## Archivos

| Archivo | Para qué |
| --- | --- |
| `index.ts` | Entrada de la función (`Deno.serve`). |
| `logica.ts` | Rutas, reglas y la revisión. |
| `baneco.ts` | Conector del banco: la misma lógica de `servidor-pagos/src/baneco.js`, que ya cobró plata real. |
| `../../migrations/011_pagos_qr.sql` | Tabla `pagos_qr` con RLS. Cada uno ve solo sus pagos; nadie escribe desde la app. |
| `../../cron_pagos_qr.sql` | Revisión de cada minuto (`pg_cron` + `pg_net`). |
| `../../pruebas/pagos-edge.ts` | 25 pruebas con un banco falso y un Supabase falso (`node supabase/pruebas/pagos-edge.ts`). |

## Cómo se instaló (25/11/2026)

Desde la carpeta del proyecto, con la herramienta de Supabase (`npx supabase@3.4.0`):

```
npx supabase login
npx supabase db query --remote=prdzxcybmcxprzjsovuy --file supabase/migrations/011_pagos_qr.sql --yes
npx supabase functions deploy pagos --remote=prdzxcybmcxprzjsovuy --no-verify-jwt --use-api --yes
npx supabase secrets set --env-file servidor-pagos/.env --remote=prdzxcybmcxprzjsovuy --yes
npx supabase secrets set REVISION_TOKEN=<token> --remote=prdzxcybmcxprzjsovuy --yes
```

Notas sobre esos comandos:

- `--no-verify-jwt` hace falta porque el aviso del banco y el cron no traen sesión. La propia función revisa la sesión del usuario en cada ruta de la app.
- `servidor-pagos/.env` tiene `BANECO_URL`, `BANECO_USUARIO`, `BANECO_CLAVE`, `BANECO_LLAVE_AES`, `BANECO_CUENTA`, `MONTO_PRUEBA` y `QR_VIDA_MINUTOS`. **Nunca se sube a GitHub.**
- Después se corrió `cron_pagos_qr.sql`, con el mismo token en `x-revision-token`.

Para **actualizar la función** después de cambiar el código, repetí solo el `functions deploy`. Para **cambiar las claves o el monto de prueba**, `secrets set`.

## Comprobar que anda

```
curl https://prdzxcybmcxprzjsovuy.supabase.co/functions/v1/pagos/salud
```

Responde `{"ok":true,"banco":true,"montoPrueba":1,...}`.

Los registros (logs) se ven en Supabase, en Edge Functions → pagos → Logs.

## Ojo con la plata

Hoy la función usa las claves de **Lemur** (prueba). Cada QR pagado entra en la cuenta de Lemur. Para que ArreglaYa cobre en serio, el equipo necesita **sus propias claves del Banco Económico**. Después se cambian con `secrets set` y se pone `MONTO_PRUEBA=0`.
