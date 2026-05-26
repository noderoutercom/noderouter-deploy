#!/usr/bin/env bash
# =============================================================================
# Noderouter Env Updater
# Update one or more env vars in a running service's .env file and restart
# the container to pick up the changes.
#
# Usage:
#   bash update-env.sh <service> [KEY=VALUE ...]
#
# Services:
#   postgres          →  postgres/.env
#   core              →  core/.env
#   runner.<name>     →  runner/.env.<name>   (e.g. runner.node1)
#
# Examples:
#   bash update-env.sh core ADMIN_PASSWORD=NewPass123
#   bash update-env.sh core JWT_SECRET=$(openssl rand -hex 32) PAIRING_KEY=$(openssl rand -hex 32)
#   bash update-env.sh runner.node1 ASYNC_MAX_WORKERS=8 SYNC_MAX_WORKERS=16
#   bash update-env.sh postgres          # no KEY=VALUE → opens file in $EDITOR
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

BASE_URL="https://raw.githubusercontent.com/noderoutercom/noderouter-deploy/main"

if [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
else
  DEPLOY_DIR="$(pwd)"
fi

info()    { echo -e "${CYAN}ℹ  $1${NC}"; }
success() { echo -e "${GREEN}✓  $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠  $1${NC}"; }
err()     { echo -e "${RED}✗  $1${NC}" >&2; exit 1; }

trap 'echo -e "\n${RED}✗ Update aborted — check the error above.${NC}" >&2' ERR

# wait_healthy "container" [max_seconds]
wait_healthy() {
  local container="$1" max_wait="${2:-60}" elapsed=0 status
  info "Waiting for ${container} to become healthy…"
  until status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null) \
        && [ "$status" = "healthy" ]; do
    sleep 3; elapsed=$((elapsed + 3))
    if [ "$elapsed" -ge "$max_wait" ]; then
      err "Timeout — ${container} did not become healthy within ${max_wait}s. Check: docker logs ${container}"
    fi
    info "  Still waiting… (${elapsed}s / ${max_wait}s)"
  done
  success "${container} is healthy"
}

# -----------------------------------------------------------------------------
# Resolve service → env file + compose file + project name
# -----------------------------------------------------------------------------

SERVICE="${1:-}"
[ -z "$SERVICE" ] && {
  echo -e "${BOLD}Usage:${NC} bash update-env.sh <service> [KEY=VALUE ...]" >&2
  echo "" >&2
  echo "  Services: postgres | core | runner.<name>" >&2
  echo "" >&2
  echo "  Examples:" >&2
  echo "    bash update-env.sh core ADMIN_PASSWORD=NewPass" >&2
  echo "    bash update-env.sh runner.node1 ASYNC_MAX_WORKERS=8" >&2
  echo "    bash update-env.sh postgres          # opens in \$EDITOR" >&2
  exit 1
}
shift   # remaining args are KEY=VALUE pairs (may be empty)

case "$SERVICE" in
  postgres)
    ENV_FILE="${DEPLOY_DIR}/postgres/.env"
    COMPOSE_FILE="${DEPLOY_DIR}/postgres/docker-compose.yml"
    PROJECT="noderouter-postgres"
    CONTAINER="noderouter-postgres"
    HAS_HEALTHCHECK=true
    ;;
  core)
    ENV_FILE="${DEPLOY_DIR}/core/.env"
    COMPOSE_FILE="${DEPLOY_DIR}/core/docker-compose.yml"
    PROJECT="noderouter-core"
    CONTAINER="noderouter-core"
    HAS_HEALTHCHECK=true
    ;;
  runner.*)
    RUNNER_NAME="${SERVICE#runner.}"
    ENV_FILE="${DEPLOY_DIR}/runner/.env.${RUNNER_NAME}"
    COMPOSE_FILE="${DEPLOY_DIR}/runner/docker-compose.yml"
    PROJECT="noderouter-runner-${RUNNER_NAME}"
    CONTAINER="noderouter-runner-${RUNNER_NAME}"
    HAS_HEALTHCHECK=false
    ;;
  *)
    err "Unknown service '${SERVICE}'. Valid: postgres | core | runner.<name>"
    ;;
esac

[ -f "$ENV_FILE" ] || err "Env file not found: ${ENV_FILE}\n  Run setup.sh first to create it."

# -----------------------------------------------------------------------------
# Backup
# -----------------------------------------------------------------------------

BACKUP="${ENV_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$ENV_FILE" "$BACKUP"
info "Backup saved: ${BACKUP}"

# -----------------------------------------------------------------------------
# Apply changes — interactive (editor) or non-interactive (KEY=VALUE args)
# -----------------------------------------------------------------------------

echo
if [ $# -eq 0 ]; then
  # No KEY=VALUE args — open in $EDITOR for freeform editing
  EDITOR="${EDITOR:-vi}"
  warn "No KEY=VALUE arguments given — opening ${ENV_FILE} in ${EDITOR}."
  warn "Save and quit the editor to continue."
  echo
  "$EDITOR" "$ENV_FILE" </dev/tty >/dev/tty
  success "File saved."
else
  # Apply each KEY=VALUE pair
  for pair in "$@"; do
    # Validate format
    [[ "$pair" == *=* ]] || err "Bad argument '${pair}' — expected KEY=VALUE format."
    KEY="${pair%%=*}"
    VAL="${pair#*=}"

    if grep -q "^${KEY}=" "$ENV_FILE"; then
      # Portable in-place sed (works on Linux, macOS, Git Bash)
      sed -i.tmp "s|^${KEY}=.*|${KEY}=${VAL}|" "$ENV_FILE"
      rm -f "${ENV_FILE}.tmp"
      success "Updated: ${KEY}"
    else
      echo "${KEY}=${VAL}" >> "$ENV_FILE"
      success "Added:   ${KEY}"
    fi
  done
fi

# -----------------------------------------------------------------------------
# Show diff so the operator can confirm what changed
# -----------------------------------------------------------------------------

echo
info "Changes applied:"
diff "$BACKUP" "$ENV_FILE" \
  | grep -E '^[<>]' \
  | sed 's/^< /  old: /; s/^> /  new: /' \
  || true   # diff exits 1 when files differ; don't abort

# -----------------------------------------------------------------------------
# Restart the container to pick up the new env
# -----------------------------------------------------------------------------

echo
if [ -t 0 ]; then
  # Interactive terminal — ask before restarting
  read -r -p "  Restart ${SERVICE} now to apply changes? [Y/n]: " reply </dev/tty
  reply="${reply:-Y}"
  [[ "$reply" =~ ^[Yy] ]] || { info "Restart skipped — changes are saved to ${ENV_FILE}."; exit 0; }
fi

warn "Restarting ${SERVICE}…"

if [ "$SERVICE" = "runner."* ] || [[ "$SERVICE" == runner.* ]]; then
  RUNNER_NAME="${SERVICE#runner.}"
  RUNNER_NAME="$RUNNER_NAME" docker compose \
    -f "$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    --project-name "$PROJECT" \
    up -d --pull always --force-recreate
else
  docker compose \
    -f "$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    --project-name "$PROJECT" \
    up -d --pull always --force-recreate
fi

# Wait for healthcheck if the service has one
if [ "$HAS_HEALTHCHECK" = "true" ]; then
  wait_healthy "$CONTAINER" 60
fi

echo
success "${SERVICE} is running with the updated env."
info "Tail logs: docker logs -f ${CONTAINER}"
