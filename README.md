# rtm-deploy

Capa de publicación para RentaMóvil: **nginx** como proxy inverso delante de todo el stack
(front web + API Gateway) y **ngrok** para exponerlo con una URL pública, sin modificar ningún
repo de servicio. Pensado para correr en una máquina Linux dedicada (servidor local), con el
mismo patrón que `docker-compose.yml` + `nginx.conf` + `ngrok` que ya validó el equipo en otro
proyecto.

## Cómo enruta nginx

El front web (`RentaMovil/web/Front-end`) ya llama a `/api/...` en su propio origen por defecto
(`httpClient.js`: `API_URL = import.meta.env.VITE_API_URL || '/api'`), igual que hace el proxy de
Vite en desarrollo. Por eso nginx solo necesita reproducir el mismo esquema de rutas:

| Ruta pública | A dónde va | Para qué |
|---|---|---|
| `/` | contenedor `web` (:4173) | Front web (build de producción) |
| `/api/*` | contenedor `api-gateway` (:8080), sin el prefijo `/api` | Todo lo que ya tiene backend real (auth, vehículos, reservas, pagos...) |
| `/mock/*` | contenedor `mock-api` (:3100), sin el prefijo `/mock` | Lo que todavía no tiene servicio real |

**La app móvil** debe apuntar su `EXPO_PUBLIC_API_URL` a `https://<tu-dominio-ngrok>/api` (no a
la raíz) — así usa exactamente el mismo `location /api/` que el front web, sin necesitar un
segundo túnel ni un dominio aparte.

## Orden de arranque (todo con la red compartida `rentamovil`)

```bash
# Una sola vez por máquina
docker network create rentamovil

# 1. Bases de datos (cada una crea/migra su schema)
cd ../rtm-iam-db && docker compose up -d && cd ../rtm-deploy
cd ../rtm-fleet-maintenance-db && docker compose up -d && cd ../rtm-deploy
cd ../rtm-booking-db && docker compose up -d && cd ../rtm-deploy
cd ../rtm-payment-billing-db && docker compose up -d && cd ../rtm-deploy

# 2. Servicios de aplicación
cd ../rtm-iam && docker compose up -d && cd ../rtm-deploy
cd ../rtm-fleet-maintenance && docker compose up -d && cd ../rtm-deploy
cd ../rtm-booking-reservation && docker compose up -d && cd ../rtm-deploy
cd ../rtm-payment-billing && docker compose up -d && cd ../rtm-deploy
cd ../rtm-api-gateway && docker compose up -d && cd ../rtm-deploy

# 3. Front web
cd ../RentaMovil/web/Front-end && docker compose up -d --build && cd ../../../rtm-deploy

# 4. Esta capa: nginx + ngrok
cp .env.example .env   # pega tu NGROK_AUTHTOKEN real
docker compose up -d
```

## Obtener la URL pública

```bash
docker compose logs ngrok | grep -i "url="
```

O entra al panel local de ngrok en `http://localhost:4040` (inspecciona requests en vivo, y ahí
mismo aparece la URL pública asignada).

> Con el plan gratuito de ngrok, la URL cambia cada vez que se reinicia el contenedor `ngrok`,
> salvo que reserves un dominio fijo en tu cuenta (dashboard de ngrok → Domains) y lo agregues al
> `command` de `docker-compose.yml` como `--url=tu-dominio.ngrok-free.dev` (igual que el ejemplo
> de referencia del equipo).

## Verificar que todo responde

```bash
curl http://localhost/              # front web
curl http://localhost/api/health    # health del gateway, a través de nginx
```

## App móvil (APK)

No se publica en tiendas (fuera de alcance de esta entrega). Se compila como build interno de
Android, apuntando a la URL pública de ngrok:

```bash
cd ../RentaMovil/app_mobile/Frontend
# EXPO_PUBLIC_API_URL=https://<tu-dominio-ngrok>/api en .env de este repo
eas build --platform android --profile preview
```

El `.apk` resultante se comparte por link/QR directo (ver riesgo `R-004` en
`rtm-docs/15-project-control/risks.md`: la URL queda fija dentro del binario, así que hay que
compilarlo después de confirmar la URL pública definitiva).

## Correlación

`rtm-docs/10-devops/environments.md` (sección "Production deployment") ·
`rtm-docs/10-devops/local-setup.md` (orden de arranque completo, sin esta capa) ·
`rtm-docs/15-project-control/risks.md` (R-003 SQL Server como punto único de fallo, R-004 tiendas móviles)
