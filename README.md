# rtm-deploy

Capa de publicación para RentaMóvil: **nginx** como proxy inverso delante de todo el stack
(front web + API Gateway) con **HTTPS real** sobre `rentamovil.tech` (Let's Encrypt), y
**Portainer CE** como panel de administración de contenedores. Sin modificar ningún repo de
servicio. Pensado para correr en el VPS de producción.

## Cómo enruta nginx

El front web (`rtm-frontend/web/Front-end`) ya llama a `/api/...` en su propio origen por defecto
(`httpClient.js`: `API_URL = import.meta.env.VITE_API_URL || '/api'`), igual que hace el proxy de
Vite en desarrollo. Por eso nginx solo necesita reproducir el mismo esquema de rutas:

| Ruta pública | A dónde va | Para qué |
|---|---|---|
| `/` | contenedor `web` (:4173) | Front web (build de producción) |
| `/api/*` | contenedor `api-gateway` (:8080), sin el prefijo `/api` | Todo (auth, vehículos, reservas, pagos, GPS...) — ya no hay mock, todos los servicios existen |
| `admin.rentamovil.tech` | contenedor `portainer` (:9000) | Panel de administración de contenedores (ver "Portainer CE" abajo) |

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
cd ../rtm-frontend/web/Front-end && docker compose up -d --build && cd ../../../rtm-deploy

# 4. Esta capa: nginx (ver "Primer certificado" abajo antes del primer arranque)
docker compose up -d

# 5. Portainer CE (opcional, ver la sección "Portainer CE")
docker compose -f docker-compose.portainer.yml up -d
bash scripts/crear-admin-portainer.sh   # da de alta el usuario administrador
```

## DNS

Antes de cualquier certificado: en el panel de tu proveedor de dominio, crea un registro **A**
para `rentamovil.tech` y otro para `www.rentamovil.tech`, apuntando ambos al IP público del VPS.
Sin esto Certbot no puede verificar que el dominio es tuyo.

Si vas a instalar Portainer, añade además un registro **A** para `admin.rentamovil.tech` con el
mismo IP.

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

## Portainer CE (panel de administración)

Portainer **no** se instala junto a nginx en el mismo `docker-compose.yml`, sino en
`docker-compose.portainer.yml`. A propósito: la capa de publicación es lo que sostiene el sitio en
producción y no debe depender de que el panel levante bien. Los dos archivos comparten la red
externa `rentamovil`, así que nginx resuelve el alias `portainer` igual que resuelve `api-gateway`
o `web`.

### 1. Preparar la contraseña

```bash
cp .env.example .env
# Edita .env y pon una contraseña de mínimo 12 caracteres (requisito de Portainer)
```

`.env` está en `.gitignore`: la contraseña nunca se sube al repositorio.

### 2. Levantar el panel

```bash
docker compose -f docker-compose.portainer.yml up -d
```

### 3. Crear el usuario administrador

En Portainer 2.4x el alta del administrador **ya no se puede hacer con la variable
`PORTAINER_ADMIN_PASSWORD`**: el panel genera un *setup token* en el primer arranque y lo exige
para crear el usuario. El script lo resuelve:

```bash
bash scripts/crear-admin-portainer.sh
```

El script lee el token de `docker logs rentamovil-portainer`, da de alta al administrador contra
`/api/users/admin/init` y verifica que el login funciona. Es idempotente: si el usuario ya existe,
lo detecta y sólo verifica. Para cambiar la contraseña después, usar la opción "Reset password" del
propio panel.

Si prefieres hacerlo a mano, el token está en los logs:

```bash
docker logs rentamovil-portainer | grep setup_token
```

y se pega en la pantalla de setup del navegador.

### 4. Certificado del subdominio `admin.rentamovil.tech`

A diferencia del certificado principal, este se pide **con nginx ya arrancado**, usando el plugin
`webroot` (nginx ya sirve `/.well-known/acme-challenge/`, así que no hay que parar el sitio ni
usar el puerto 80 libre):

```bash
sudo certbot certonly --webroot -w ./certbot-www \
  -d admin.rentamovil.tech \
  --agree-tos -m tu-email@ejemplo.com --no-eff-email
```

Queda en `/etc/letsencrypt/live/admin.rentamovil.tech/`, que es exactamente lo que espera el
`server` block de `admin.rentamovil.tech` en `nginx/nginx.conf`. El `certbot renew` de arriba
renueva **las dos** lineages (la principal y la del panel) con el mismo `--webroot`.

Después recarga nginx:

```bash
docker exec rentamovil-nginx nginx -s reload
```

### 5. Acceso

| Vía | URL | Cuándo usarla |
|---|---|---|
| Subdominio público | `https://admin.rentamovil.tech` | Desde cualquier navegador, con TLS válido |
| Túnel SSH | `ssh -L 9443:127.0.0.1:9443 root@<IP_DEL_VPS>` → `https://localhost:9443` | Si prefieres no exponer el subdominio (el certificado del 9443 es autofirmado: el navegador advertirá) |

El puerto 9443 del host está atado a `127.0.0.1`, así que **no es alcanzable desde Internet**.
El único camino público es el subdominio, con TLS de Let's Encrypt.

### 6. Seguridad

Portainer monta `/var/run/docker.sock`, que es **equivalente a root en el servidor**: quien entre
al panel puede operar todos los contenedores. Mitigaciones aplicadas aquí:

- El puerto real del panel no está publicado en la IP pública (sólo `127.0.0.1`).
- El acceso público es por HTTPS con certificado válido, en un subdominio aparte.
- La contraseña del administrador se genera en el VPS y vive en `.env` (ignorado por git) o en el
  hash guardado en el volumen `portainer_data`.
- El *setup token* se genera en el servidor y se consume al crear el administrador: nadie puede
  dar de alta un admin remoto sin acceso al servidor.

Si el panel no se necesita en producción, simplemente no se levanta ese compose: la plataforma
sigue funcionando con Docker CLI.

### 7. Detalles de la imagen (verificados contra `portainer/portainer-ce:lts`, 2.45.x)

- La imagen **no tiene shell** (`/bin/sh` no existe), así que no se puede `docker exec ... sh` ni
  usar un healthcheck de tipo `CMD-SHELL`. El healthcheck del compose usa forma `CMD`:
  `/portainer --version`.
- El flag `--host` **no** es la dirección de escucha, es el endpoint de la API de Docker (para el
  agente) y hace fallar el arranque si se le pasa una IP. Para escuchar se usa `--bind` (HTTP,
  9000) y `--bind-https` (HTTPS, 9443).
- `--trusted-origins` se rellena con el subdominio del panel porque entra por un origen distinto
  al del sitio y la protección CSRF del panel lo valida.

### 8. Respaldo

Los datos del panel (usuarios, organizaciones, endpoints, tokens) viven en el volumen
`portainer_data`:

```bash
docker run --rm \
  -v rtm-deploy_portainer_data:/data:ro \
  -v "$PWD":/backup \
  alpine tar czf /backup/portainer_data-$(date +%Y%m%d-%H%M).tar.gz -C /data .
```

## Verificar que todo responde

```bash
curl http://rentamovil.tech/        # debe redirigir (301) a https
curl https://rentamovil.tech/       # front web
curl https://rentamovil.tech/api/health   # health del gateway, a través de nginx
curl https://admin.rentamovil.tech/api/system/status   # estado del panel (200)
```

## App móvil (APK)

No se publica en tiendas (fuera de alcance de esta entrega). Se compila como build interno de
Android, apuntando al dominio real:

```bash
cd ../rtm-frontend/app_mobile/Frontend
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
