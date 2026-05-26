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

# ask_secret "Label"  →  shows auto-generated value, allows override
ask_secret() {
  local label="$1" generated
  generated="$(gen_secret)"
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
  local services=(postgres core runner)
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
  info "Deploy a bundled postgres container, or skip to use an external server."
  if ! ask_yn "Deploy bundled PostgreSQL container?"; then
    info "Skipped. Set DATABASE_URL in core/.env and runner/.env to your external postgres DSN."
    return
  fi

  echo
  info "Bind address:"
  echo "  0.0.0.0   → all interfaces (needed when core/runner are on other hosts)"
  echo "  127.0.0.1 → localhost only (if core/runner are on the same host)"

  local bind_addr pg_port pg_user pg_pass pg_db
  bind_addr=$(ask "POSTGRES_BIND_ADDR" "0.0.0.0")
  pg_port=$(ask "POSTGRES_PORT" "5432")
  pg_user=$(ask "POSTGRES_USER" "noderouter")
  pg_pass=$(ask_secret "POSTGRES_PASSWORD (stored in postgres/.env)")
  pg_db=$(ask "POSTGRES_DB" "noderouter")

  mkdir -p "${DEPLOY_DIR}/postgres"
  cat > "$env_file" <<EOF
POSTGRES_BIND_ADDR=${bind_addr}
POSTGRES_PORT=${pg_port}
POSTGRES_USER=${pg_user}
POSTGRES_PASSWORD=${pg_pass}
POSTGRES_DB=${pg_db}
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
  core_image=$(ask "CORE_IMAGE" "${DOCKERHUB_USER}/noderouter-core:latest")

  echo
  info "DATABASE_URL — the PostgreSQL DSN core will connect to."
  info "  Example: postgresql://noderouter:PASSWORD@localhost:5432/noderouter?sslmode=disable"

  local db_url core_port jwt_secret pairing_key runner_secret admin_pass
  db_url=$(ask "DATABASE_URL")
  core_port=$(ask "CORE_PORT (host port)" "3000")

  echo
  info "Generating secrets (press Enter to accept each auto-generated value):"
  jwt_secret=$(ask_secret "JWT_SECRET")
  pairing_key=$(ask_secret "PAIRING_KEY")
  runner_secret=$(ask_secret "RUNNER_SECRET (copy this to every runner's .env)")

  echo
  admin_pass=$(ask "ADMIN_PASSWORD")

  mkdir -p "${DEPLOY_DIR}/core"
  cat > "$env_file" <<EOF
CORE_IMAGE=${core_image}
CORE_PORT=${core_port}
CORE_BIND_ADDR=0.0.0.0
APP_ENV=production
DATABASE_URL=${db_url}
JWT_SECRET=${jwt_secret}
PAIRING_KEY=${pairing_key}
RUNNER_SECRET=${runner_secret}
ADMIN_PASSWORD=${admin_pass}
EOF
  success "core/.env written"
  echo
  warn "RUNNER_SECRET = ${runner_secret}"
  warn "→ Copy this value when you set up each runner."
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
  runner_image=$(ask "RUNNER_IMAGE" "${DOCKERHUB_USER}/noderouter-runner:latest")

  echo
  info "CORE_WS_URL — WebSocket URL of noderouter-core reachable from this runner host."
  info "  Same host (Docker bridge): ws://noderouter-core:3000"
  info "  Different host:            ws://192.168.1.x:3000  or  wss://core.example.com"

  local core_ws_url db_url runner_secret async_workers sync_workers
  core_ws_url=$(ask "CORE_WS_URL")

  echo
  info "DATABASE_URL — same postgres that core uses, reachable from this runner host."
  db_url=$(ask "DATABASE_URL")

  echo
  info "RUNNER_SECRET — must match the value in core/.env exactly."
  runner_secret=$(ask "RUNNER_SECRET (from core/.env)")

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

echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   Noderouter Interactive Setup   ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════╝${NC}"

check_deps

# Create service directories up front so .env writes never fail on a fresh machine
mkdir -p "${DEPLOY_DIR}/postgres" "${DEPLOY_DIR}/core" "${DEPLOY_DIR}/runner"

echo
info "Docker Hub username — used to pre-fill image name defaults."
read -r -p "  Docker Hub username [06042013]: " DOCKERHUB_USER </dev/tty
DOCKERHUB_USER="${DOCKERHUB_USER:-06042013}"
echo

header "Which services do you want to configure?"
echo "  (You can run this script multiple times — existing .env files are skipped)"
echo

# Use if/then — avoids running `false` as a command under set -e
DEPLOY_POSTGRES=false
DEPLOY_CORE=false
DEPLOY_RUNNER=false

if ask_yn "Configure PostgreSQL?"; then DEPLOY_POSTGRES=true; fi
if ask_yn "Configure Core?";       then DEPLOY_CORE=true;     fi
if ask_yn "Configure Runner?";     then DEPLOY_RUNNER=true;   fi

if [ "$DEPLOY_POSTGRES" = "true" ]; then setup_postgres; fi
if [ "$DEPLOY_CORE"     = "true" ]; then setup_core;     fi
if [ "$DEPLOY_RUNNER"   = "true" ]; then setup_runner;   fi

ensure_gitignored
ensure_compose_files

header "Deploy"
if ask_yn "Start configured services now?"; then

  if [ "$DEPLOY_POSTGRES" = "true" ] && [ -f "${DEPLOY_DIR}/postgres/.env" ]; then
    start_service postgres "${DEPLOY_DIR}/postgres/.env" noderouter-postgres
    wait_healthy noderouter-postgres 60
  fi

  if [ "$DEPLOY_CORE" = "true" ] && [ -f "${DEPLOY_DIR}/core/.env" ]; then
    start_service core "${DEPLOY_DIR}/core/.env" noderouter-core
  fi

  if [ "$DEPLOY_RUNNER" = "true" ]; then
    for env_file in "${DEPLOY_DIR}"/runner/.env.*; do
      [ -f "$env_file" ] || continue
      # Skip template/example files — they contain placeholder image names
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

  echo
  success "All done! Run 'docker ps' to verify."

else
  info "To start later, run:"
  if [ "$DEPLOY_POSTGRES" = "true" ]; then
    echo "  docker compose -f ${DEPLOY_DIR}/postgres/docker-compose.yml --env-file ${DEPLOY_DIR}/postgres/.env --project-name noderouter-postgres up -d"
  fi
  if [ "$DEPLOY_CORE" = "true" ]; then
    echo "  docker compose -f ${DEPLOY_DIR}/core/docker-compose.yml --env-file ${DEPLOY_DIR}/core/.env --project-name noderouter-core up -d"
  fi
  if [ "$DEPLOY_RUNNER" = "true" ]; then
    echo "  RUNNER_NAME=node1 docker compose -f ${DEPLOY_DIR}/runner/docker-compose.yml --env-file ${DEPLOY_DIR}/runner/.env.node1 --project-name noderouter-runner-node1 up -d"
  fi
fi
