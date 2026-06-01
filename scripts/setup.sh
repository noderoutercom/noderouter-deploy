#!/usr/bin/env bash
# =============================================================================
# Noderouter Interactive Deploy Setup
# Generates .env files for each service and starts the containers.
# Usage: bash setup.sh
# =============================================================================
set -euo pipefail
trap 'echo -e "\n${RED}✗ Deploy aborted — check the error above.${NC}" >&2' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# Base URL for downloading compose/example files when running via curl pipe
BASE_URL="https://raw.githubusercontent.com/noderoutercom/noderouter-deploy/main"

# When run as a file (cloned repo):  DEPLOY_DIR = parent of scripts/
# When piped via curl:               DEPLOY_DIR = current working directory
if [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
else
  DEPLOY_DIR="$(pwd)"
fi

header()  { echo -e "\n${BOLD}${BLUE}━━━ $1 ━━━${NC}"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $1${NC}"; }
info()    { echo -e "${CYAN}ℹ $1${NC}"; }
err()     { echo -e "${RED}✗ $1${NC}" >&2; }

# -----------------------------------------------------------------------------
# Prompt helpers
# -----------------------------------------------------------------------------

# ask "Label" ["default"]  →  prints value to stdout
ask() {
  local label="$1" default="${2:-}" val
  while true; do
    if [ -n "$default" ]; then
      read -r -p "  ${label} [${default}]: " val </dev/tty
      val="${val:-$default}"
    else
      read -r -p "  ${label}: " val </dev/tty
    fi
    [ -n "$val" ] && break
    echo -e "  ${RED}Required — cannot be blank.${NC}" >&2
  done
  echo "$val"
}

# ask_secret "Label" [pregenerated]  →  shows value, allows override
ask_secret() {
  local label="$1" generated="${2:-$(gen_secret)}"
  echo -e "  ${CYAN}Auto-generated:${NC} ${generated}" >&2
  read -r -p "  ${label} [press Enter to use above, or type your own]: " val </dev/tty
  echo "${val:-$generated}"
}

# ask_yn "Label" ["y"|"n"]  →  returns 0 for yes, 1 for no
# NOTE: never call this bare with set -e; always use inside `if`.
ask_yn() {
  local label="$1" default="${2:-y}" reply
  read -r -p "  ${label} [${default}]: " reply </dev/tty
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n'
  fi
}

# wait_healthy "container-name" [max_seconds]
# Polls the Docker healthcheck status until healthy or timeout.
wait_healthy() {
  local container="$1" max_wait="${2:-60}" elapsed=0 status
  info "Waiting for ${container} to become healthy…"
  until status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null) \
        && [ "$status" = "healthy" ]; do
    sleep 3; elapsed=$((elapsed + 3))
    if [ "$elapsed" -ge "$max_wait" ]; then
      err "Timeout — ${container} did not become healthy within ${max_wait}s."
      echo "  → Check logs: docker logs ${container}" >&2
      exit 1
    fi
    info "  Still waiting… (${elapsed}s / ${max_wait}s)"
  done
  success "${container} is healthy"
}

# ensure_compose_files — downloads docker-compose.yml + .env.example from GitHub
# if they are missing (i.e. running via curl pipe rather than a cloned repo).
ensure_compose_files() {
  local services=(postgres core nginx runner)
  local needed=false
  for svc in "${services[@]}"; do
    [ -f "${DEPLOY_DIR}/${svc}/docker-compose.yml" ] || { needed=true; break; }
  done
  [ "$needed" = "false" ] && return 0

  info "Compose files not found locally — downloading from GitHub…"
  for svc in "${services[@]}"; do
    local dir="${DEPLOY_DIR}/${svc}"
    mkdir -p "$dir"
    if [ ! -f "${dir}/docker-compose.yml" ]; then
      curl -fsSL "${BASE_URL}/${svc}/docker-compose.yml" -o "${dir}/docker-compose.yml" \
        || { err "Failed to download ${svc}/docker-compose.yml"; exit 1; }
      success "Downloaded ${svc}/docker-compose.yml"
    fi
    if [ ! -f "${dir}/.env.example" ]; then
      curl -fsSL "${BASE_URL}/${svc}/.env.example" -o "${dir}/.env.example" 2>/dev/null || true
    fi
  done
  # nginx also needs its template and map files
  local nginx_dir="${DEPLOY_DIR}/nginx"
  mkdir -p "${nginx_dir}/templates" "${nginx_dir}/conf.d"
  for f in templates/noderouter.conf.template conf.d/map.conf init-certs.sh init-self-signed.sh; do
    if [ ! -f "${nginx_dir}/${f}" ]; then
      curl -fsSL "${BASE_URL}/nginx/${f}" -o "${nginx_dir}/${f}" 2>/dev/null || true
    fi
  done
  chmod +x "${nginx_dir}/init-certs.sh" "${nginx_dir}/init-self-signed.sh" 2>/dev/null || true
}

# ensure_gitignored — adds deploy .env patterns to .gitignore to prevent secret commits
ensure_gitignored() {
  local gitroot
  gitroot=$(git -C "$DEPLOY_DIR" rev-parse --show-toplevel 2>/dev/null) || return 0
  local gitignore="${gitroot}/.gitignore"
  local changed=false

  for pattern in "deploy/**/.env" "deploy/**/.env.*"; do
    if ! grep -qxF "$pattern" "$gitignore" 2>/dev/null; then
      echo "$pattern" >> "$gitignore"
      changed=true
    fi
  done

  if [ "$changed" = "true" ]; then
    warn ".env patterns added to .gitignore — commit .gitignore to prevent accidental secret commits."
  fi
}

# -----------------------------------------------------------------------------
# Dependency check
# -----------------------------------------------------------------------------

resolve_docker() {
  # 1. Already in PATH — nothing to do.
  if command -v docker >/dev/null 2>&1; then return; fi

  # 2. Probe known Docker Desktop install locations for Git Bash / WSL.
  #    Git Bash maps C:\ as /c/, so we check both Windows-mapped and native paths.
  local candidates=(
    "/c/Program Files/Docker/Docker/resources/bin"
    "/c/ProgramData/DockerDesktop/version-bin"
    "/usr/bin"
    "/usr/local/bin"
  )
  local dir
  for dir in "${candidates[@]}"; do
    if [ -x "${dir}/docker" ] || [ -x "${dir}/docker.exe" ]; then
      export PATH="${dir}:${PATH}"
      info "Docker found at ${dir} — added to session PATH."
      return
    fi
  done

  # 3. Genuinely not found anywhere.
  err "Docker binary not found in PATH."
  echo "" >&2
  echo "  Likely fixes:" >&2
  echo "  • Close this terminal, reopen it, then try again" >&2
  echo "    (Docker Desktop updates the Windows PATH at install time;" >&2
  echo "     the current shell session won't see it until a new window is opened)" >&2
  echo "  • WSL — open Docker Desktop → Settings → Resources → WSL Integration," >&2
  echo "    enable your distro, then restart the terminal" >&2
  echo "  • Not yet installed — https://docs.docker.com/desktop/install/windows/" >&2
  exit 1
}

check_deps() {
  # ── Step 1: locate the docker binary ────────────────────────────────────────
  resolve_docker   # exports PATH fix or exits

  # ── Step 2: binary sanity check (client-only, no daemon needed) ─────────────
  if ! docker --version >/dev/null 2>&1; then
    err "Docker binary found but 'docker --version' failed."
    echo "  → Try reinstalling Docker Desktop." >&2
    exit 1
  fi

  # ── Step 3: is the daemon running? ──────────────────────────────────────────
  # `docker info` requires the daemon; failure means it is not yet started.
  if ! docker info >/dev/null 2>&1; then
    err "Docker daemon is not running (binary is OK)."
    echo "" >&2
    echo "  → Start Docker Desktop from the Start Menu (or system-tray icon)" >&2
    echo "    and wait for the whale icon to stop animating, then try again." >&2
    exit 1
  fi

  # ── Step 4: compose v2 ──────────────────────────────────────────────────────
  if ! docker compose version >/dev/null 2>&1; then
    err "'docker compose' v2 not found."
    echo "  → Docker Desktop bundles Compose v2 automatically." >&2
    echo "    Engine-only install: https://docs.docker.com/compose/install/" >&2
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# Service setup functions
# -----------------------------------------------------------------------------

setup_postgres() {
  local env_file="${DEPLOY_DIR}/postgres/.env"
  if [ -f "$env_file" ]; then
    warn "postgres/.env already exists — skipping (delete it to reconfigure)"
    return
  fi

  header "PostgreSQL"
  echo
  info "Bundled:  runs postgres in Docker on the same noderouter network."
  info "          Core and runner connect to it as 'noderouter-postgres' — no URL config needed."
  info "External: skip this and provide your own DATABASE_URL when setting up core and runner."
  echo
  if ! ask_yn "Deploy bundled PostgreSQL container?"; then
    info "Skipped — enter your external DATABASE_URL when prompted during core and runner setup."
    return
  fi

  echo
  info "Bind address:"
  echo "  0.0.0.0   → all interfaces (needed when core/runner are on other hosts)"
  echo "  127.0.0.1 → localhost only (if core/runner are on the same host)"

  PG_PORT=$(ask "POSTGRES_PORT" "5432")
  PG_USER=$(ask "POSTGRES_USER" "noderouter")
  PG_DB=$(ask "POSTGRES_DB" "noderouter")

  # Construct DATABASE_URL once — reused as the default in setup_core and setup_runner
  BUNDLED_DATABASE_URL="postgresql://${PG_USER}:${PG_PASS}@noderouter-postgres:${PG_PORT}/${PG_DB}?sslmode=disable"

  mkdir -p "${DEPLOY_DIR}/postgres"
  cat > "$env_file" <<EOF
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=${PG_DB}
EOF
  success "postgres/.env written"
}

setup_core() {
  local env_file="${DEPLOY_DIR}/core/.env"
  if [ -f "$env_file" ]; then
    warn "core/.env already exists — skipping (delete it to reconfigure)"
    return
  fi

  header "Noderouter Core"

  echo
  info "Docker image to pull from Docker Hub."
  local core_image
  core_image=$(ask "CORE_IMAGE" "06042013/noderouter-core:latest")

  echo
  info "DATABASE_URL — the PostgreSQL DSN core will connect to."

  local db_url core_port bind_addr
  db_url=$(ask "DATABASE_URL" "${BUNDLED_DATABASE_URL:-}")
  CORE_DATABASE_URL="$db_url"
  core_port=$(ask "CORE_PORT (host port)" "3000")
  CORE_PORT_VAL="$core_port"

  # Bind to localhost only when nginx sits in front; otherwise expose on all interfaces.
  if [ "${USE_NGINX:-false}" = "true" ]; then
    bind_addr="127.0.0.1"
    info "CORE_BIND_ADDR set to 127.0.0.1 (nginx is in front — port ${core_port} not exposed publicly)"
  else
    bind_addr="0.0.0.0"
  fi

  mkdir -p "${DEPLOY_DIR}/core"
  cat > "$env_file" <<EOF
CORE_IMAGE=${core_image}
CORE_PORT=${core_port}
CORE_BIND_ADDR=${bind_addr}
APP_ENV=production
DATABASE_URL=${db_url}
JWT_SECRET=${JWT_SECRET}
RUNNER_SECRET=${RUNNER_SECRET}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF
  success "core/.env written"
}

setup_nginx() {
  local env_file="${DEPLOY_DIR}/nginx/.env"
  if [ -f "$env_file" ]; then
    warn "nginx/.env already exists — skipping (delete it to reconfigure)"
    # Still read NGINX_DOMAIN for runner default
    NGINX_DOMAIN=$(grep '^DOMAIN_NAME=' "$env_file" | cut -d= -f2) || true
    return
  fi

  header "nginx HTTPS"

  echo
  info "Domain name that nginx will serve (e.g. core.example.com)."
  info "Make sure the DNS A record points to this server's IP before issuing a certificate."
  NGINX_DOMAIN=$(ask "DOMAIN_NAME")

  local certbot_email certbot_staging="0"
  echo
  info "Certificate type:"
  echo "  1) Self-signed  — local dev, no internet needed, browser shows a warning"
  echo "  2) Let's Encrypt — production, requires a public domain reachable on port 80"
  local cert_choice
  cert_choice=$(ask "Choose [1/2]" "1")

  if [ "$cert_choice" = "2" ]; then
    certbot_email=$(ask "CERTBOT_EMAIL (Let's Encrypt account)")
    if ask_yn "Use Let's Encrypt staging CA? (safe for testing — avoids rate limits)" "n"; then
      certbot_staging="1"
    fi
  fi

  mkdir -p "${DEPLOY_DIR}/nginx"
  cat > "$env_file" <<EOF
DOMAIN_NAME=${NGINX_DOMAIN}
CERTBOT_EMAIL=${certbot_email:-}
CERTBOT_STAGING=${certbot_staging}
EOF
  success "nginx/.env written"

  # Store cert type for deploy step
  NGINX_CERT_TYPE="$cert_choice"
}

setup_runner() {
  local runner_name
  runner_name=$(ask "Runner name (unique per host)" "node1")
  local env_file="${DEPLOY_DIR}/runner/.env.${runner_name}"

  if [ -f "$env_file" ]; then
    warn "runner/.env.${runner_name} already exists — skipping (delete it to reconfigure)"
    return
  fi

  header "Runner — ${runner_name}"

  echo
  info "Docker image to pull from Docker Hub."
  local runner_image
  runner_image=$(ask "RUNNER_IMAGE" "06042013/noderouter-runner:latest")

  local core_ws_url="ws://noderouter-core:3000"
  local db_url runner_secret async_workers sync_workers

  local db_url="${CORE_DATABASE_URL:-${BUNDLED_DATABASE_URL:-}}"

  echo
  runner_secret=$(ask "RUNNER_SECRET" "${RUNNER_SECRET:-}")

  async_workers=$(ask "ASYNC_MAX_WORKERS" "4")
  sync_workers=$(ask "SYNC_MAX_WORKERS" "8")

  mkdir -p "${DEPLOY_DIR}/runner"
  cat > "$env_file" <<EOF
RUNNER_IMAGE=${runner_image}
RUNNER_NAME=${runner_name}
CORE_WS_URL=${core_ws_url}
DATABASE_URL=${db_url}
RUNNER_SECRET=${runner_secret}
NODE_ID=
ASYNC_MAX_WORKERS=${async_workers}
SYNC_MAX_WORKERS=${sync_workers}
EOF
  success "runner/.env.${runner_name} written"
}

# -----------------------------------------------------------------------------
# Deploy helpers
# -----------------------------------------------------------------------------

print_summary() {
  local base_url="$1"
  local W=54

  local sep; sep=$(printf '═%.0s' $(seq 1 $W))

  row() {
    local txt="${1:-}"
    local pad=$(( W - ${#txt} - 2 ))
    [ $pad -lt 0 ] && pad=0
    printf "${BOLD}${CYAN}  ║${NC} %-s%${pad}s ${BOLD}${CYAN}║${NC}\n" "$txt" ""
  }

  echo -e ""
  echo -e "${BOLD}${CYAN}  ╔${sep}╗${NC}"
  row ""
  row "  ${GREEN}✓${CYAN}  Noderouter is up and running"
  row ""
  row "  Web UI   →  ${NC}${BOLD}${base_url}${CYAN}"
  row "  Admin    →  ${NC}${BOLD}${base_url}/admin${CYAN}"
  row ""
  echo -e "${BOLD}${CYAN}  ╚${sep}╝${NC}"
  echo -e ""

  if [ -n "${ADMIN_PASSWORD:-}" ] || [ -n "${RUNNER_SECRET:-}" ]; then
    echo -e "${BOLD}${YELLOW}  Secrets — save these now:${NC}"
    [ -n "${ADMIN_PASSWORD:-}" ] && echo -e "  ${BOLD}ADMIN_PASSWORD${NC}  ${ADMIN_PASSWORD}"
    [ -n "${RUNNER_SECRET:-}"  ] && echo -e "  ${BOLD}RUNNER_SECRET${NC}   ${RUNNER_SECRET}  ${CYAN}(copy to every runner .env)${NC}"
    [ -n "${JWT_SECRET:-}"     ] && echo -e "  ${CYAN}JWT_SECRET${NC}      ${JWT_SECRET}  ${CYAN}(internal)${NC}"
    [ -n "${PG_PASS:-}"        ] && echo -e "  ${CYAN}PG_PASSWORD${NC}     ${PG_PASS}  ${CYAN}(internal)${NC}"
    echo -e ""
  fi
}

start_service() {
  local name="$1" env_file="$2" project="${3:-noderouter-${1}}"
  info "Starting ${name}…"
  docker compose \
    -f "${DEPLOY_DIR}/${name}/docker-compose.yml" \
    --env-file "${env_file}" \
    --project-name "${project}" \
    up -d --pull always
  success "${name} is up"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

echo -e ""
echo -e "${BOLD}${CYAN}  █  █  ██  ███  ████ ███   ██  █  █ ████ ████ ███ ${NC}"
echo -e "${BOLD}${CYAN}  ██ █ █  █ █  █ █    █  █ █  █ █  █  █   █    █  █${NC}"
echo -e "${BOLD}${CYAN}  █ ██ █  █ █  █ ███  ███  █  █ █  █  █   ███  ███ ${NC}"
echo -e "${BOLD}${CYAN}  █  █ █  █ █  █ █    █ █  █  █ █  █  █   █    █ █ ${NC}"
echo -e "${BOLD}${CYAN}  █  █  ██  ███  ████ █  █  ██   ██   █   ████ █  █${NC}"
echo -e "${BLUE}                 ─  Interactive Setup  ─${NC}"
echo -e ""

check_deps

# Create service directories up front so .env writes never fail on a fresh machine
mkdir -p "${DEPLOY_DIR}/postgres" "${DEPLOY_DIR}/core" "${DEPLOY_DIR}/nginx" "${DEPLOY_DIR}/runner"

echo

header "Which services do you want to configure?"
echo "  (You can run this script multiple times — existing .env files are skipped)"
echo

# Use if/then — avoids running `false` as a command under set -e
DEPLOY_POSTGRES=false
DEPLOY_CORE=false
USE_NGINX=false
DEPLOY_RUNNER=false
NGINX_DOMAIN=""
NGINX_CERT_TYPE="1"
BUNDLED_DATABASE_URL=""
CORE_DATABASE_URL=""
CORE_PORT_VAL="3000"
PG_USER="noderouter"
PG_PASS=""
PG_DB="noderouter"
PG_PORT="5432"
JWT_SECRET=""
RUNNER_SECRET=""
ADMIN_PASSWORD=""

if ask_yn "Configure nginx HTTPS proxy?"; then USE_NGINX=true;       fi
if ask_yn "Configure PostgreSQL?";         then DEPLOY_POSTGRES=true; fi
if ask_yn "Configure Core?";              then DEPLOY_CORE=true;     fi
if ask_yn "Configure Runner?";            then DEPLOY_RUNNER=true;   fi

# ── Pre-generate secrets ──────────────────────────────────────────────────────
[ "$DEPLOY_POSTGRES" = "true" ] && PG_PASS=$(gen_secret)
if [ "$DEPLOY_CORE" = "true" ]; then
  JWT_SECRET=$(gen_secret)
  RUNNER_SECRET=$(gen_secret)
  ADMIN_PASSWORD=$(gen_secret)
fi

# Single customization gate — one y/n replaces all individual secret prompts
_needs_secrets=false
[ "$DEPLOY_POSTGRES" = "true" ] && _needs_secrets=true
[ "$DEPLOY_CORE"     = "true" ] && _needs_secrets=true
if [ "$_needs_secrets" = "true" ]; then
  echo
  info "All secrets have been auto-generated."
  if ask_yn "Customize any secret?" "n"; then
    echo
    [ "$DEPLOY_POSTGRES" = "true" ] && PG_PASS=$(ask_secret "POSTGRES_PASSWORD" "$PG_PASS")
    if [ "$DEPLOY_CORE" = "true" ]; then
      JWT_SECRET=$(ask_secret "JWT_SECRET" "$JWT_SECRET")
      RUNNER_SECRET=$(ask_secret "RUNNER_SECRET" "$RUNNER_SECRET")
      ADMIN_PASSWORD=$(ask_secret "ADMIN_PASSWORD" "$ADMIN_PASSWORD")
    fi
  fi
fi

# nginx must be known before core (affects CORE_BIND_ADDR) and runner (affects CORE_WS_URL default)
if [ "$DEPLOY_POSTGRES" = "true" ]; then setup_postgres; fi
if [ "$DEPLOY_CORE"     = "true" ]; then setup_core;     fi
if [ "$USE_NGINX"       = "true" ]; then setup_nginx;    fi
if [ "$DEPLOY_RUNNER"   = "true" ]; then setup_runner;   fi

ensure_gitignored
ensure_compose_files

header "Starting services"

# ── 1. Shared Docker network ──────────────────────────────────────────────────
if docker network inspect noderouter >/dev/null 2>&1; then
  label=$(docker network inspect noderouter --format '{{index .Labels "com.docker.compose.network"}}' 2>/dev/null || true)
  if [ -n "$label" ]; then
    info "Recreating 'noderouter' network (removing stale compose labels)…"
    docker network rm noderouter 2>/dev/null \
      || { warn "Could not remove 'noderouter' network — stop all containers using it first, then re-run."; exit 1; }
    docker network create --driver bridge noderouter >/dev/null
    success "Recreated 'noderouter' Docker network"
  fi
else
  docker network create --driver bridge noderouter >/dev/null
  success "Created 'noderouter' Docker network"
fi

# ── 2. PostgreSQL ─────────────────────────────────────────────────────────────
if [ "$DEPLOY_POSTGRES" = "true" ] && [ -f "${DEPLOY_DIR}/postgres/.env" ]; then
  start_service postgres "${DEPLOY_DIR}/postgres/.env" noderouter-postgres
  wait_healthy noderouter-postgres 60
fi

# ── 3. Core ───────────────────────────────────────────────────────────────────
if [ "$DEPLOY_CORE" = "true" ] && [ -f "${DEPLOY_DIR}/core/.env" ]; then
  start_service core "${DEPLOY_DIR}/core/.env" noderouter-core
fi

# ── 4. nginx (cert init + start) ─────────────────────────────────────────────
if [ "$USE_NGINX" = "true" ] && [ -f "${DEPLOY_DIR}/nginx/.env" ]; then
  local_domain=$(grep '^DOMAIN_NAME=' "${DEPLOY_DIR}/nginx/.env" | cut -d= -f2)
  cert_path="/etc/letsencrypt/live/${local_domain}/fullchain.pem"

  cert_exists=false
  if docker run --rm \
      -v noderouter-nginx_certbot_conf:/etc/letsencrypt:ro \
      alpine test -f "$cert_path" 2>/dev/null; then
    cert_exists=true
  fi

  if [ "$cert_exists" = "false" ]; then
    if [ "${NGINX_CERT_TYPE:-1}" = "2" ]; then
      info "Issuing Let's Encrypt certificate for ${local_domain}…"
      bash "${DEPLOY_DIR}/nginx/init-certs.sh"
    else
      info "Generating self-signed certificate for ${local_domain}…"
      bash "${DEPLOY_DIR}/nginx/init-self-signed.sh"
    fi
  fi

  start_service nginx "${DEPLOY_DIR}/nginx/.env" noderouter-nginx
fi

# ── 5. Runner ─────────────────────────────────────────────────────────────────
if [ "$DEPLOY_RUNNER" = "true" ]; then
  for env_file in "${DEPLOY_DIR}"/runner/.env.*; do
    [ -f "$env_file" ] || continue
    [[ "$env_file" == *.example ]] && continue
    runner_name="${env_file##*.env.}"
    info "Starting runner-${runner_name}…"
    RUNNER_NAME="$runner_name" docker compose \
      -f "${DEPLOY_DIR}/runner/docker-compose.yml" \
      --env-file "$env_file" \
      --project-name "noderouter-runner-${runner_name}" \
      up -d --pull always
    success "runner-${runner_name} is up"
  done
fi

base_url=""
if [ "${USE_NGINX:-false}" = "true" ] && [ -n "${NGINX_DOMAIN:-}" ]; then
  base_url="https://${NGINX_DOMAIN}"
else
  base_url="http://localhost:${CORE_PORT_VAL:-3000}"
fi
print_summary "$base_url"
