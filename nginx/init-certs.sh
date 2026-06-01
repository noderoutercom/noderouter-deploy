#!/usr/bin/env bash
# init-certs.sh — one-time Let's Encrypt certificate bootstrap (PRODUCTION only).
#
# Requires:
#   - A public domain with a DNS A record pointing to this server's IP
#   - Ports 80 and 443 open and reachable from the internet
#   - nginx/.env with DOMAIN_NAME and CERTBOT_EMAIL set
#
# Run ONCE before starting the nginx stack:
#   bash init-certs.sh
#   docker compose --env-file .env up -d

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: ${ENV_FILE} not found."
  echo "       Copy .env.example to .env and fill in DOMAIN_NAME and CERTBOT_EMAIL."
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${DOMAIN_NAME:?DOMAIN_NAME must be set in .env}"
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL must be set in .env}"
STAGING="${CERTBOT_STAGING:-0}"

COMPOSE="docker compose -f ${COMPOSE_FILE} --env-file ${ENV_FILE}"

echo "==> Creating temporary self-signed certificate for ${DOMAIN_NAME} ..."
$COMPOSE run --rm --entrypoint "" certbot \
  /bin/sh -c "
    mkdir -p /etc/letsencrypt/live/${DOMAIN_NAME} &&
    openssl req -x509 -nodes -newkey rsa:4096 -days 1 \
      -keyout /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem \
      -out    /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem \
      -subj   '/CN=localhost' 2>/dev/null
  "

echo "==> Starting nginx with temporary certificate ..."
$COMPOSE up --force-recreate -d nginx
echo "    Waiting for nginx to be ready ..."
sleep 5

echo "==> Removing temporary certificate ..."
$COMPOSE run --rm --entrypoint "" certbot \
  /bin/sh -c "
    rm -rf /etc/letsencrypt/live/${DOMAIN_NAME} \
           /etc/letsencrypt/archive/${DOMAIN_NAME} \
           /etc/letsencrypt/renewal/${DOMAIN_NAME}.conf
  "

STAGING_FLAG=""
if [ "$STAGING" = "1" ]; then
  STAGING_FLAG="--staging"
  echo "==> Using Let's Encrypt STAGING server (set CERTBOT_STAGING=0 for production)"
fi

echo "==> Requesting Let's Encrypt certificate for ${DOMAIN_NAME} ..."
$COMPOSE run --rm --entrypoint "" certbot \
  certbot certonly --webroot \
    --webroot-path /var/www/certbot \
    --email "${CERTBOT_EMAIL}" \
    --agree-tos \
    --no-eff-email \
    ${STAGING_FLAG} \
    -d "${DOMAIN_NAME}"

echo "==> Reloading nginx with real certificate ..."
$COMPOSE exec nginx nginx -s reload

echo ""
echo "Done! Certificate issued for ${DOMAIN_NAME}."
echo ""
echo "Start the full nginx stack (nginx + certbot renewal daemon):"
echo "  docker compose -f nginx/docker-compose.yml --env-file nginx/.env up -d"
