#!/usr/bin/env bash
# init-self-signed.sh — generate a self-signed certificate for LOCAL DEV.
#
# Does NOT require a public domain or internet access.
# Browsers will show a security warning for self-signed certs.
# To suppress the warning: import the generated fullchain.pem into your OS/browser trust store.
#
# Run ONCE before starting the nginx stack:
#   bash init-self-signed.sh
#   docker compose --env-file .env up -d

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: ${ENV_FILE} not found."
  echo "       Copy .env.example to .env and fill in DOMAIN_NAME."
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${DOMAIN_NAME:?DOMAIN_NAME must be set in .env}"

echo "==> Generating self-signed certificate for ${DOMAIN_NAME} (3650-day validity) ..."

docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
  run --rm --entrypoint "" certbot \
  /bin/sh -c "
    mkdir -p /etc/letsencrypt/live/${DOMAIN_NAME} &&
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem \
      -out    /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem \
      -subj   '/CN=${DOMAIN_NAME}' 2>/dev/null
  "

echo ""
echo "Done! Self-signed certificate created for ${DOMAIN_NAME}."
echo ""
echo "Start the nginx stack:"
echo "  docker compose -f nginx/docker-compose.yml --env-file nginx/.env up -d"
echo ""
echo "NOTE: Browsers will show a security warning. To trust the cert locally:"
echo "  1. Copy the cert from the Docker volume:"
echo "     docker run --rm -v noderouter-nginx_certbot_conf:/certs alpine \\"
echo "       cat /certs/live/${DOMAIN_NAME}/fullchain.pem > fullchain.pem"
echo "  2. Import fullchain.pem into your OS/browser certificate trust store."
