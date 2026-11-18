# BUK-45 lab: bukka-api-1

The Bukka API server, in a Docker container on the `bukka-web-net` network.
Its data still lives in a SQLite file on its own disk. Your job (see
`tickets/BUK-45.md`) is to give it a private PostgreSQL database.

```bash
bash labs/buk-45/start.sh                   # create the API server (fresh each time)
docker exec -it -u oncall bukka-api-1 bash  # log in
bash labs/buk-45/stop.sh                    # remove the API server
bash labs/buk-45/stop.sh --all              # also remove your database, its data and the networks
```

Customers reach the API at `http://localhost:18082`.

## How this maps to Google Cloud

| Here | In Google Cloud |
|---|---|
| `bukka-web-net` Docker network | the `bukka-web` subnet, where VMs have external IPs |
| `bukka-db-net`, created with `--internal` | the `bukka-db` subnet, with `bukka-db-deny-egress` (no way out to the internet) |
| `bukka-orders-db` PostgreSQL container, no published ports | a Cloud SQL instance with a private IP only |
| the `bukka-orders-data` volume | Cloud SQL storage |
| `bukka-api-1` attached to both networks | the API server, allowed in by `bukka-db-allow-api` (its service account is the source) |

**Needs Docker:** Docker Desktop on macOS or Windows (with WSL), Docker Engine
on Linux, or a GitHub Codespace (Docker is already there).
