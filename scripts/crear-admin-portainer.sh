#!/usr/bin/env bash
# =============================================================================
# crear-admin-portainer.sh
# Crea el usuario administrador de Portainer CE de forma reproducible, sin
# depender de que alguien complete el formulario en el navegador.
#
# En Portainer 2.4x el alta del admin ya NO se puede hacer con la variable
# PORTAINER_ADMIN_PASSWORD: el panel exige el "setup token" que genera en el
# primer arranque. Este script lo extrae de los logs y lo usa contra la API.
#
#   bash scripts/crear-admin-portainer.sh
#
# Variables (opcionales, con estos valores por defecto):
#   CONTAINER               rentamovil-portainer
#   URL                     https://127.0.0.1:9443
#   PORTAINER_ADMIN_USER    admin
#   PORTAINER_ADMIN_PASSWORD  (obligatoria; se lee del .env si no está en el entorno)
# =============================================================================
set -euo pipefail

CONTAINER="${CONTAINER:-rentamovil-portainer}"
URL="${URL:-https://127.0.0.1:9443}"
USERNAME="${PORTAINER_ADMIN_USER:-admin}"

cd "$(dirname "$0")/.."   # raíz del repo rtm-deploy, para leer el .env

# La contraseña sale del entorno o del .env del repo (que nunca se versiona).
if [ -z "${PORTAINER_ADMIN_PASSWORD:-}" ] && [ -f .env ]; then
  PORTAINER_ADMIN_PASSWORD="$(grep -E '^PORTAINER_ADMIN_PASSWORD=' .env | tail -1 | cut -d= -f2-)"
fi
if [ -z "${PORTAINER_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: define PORTAINER_ADMIN_PASSWORD en el .env del repo o en el entorno." >&2
  exit 1
fi
if [ "${#PORTAINER_ADMIN_PASSWORD}" -lt 12 ]; then
  echo "ERROR: Portainer exige una contraseña de mínimo 12 caracteres." >&2
  exit 1
fi

# Escapa lo mínimo para armar JSON válido sin depender de jq.
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
JSON="$(printf '{"username":"%s","password":"%s"}' "$(json_escape "$USERNAME")" "$(json_escape "$PORTAINER_ADMIN_PASSWORD")")"

# --- 1. El panel ya está arriba? ------------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERROR: el contenedor '$CONTAINER' no está corriendo." >&2
  echo "       Arráncalo con: docker compose -f docker-compose.portainer.yml up -d" >&2
  exit 1
fi

# --- 2. Setup token: sólo se genera en el primer arranque ------------------------
TOKEN="$(docker logs "$CONTAINER" 2>&1 | grep -o 'setup_token=[a-f0-9]\+' | tail -1 | cut -d= -f2 || true)"

if [ -n "$TOKEN" ]; then
  echo "-> Se encontró el setup token en los logs. Creando el administrador..."
  RESP="$(curl -k -sS -X POST "$URL/api/users/admin/init" \
            -H "Content-Type: application/json" \
            -H "X-Setup-Token: $TOKEN" \
            -d "$JSON" || true)"
  case "$RESP" in
    *'"Id"'*) echo "   Administrador '$USERNAME' creado." ;;
    *)       echo "   La API respondió: ${RESP:-<sin cuerpo>}" ;;
  esac
else
  echo "-> No hay setup token en los logs: el administrador ya fue creado antes."
  echo "   (El token sólo se emite en el primer arranque.)"
fi

# --- 3. Verificación: el login tiene que funcionar ------------------------------
echo "-> Verificando el inicio de sesión..."
LOGIN="$(curl -k -sS -X POST "$URL/api/auth" \
          -H "Content-Type: application/json" \
          -d "$JSON" || true)"

case "$LOGIN" in
  *'"jwt"'*)
    echo "OK: Portainer responde y las credenciales son correctas."
    echo
    echo "Panel:  https://admin.rentamovil.tech  (a través de nginx)"
    echo "Directo: $URL  (sólo desde el host o por túnel SSH)"
    ;;
  *)
    echo "ERROR: el inicio de sesión falló." >&2
    echo "       Respuesta: ${LOGIN:-<sin cuerpo>}" >&2
    echo "       Si el panel se acaba de instalar, revisa:" >&2
    echo "       docker logs $CONTAINER | grep setup_token" >&2
    exit 1
    ;;
esac
