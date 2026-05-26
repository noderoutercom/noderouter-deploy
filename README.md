# Noderouter — Distributed Deployment Guide

Three independently deployable units. Each can run on the same host or on
completely separate machines.

```
┌─────────────────┐        ┌──────────────────────────────────────┐
│   postgres/     │◄───────│   core/                              │
│                 │        │   (reads/writes app blobs to DB)     │
│  Any PostgreSQL │◄───────┤                                      │
│  server works   │        └─────────────────┬────────────────────┘
└─────────────────┘                          │ WebSocket
                                             │ (CORE_WS_URL)
                           ┌─────────────────▼─────────┐
                           │   runner/  ×N              │
                           │                            │
                           │  • Registers with core     │
                           │  • Pulls app blobs from DB │
                           │  • No shared volume needed │
                           └────────────────────────────┘
```

---

## Quick Start — Interactive Setup

Run these commands on any Linux / macOS machine with Docker installed:

```bash
mkdir noderouter && cd noderouter
bash <(curl -fsSL https://raw.githubusercontent.com/noderoutercom/noderouter-deploy/main/scripts/setup.sh)
```

The script will download all required compose files, prompt for configuration values,
auto-generate cryptographic secrets, and optionally start the containers.

> **Why `mkdir noderouter` first?**
> The script creates `postgres/`, `core/`, and `runner/` subdirectories in the
> current working directory. Running from a dedicated folder keeps everything tidy.

Or clone the full repo instead:

```bash
git clone https://github.com/noderoutercom/noderouter-deploy.git && cd noderouter-deploy
bash scripts/setup.sh
```

### Update env vars on a running service

```bash
curl -fsSL https://raw.githubusercontent.com/noderoutercom/noderouter-deploy/main/scripts/update-env.sh -o update-env.sh
bash update-env.sh core ADMIN_PASSWORD=NewPass
bash update-env.sh runner.node1 ASYNC_MAX_WORKERS=8
bash update-env.sh postgres   # opens $EDITOR for freeform editing
```

---

## Manual Setup

### 1. PostgreSQL

> Skip if you already have a PostgreSQL server.

```bash
cd postgres
cp .env.example .env        # edit: POSTGRES_PASSWORD (required), POSTGRES_BIND_ADDR
docker compose up -d
```

Set `POSTGRES_BIND_ADDR=0.0.0.0` if core or runners run on **different** hosts.

---

### 2. Core

```bash
cd core
cp .env.example .env
# Fill in:
#   DATABASE_URL  — DSN pointing to your postgres
#   JWT_SECRET    — openssl rand -hex 32
#   PAIRING_KEY   — openssl rand -hex 32
#   RUNNER_SECRET — openssl rand -hex 32   ← copy this to every runner
#   ADMIN_PASSWORD
docker compose up -d
```

---

### 3. Runner(s)

Each runner is independent. Repeat for every node you want to add.

```bash
cd runner
cp .env.example .env
# Fill in:
#   RUNNER_NAME    — unique per host (e.g. node1, node2, gpu-node)
#   CORE_WS_URL    — ws://<core-host>:3000
#   DATABASE_URL   — same postgres as core
#   RUNNER_SECRET  — must match core's RUNNER_SECRET exactly
docker compose --project-name noderouter-runner-node1 up -d
```

#### Running multiple runners on the same host

Each runner needs a unique `RUNNER_NAME` and a separate compose project name:

```bash
# Runner 1
RUNNER_NAME=node1 docker compose \
  -f runner/docker-compose.yml \
  --env-file runner/.env.node1 \
  --project-name noderouter-runner-node1 \
  up -d

# Runner 2
RUNNER_NAME=node2 docker compose \
  -f runner/docker-compose.yml \
  --env-file runner/.env.node2 \
  --project-name noderouter-runner-node2 \
  up -d
```

The setup script writes per-runner env files as `runner/.env.<RUNNER_NAME>` and
handles this automatically.

---

## How Runners Get App Code

Runners do **not** need a shared filesystem with core.

On startup, each runner connects to the same PostgreSQL database and pulls all
app `code_bytes` blobs directly. When an app is updated via the core admin panel,
core fires a `NOTIFY app_updated` event; every connected runner fetches and
hot-reloads the updated app automatically.

This is why `DATABASE_URL` is required on runners, not just core.

---

## Choosing a PostgreSQL Server

| Scenario | Recommendation |
|---|---|
| Single host, small workload | Use `postgres/` bundled container |
| Multiple hosts, own infra | Dedicated VM or bare-metal postgres, set `POSTGRES_BIND_ADDR=0.0.0.0` and firewall to core/runner IPs |
| Managed cloud | AWS RDS, Supabase, Neon, etc. — just set `DATABASE_URL` in core and runner; skip `postgres/` entirely |

---

## Environment Variable Reference

### postgres/.env

| Variable | Required | Default | Notes |
|---|---|---|---|
| `POSTGRES_PASSWORD` | ✅ | — | Choose a strong password |
| `POSTGRES_PORT` | | `5432` | Host-side port |
| `POSTGRES_BIND_ADDR` | | `127.0.0.1` | `0.0.0.0` for remote access |
| `POSTGRES_USER` | | `noderouter` | |
| `POSTGRES_DB` | | `noderouter` | |

### core/.env

| Variable | Required | Default | Notes |
|---|---|---|---|
| `DATABASE_URL` | ✅ | — | Full PostgreSQL DSN |
| `JWT_SECRET` | ✅ | — | `openssl rand -hex 32` |
| `PAIRING_KEY` | ✅ | — | `openssl rand -hex 32` |
| `RUNNER_SECRET` | ✅ | — | Must match every runner |
| `ADMIN_PASSWORD` | ✅ | — | Admin panel password |
| `CORE_PORT` | | `3000` | Host-side port |
| `CORE_BIND_ADDR` | | `0.0.0.0` | |
| `APP_ENV` | | `production` | |

### runner/.env

| Variable | Required | Default | Notes |
|---|---|---|---|
| `CORE_WS_URL` | ✅ | — | `ws://host:3000` or `wss://host` |
| `DATABASE_URL` | ✅ | — | Same DB as core |
| `RUNNER_SECRET` | ✅ | — | Copy from core/.env |
| `RUNNER_NAME` | | `node1` | Unique per host |
| `NODE_ID` | | *(auto)* | Leave blank for auto-registration |
| `ASYNC_MAX_WORKERS` | | `4` | |
| `SYNC_MAX_WORKERS` | | `8` | |
