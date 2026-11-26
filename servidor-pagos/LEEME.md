# Servidor de pagos de ArreglaYa (QR del Banco Económico)

> **La app ya no usa este servidor por defecto:** el cobro está en la Edge Function de Supabase ([`supabase/functions/pagos/`](../supabase/functions/pagos/LEEME.md)), que vive en internet. Este servidor Node.js queda para probar en una PC (y su página `/prueba`). Para que la app lo use: `--dart-define=PAGOS_URL=http://IP-DE-LA-PC:3100/api/pagos`.

La app cobra el trabajo, cuando el técnico lo marca como completado, con un QR del Banco Económico. Las claves del banco **no pueden ir dentro de la app**: cualquiera que abra el APK las sacaría. Por eso hay este servidorcito Node.js. Solo él habla con el banco. La app le pide el QR y le pregunta si ya se pagó.

```
App (Flutter) ──token de Supabase──▶ servidor-pagos ──claves del banco──▶ Banco Económico
                                         │
                                         └──▶ Supabase (con el token del usuario: ¿la oferta es suya y está aceptada?)
```

- El **monto lo pone el servidor**, mirando el precio de la oferta en Supabase. La app solo manda el número de oferta.
- Con `MONTO_PRUEBA=1` (así viene) **cada QR sale por Bs 1**, cueste lo que cueste la oferta. La pantalla avisa «Modo prueba». Para cobrar el precio real, poné `MONTO_PRUEBA=0`.
- No instala nada: Node.js 18 o más nuevo.

## 1. Probar sin plata (banco de mentira)

```
cd servidor-pagos
node servidor.js --falso
```

Abrí `http://localhost:3100`. Cada cobro que pida la app aparece ahí con un botón **«Simular pago»**.

## 2. Poner los datos del banco

```
cd servidor-pagos
node configurar.js
```

Te pide usuario, contraseña, llave AES y cuenta **sin mostrarlos**. Te muestra una huella (largo, primeras y últimas letras) para que la compares. Recién con tu «s» los prueba con el banco: inicia sesión, genera un QR de Bs 1 y lo anula enseguida. Si todo sale bien, los guarda en `servidor-pagos/.env`. Ese archivo **no se sube a GitHub**.

## 3. Prender el servidor

```
node servidor.js
```

Al prender muestra las direcciones de la PC, por ejemplo `--dart-define=PAGOS_URL=http://192.168.1.50:3100`. Usá la del Wi-Fi. La primera vez Windows pregunta si deja entrar conexiones a Node.js: aceptá en **redes privadas**.

## Probar con plata real sin la app

Con el servidor prendido, abrí **http://localhost:3100/prueba** en la PC. El botón genera un QR real por el monto de prueba (Bs 1). Pagalo con la app de tu banco desde el celular y la página pasa sola a **«¡Pagado!»**. Esta página solo responde desde la misma PC: nadie más del Wi-Fi puede generar QR.

Para traer los datos del banco de una tienda que ya cobra con el Banco Económico, sin verlos ni copiarlos a mano:

```
node configurar.js --ssh root@IP-DEL-SERVIDOR:/ruta/de/la/tienda/.env
```

Trae solo las líneas BANECO_ y las prueba antes de guardarlas. Al terminar la prueba: `node configurar.js --borrar`.

## 4. Compilar la app con el pago

El celular tiene que estar en el **mismo Wi-Fi** que la PC.

```
flutter build apk --debug --dart-define=PAGOS_URL=http://IP-DE-LA-PC:3100/api/pagos
```

En la app: el técnico marca el trabajo como **completado** → el cliente abre la solicitud → en «Trabajo completado» aparece **«Pagar el trabajo»** → **«Pagar con QR»**. Aparece el QR. Págalo con la app de cualquier banco, desde otro celular o con una captura desde el mismo. A los segundos dice **«¡Pagado!»** y la solicitud queda en «Pagado con QR».

El servidor no genera el QR si el trabajo todavía no está completado (responde «el técnico tiene que marcar el trabajo como completado»).

Si la app se compila sin `PAGOS_URL`, el botón no aparece y la app queda como antes.

## Cómo no se pierde ningún pago

El pago se confirma por tres caminos, y se marca pagado **una sola vez**:

1. La pantalla de la app pregunta cada 3 segundos, y otra vez apenas volvés de la app del banco.
2. El banco avisa a `POST /aviso-banco`, si se registra esa URL en el banco (tiene que ser https y pública). Nunca se confía en el aviso solo: se le pregunta al banco.
3. Una revisión cada minuto mira la lista de pagados del día.

Los QR valen 10 minutos (`QR_VIDA_MINUTOS`). Pasado ese tiempo se anulan en el banco: el banco los vence por día, no por minutos. Antes de anular se pregunta una última vez, por si se pagó justo.

## Pruebas

```
npm test
```

Son 29 pruebas contra un banco falso y un Supabase falso: permisos, cobro, los tres caminos, vencimiento, monto de prueba y la página de prueba. No usan internet ni plata.

## Archivos

| Archivo | Para qué |
| --- | --- |
| `servidor.js` | El servidor (cobros, consulta, aviso del banco, revisión de cada minuto). |
| `configurar.js` | Pide (o trae por SSH), prueba y guarda los datos del banco. `--borrar` los quita. |
| `prueba.html` | Página de prueba en http://localhost:3100/prueba (solo desde la PC). |
| `src/baneco.js` | El conector del Banco Económico (el mismo del paquete genérico). |
| `pruebas/` | Banco falso y pruebas automáticas. |
| `datos/cobros.json` | Se crea solo: los cobros. No se sube a GitHub. |
