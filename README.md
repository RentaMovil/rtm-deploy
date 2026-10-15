# rtm-deploy

Capa de publicación para RentaMóvil: **nginx** como proxy inverso delante de todo el stack
(front web + API Gateway) con **HTTPS real** sobre `rentamovil.tech` (Let's Encrypt), sin
modificar ningún repo de servicio. Pensado para correr en el VPS de producción.

## Cómo enruta nginx

El front web (`RentaMovil/web/Front-end`) ya llama a `/api/...` en su propio origen por defecto
(`httpClient.js`: `API_URL = import.meta.env.VITE_API_URL || '/api'`), igual que hace el proxy de
Vite en desarrollo. Por eso nginx solo necesita reproducir el mismo esquema de rutas:

| Ruta pública | A dónde va | Para qué |
|---|---|---|
| `/` | contenedor `web` (:4173) | Front web (build de producción) |
| `/api/*` | contenedor `api-gateway` (:8080), sin el prefijo `/api` | Todo lo que ya tiene backend real (auth, vehículos, reservas, pagos, GPS...) |
| `/mock/*` | contenedor `mock-api` (:3100), sin el prefijo `/mock` | Lo que todavía no tiene servicio real |

**La app móvil** debe apuntar su `EXPO_PUBLIC_API_URL` a `https://rentamovil.tech/api` (no a la
raíz) — así usa exactamente el mismo `location /api/` que el front web.

## Orden de arranque (todo con la red compartida `rentamovil`)

```bash
# Una sola vez por máquina
docker network create rentamovil

# 1. Bases de datos (cada una crea/migra su schema)
cd ../rtm-iam-db && docker compose up -d && cd ../rtm-deploy
cd ../rtm-fleet-maintenance-db && docker compose up -d && cd ../rtm-deploy
cd ../rtm-booking-db && docker compose up -d && cd ../rtm-deploy
cd ../rtm-payment-billing-db && docker compose up -d && cd ../rtm-deploy
cd ../rtm-telemetry-gps-db && docker compose up -d && cd ../rtm-deploy

# 2. Servicios de aplicación
cd ../rtm-iam && docker compose up -d && cd ../rtm-deploy
cd ../rtm-fleet-maintenance && docker compose up -d && cd ../rtm-deploy
cd ../rtm-booking-reservation && docker compose up -d && cd ../rtm-deploy
cd ../rtm-payment-billing && docker compose up -d && cd ../rtm-deploy
cd ../rtm-telemetry-gps && docker compose up -d && cd ../rtm-deploy
cd ../rtm-api-gateway && docker compose up -d && cd ../rtm-deploy

# 3. Front web
cd ../RentaMovil/web/Front-end && docker compose up -d --build && cd ../../../rtm-deploy

# 4. Esta capa: nginx (ver "Primer certificado" abajo antes del primer arranque)
docker compose up -d
```

## DNS

Antes de cualquier certificado: en el panel de tu proveedor de dominio, crea un registro **A**
para `rentamovil.tech` y otro para `www.rentamovil.tech`, apuntando ambos al IP público del VPS.
Sin esto Certbot no puede verificar que el dominio es tuyo.

## Primer certificado (una sola vez, antes del primer `docker compose up -d` de este repo)

Certbot corre **en el VPS, no en un contenedor** — más simple para este tamaño de proyecto, y el
certificado queda en `/etc/letsencrypt` del host, que `docker-compose.yml` monta de solo lectura
dentro de nginx.

```bash
# Instala certbot en el VPS (Ubuntu/Debian)
sudo apt update && sudo apt install -y certbot

# Crea la carpeta que nginx va a servir para la verificación (webroot), y que luego
# se reutiliza para las renovaciones automáticas
mkdir -p certbot-www

# Pide el certificado con el plugin standalone (necesita el puerto 80 libre:
# nginx todavía NO está arrancado en este punto)
sudo certbot certonly --standalone \
  -d rentamovil.tech -d www.rentamovil.tech \
  --agree-tos -m tu-email@ejemplo.com --no-eff-email
```

Si todo sale bien, el certificado queda en `/etc/letsencrypt/live/rentamovil.tech/`. Recién ahora
arrancas nginx (paso 4 del orden de arranque) — como el certificado ya existe, el `nginx.conf` con
el bloque `443 ssl` arranca sin problema.

## Renovación automática (sin downtime)

El certificado de Let's Encrypt dura 90 días. `certbot` instala un timer de systemd que revisa la
renovación dos veces al día (no hace nada si todavía no está cerca de vencer), pero por defecto
usaría de nuevo el plugin `standalone` — y eso tumbaría nginx cada vez. Para que renueve sin bajar
el sitio, se le dice que use el webroot que nginx ya está sirviendo, y que recargue nginx después:

```bash
sudo certbot renew --webroot -w ./certbot-www \
  --deploy-hook "docker exec rentamovil-nginx nginx -s reload"
```

Verifica que el timer automático de certbot vaya a usar esta misma configuración:

```bash
sudo systemctl list-timers | grep certbot
```

## Verificar que todo responde

```bash
curl http://rentamovil.tech/        # debe redirigir (301) a https
curl https://rentamovil.tech/       # front web
curl https://rentamovil.tech/api/health   # health del gateway, a través de nginx
```

## App móvil (APK)

No se publica en tiendas (fuera de alcance de esta entrega). Se compila como build interno de
Android, apuntando al dominio real:

```bash
cd ../RentaMovil/app_mobile/Frontend
# EXPO_PUBLIC_API_URL=https://rentamovil.tech/api en .env de este repo
eas build --platform android --profile preview
```

El `.apk` resultante se comparte por link/QR directo. A diferencia de cuando se usaba ngrok, el
dominio ya no cambia entre reinicios, así que el `.apk` no queda atado a una URL temporal — solo
hay que recompilar si el dominio cambiara de verdad en el futuro.

## Correlación

`rtm-docs/10-devops/environments.md` (sección "Production deployment") ·
`rtm-docs/10-devops/local-setup.md` (orden de arranque completo, sin esta capa) ·
`rtm-docs/15-project-control/risks.md` (R-003 SQL Server como punto único de fallo, R-004 tiendas móviles)
