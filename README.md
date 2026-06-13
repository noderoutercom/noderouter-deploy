# Noderouter — Deployment Guide

All services run on the **same host**, connected through a shared Docker network (`noderouter`).

```
                        ┌─────────────────────────────────┐
  Browser / Runner      │         noderouter network       │
        │               │                                  │
        │  :443 / :80   │  ┌──────────┐   ┌───────────┐   │
        └──────────────►│  │  nginx   │──►│   core    │   │
           (optional)   │  └──────────┘   └─────┬─────┘   │
                        │                        │         │
                        │               ┌────────▼──────┐  │
                        │               │   postgres    │  │
                        │               └───────────────┘  │
                        │                                  │
                        │        ┌──────────────┐          │
                        │        │   runner ×N  │          │
                        │        └──────────────┘          │
                        └─────────────────────────────────┘
```

Services talk to each other by container name (e.g. `noderouter-core`, `noderouter-postgres`) — no host IPs needed.

---

## Quick Start — Interactive Setup

> **Prerequisites:** [Docker Desktop](https://docs.docker.com/desktop/) must be installed and running.

### Linux / macOS

```bash
mkdir noderouter && cd noderouter
bash <(curl -fsSL https://raw.githubusercontent.com/noderoutercom/noderouter-deploy/main/scripts/setup.sh)
```

### Windows

Use **Git Bash** ([Git for Windows](https://git-scm.com/download/win)) or **WSL**:

```bash
mkdir noderouter && cd noderouter
bash <(curl -fsSL https://raw.githubusercontent.com/noderoutercom/noderouter-deploy/main/scripts/setup.sh)
```

> **WSL users:** enable Docker Desktop → Settings → Resources → WSL Integration for your distro.

### Clone instead of curl

```bash
git clone https://github.com/noderoutercom/noderouter-deploy.git && cd noderouter-deploy
bash scripts/setup.sh
```

The script opens with an upfront menu — choose which services to configure (nginx, PostgreSQL, core, runner), then it prompts for values, generates env files, initialises TLS certificates if needed, and starts everything. Existing env files are skipped, so you can re-run safely to add more services later. Runner env files are written as `runner/.env.<name>` (e.g. `runner/.env.node1`).

---

## Manual Setup

### 0. Shared Docker network

All services share one named network. It is created automatically by the first `docker compose up`, but you can also create it manually:

```bash
docker network create noderouter
```

> If a stale `noderouter` network exists from a previous install, remove it first:
> `docker network rm noderouter`

---

### 1. nginx HTTPS *(optional)*

Skip this section if you use Cloudflare or another external proxy, or if you only need HTTP.

When nginx is in front, set `CORE_BIND_ADDR=127.0.0.1` in `core/.env` so port 3000 is not exposed publicly.

#### Local dev — self-signed certificate

```bash
cd nginx
cp .env.example .env        # set DOMAIN_NAME=your-local-hostname
bash init-self-signed.sh
docker compose --env-file .env up -d
```

> Browsers will show a security warning for self-signed certs. Import `fullchain.pem` into your OS trust store to suppress it.

#### Production — Let's Encrypt

Requires a public domain with a DNS A record pointing to this server before running:

```bash
cd nginx
cp .env.example .env        # set DOMAIN_NAME and CERTBOT_EMAIL
bash init-certs.sh
docker compose --env-file .env up -d
```

Certificates auto-renew every 12 hours via the `certbot` sidecar. nginx reloads nightly at 3 am to pick up renewed certs.

---

### 2. PostgreSQL

> Skip if you already have a PostgreSQL server — just set `DATABASE_URL` in `core/.env`.

```bash
cd postgres
cp .env.example .env        # set POSTGRES_PASSWORD
docker compose --project-name noderouter-postgres up -d
```

Port 5432 is bound to `127.0.0.1` (localhost only). Core and runner connect via the `noderouter` Docker network using the container name `noderouter-postgres` — no host port access needed.

---

### 3. Core

```bash
cd core
cp .env.example .env
# Fill in:
#   CORE_IMAGE     — 06042013/noderouter-core:latest  (or a specific tag)
#   DATABASE_URL   — postgresql://noderouter:PASSWORD@noderouter-postgres:5432/noderouter?sslmode=disable
#   JWT_SECRET     — openssl rand -hex 32
#   PAIRING_KEY    — openssl rand -hex 32
#   RUNNER_SECRET  — openssl rand -hex 32   ← copy this to every runner
#   ADMIN_PASSWORD
#
# With nginx in front:  CORE_BIND_ADDR=127.0.0.1
# Without nginx:        CORE_BIND_ADDR=0.0.0.0  (default)
docker compose --project-name noderouter-core up -d
```

---

### 4. Runner(s)

Runners run on the **same host** as core and connect via the shared Docker network.

Runner env files are named `runner/.env.<name>` — one file per runner instance.

```bash
cd runner
cp .env.example .env.node1
# Fill in:
#   RUNNER_IMAGE   — 06042013/noderouter-runner:latest  (or a specific tag)
#   RUNNER_NAME    — unique per runner (e.g. node1, node2)
#   RUNNER_SECRET  — must match core's RUNNER_SECRET exactly
#   DATABASE_URL   — same postgres as core
#
# CORE_GRPC_TARGET defaults to noderouter-core:50051 — no change needed for same-host runners.
RUNNER_NAME=node1 docker compose \
  -f runner/docker-compose.yml \
  --env-file runner/.env.node1 \
  --project-name noderouter-runner-node1 \
  up -d
```

#### Multiple runners on the same host

Add a new env file per runner and start each with its own project name:

```bash
cp runner/.env.node1 runner/.env.node2   # edit RUNNER_NAME inside
RUNNER_NAME=node2 docker compose \
  -f runner/docker-compose.yml \
  --env-file runner/.env.node2 \
  --project-name noderouter-runner-node2 \
  up -d
```

---

## Updating Configuration

Use `scripts/update-env.sh` to change one or more env variables and restart the affected container in a single step:

```bash
# Change a single value
bash scripts/update-env.sh core ADMIN_PASSWORD=NewPass123

# Rotate multiple secrets at once
bash scripts/update-env.sh core \
  JWT_SECRET=$(openssl rand -hex 32) \
  PAIRING_KEY=$(openssl rand -hex 32)

# Update a runner
bash scripts/update-env.sh runner.node1 ASYNC_MAX_WORKERS=8

# Open the env file in $EDITOR for freeform editing
bash scripts/update-env.sh postgres
```

The script backs up the existing file (`.env.bak.<timestamp>`) before writing, shows a diff of what changed, and prompts before restarting the container.

Services: `postgres` | `core` | `runner.<name>`

---

## HTTPS with an External Proxy (Cloudflare, etc.)

If you use Cloudflare or another external proxy, skip the `nginx/` directory entirely:

- Set `CORE_BIND_ADDR=0.0.0.0` in `core/.env` so the proxy can reach port 3000.
- Runners use `ws://noderouter-core:3000` (internal network) — they do **not** go through the external proxy.
- Let's Encrypt is not needed; your proxy provider handles TLS at the edge.

> **Cloudflare note:** Cloudflare proxies WebSocket connections, but idle connections are dropped after ~100 seconds. The runner sends WebSocket-level pings every 20 seconds, which keeps the tunnel alive.

---

## How Runners Get App Code

Runners do **not** need a shared filesystem with core.

On startup each runner connects to PostgreSQL and pulls all app `code_bytes` blobs directly. When an app is updated via the admin panel, core fires a `NOTIFY app_updated` event and every runner fetches and hot-reloads the updated app automatically. This is why `DATABASE_URL` is required on runners as well as core.

---

## Environment Variable Reference

### `nginx/.env`

| Variable | Required | Default | Notes |
|---|---|---|---|
| `DOMAIN_NAME` | ✅ | — | Domain nginx serves (e.g. `core.example.com`) |
| `CERTBOT_EMAIL` | | — | Let's Encrypt account email (production only) |
| `CERTBOT_STAGING` | | `0` | Set `1` to use staging CA during testing |

### `postgres/.env`

| Variable | Required | Default | Notes |
|---|---|---|---|
| `POSTGRES_PASSWORD` | ✅ | — | Choose a strong password |
| `POSTGRES_PORT` | | `5432` | Host-side port (for local psql / DB tools) |
| `POSTGRES_USER` | | `noderouter` | |
| `POSTGRES_DB` | | `noderouter` | |

### `core/.env`

| Variable | Required | Default | Notes |
|---|---|---|---|
| `DATABASE_URL` | ✅ | — | Full PostgreSQL DSN |
| `JWT_SECRET` | ✅ | — | `openssl rand -hex 32` |
| `PAIRING_KEY` | ✅ | — | `openssl rand -hex 32` |
| `RUNNER_SECRET` | ✅ | — | Must match every runner |
| `ADMIN_PASSWORD` | ✅ | — | Admin panel password |
| `CORE_IMAGE` | ✅ | `06042013/noderouter-core:latest` | Docker Hub image |
| `CORE_PORT` | | `3000` | Host-side port |
| `CORE_BIND_ADDR` | | `0.0.0.0` | Set `127.0.0.1` when nginx is in front |
| `APP_ENV` | | `production` | |

### `runner/.env.<name>`

| Variable | Required | Default | Notes |
|---|---|---|---|
| `DATABASE_URL` | ✅ | — | Same DB as core |
| `RUNNER_SECRET` | ✅ | — | Copy from `core/.env` |
| `RUNNER_IMAGE` | ✅ | `06042013/noderouter-runner:latest` | Docker Hub image |
| `RUNNER_NAME` | | `node1` | Unique per runner instance |
| `CORE_GRPC_TARGET` | | `noderouter-core:50051` | mTLS Tunnel — same-host default; remote: `domain:8443` |
| `CORE_ENROLL_TARGET` | | `noderouter-core:50052` | Plaintext Enroll — same-host default; remote: `domain:8444` |
| `NODE_ID` | | *(auto)* | Leave blank for auto-registration |
| `ASYNC_MAX_WORKERS` | | `4` | |
| `SYNC_MAX_WORKERS` | | `8` | |
