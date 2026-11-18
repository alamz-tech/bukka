# BUK-45: Move the orders database to a private server and menu photos to Cloud Storage

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-2 Move to the cloud |
| **Month** | 2 |
| **Sprint** | 7 |
| **Skills** | postgresql, network-isolation, gcp-storage |
| **Reporter** | Hussein Alamutu (Product Manager & Lead DevOps Engineer) |
| **Assignee** | You |
| **Due** | End of sprint 7 |

## Context

### Why this matters

Two things keep me up at night. First, the orders: they're still a file on
the API server's own disk. Every lunch rush the API and the database fight
over the same CPU and memory, and if that one box dies we lose orders that
customers have already paid for. Second, menu photos: they live in a folder
called `menu photos FINAL (2)` on a laptop and get emailed around whenever a
menu changes. 😅

### What I need from you

- The orders move to PostgreSQL on its own server, on a private network
  where nothing on the internet can reach it and it can't reach the internet
  either. Only our API servers get in, and only over an encrypted connection.
- The Google Cloud side matches: a firewall rule that only lets the API
  servers in.
- Menu photos move into the `bukka-menu-photos` bucket from BUK-38, private
  and recoverable. The `Dish.photo_key` column in the API is already
  waiting for them.

— Hussein Alamutu, Product Manager & Lead DevOps Engineer

## Acceptance criteria

There are two halves, both on your machine, no Google account and no bill:

- **The database** runs in Docker: a real PostgreSQL server on a private
  network, next to the API server from `labs/buk-45/`. This is how you
  would build it on your own servers, and it's what Cloud SQL does for you
  in Google Cloud (see the table in `labs/buk-45/README.md`).
- **The Google Cloud side** (the database's firewall rule and the photos
  bucket) runs on **floci-gcp**, like BUK-38 and BUK-42.

### Get the API server

1. Start it with `bash labs/buk-45/start.sh` and log in with
   `docker exec -it -u oncall bukka-api-1 bash`. Read the welcome message.
   The API works, but its data is a SQLite file on its own disk.

### A private network for the database

2. Create a Docker network called `bukka-db-net` with the `--internal`
   option, so nothing on it has a route to the internet.
3. Connect `bukka-api-1` to `bukka-db-net` as well. It stays on
   `bukka-web-net` too, so customers can still reach it.

### The database server

4. Run a PostgreSQL 16 container called `bukka-orders-db`:
   - image `postgres:16`
   - on `bukka-db-net` **only**
   - **no published ports** (no `-p`): nothing outside `bukka-db-net` can
     connect to it
   - database `bukka`, user `bukka`
   - data in a named volume called `bukka-orders-data`, so the orders
     survive the container being replaced
   - restarts by itself (`--restart unless-stopped`)
   - TLS turned on (`ssl=on`), so the API's connection can be encrypted.
     See the Notes
5. The password is at least 16 characters and is **not in any file you
   commit**. Your script reads it from an environment variable called
   `BUKKA_DB_PASSWORD` and refuses to run without it.
6. Save the commands for steps 2 to 4 in `infra/db/orders-db.sh`, so the
   database server can be rebuilt with one command.

### Point the API at it

7. On `bukka-api-1`, change `DATABASE_URL` in `/etc/bukka/api.env` to the
   new server, with TLS required:
   ```
   postgresql+psycopg://bukka:<password>@bukka-orders-db:5432/bukka?sslmode=require
   ```
8. Create the tables (`bukka-api migrate`), load the demo restaurants
   (`bukka-api seed`) and restart the API (`bukka-api restart`).
   `http://localhost:18082/readyz` returns `200` and
   `http://localhost:18082/api/restaurants` lists restaurants that now come
   from PostgreSQL.
9. Replace the database container (`docker rm -f bukka-orders-db`, then run
   your script again). The restaurants are still there.

### The Google Cloud side (floci-gcp)

10. Rebuild BUK-38 and BUK-42 on a fresh floci-gcp with your scripts.
11. Create a service account called `bukka-orders-db`: the identity the
    database server will run as.
12. Create a firewall rule called `bukka-db-allow-api` on `bukka-prod-vpc`
    that allows TCP `5432` **only** from the `bukka-api-server` service
    account (use the service account as the source, not an IP range or a
    tag), to VMs running as `bukka-orders-db`. No other inbound rule may
    reach the database. This is the Google Cloud version of what
    `bukka-db-net` does for you in Docker.
13. On `bukka-menu-photos-<your-github-username>`:
    - uniform bucket-level access on (IAM only, no per-object ACLs)
    - **public access prevention** enforced, so nobody can make it public
      by accident
    - **object versioning** on, so an overwritten or deleted photo can be
      brought back
    - upload at least three dish photos under the `dishes/` prefix, e.g.
      `dishes/mama-put-yaba/jollof-rice.jpg`. Any small images will do
14. Save these commands in `infra/cli/buk-45.sh`.

### Prove the database is private

15. In your pull request description, show the evidence:
    - `docker port bukka-orders-db` (it prints nothing)
    - `docker network inspect bukka-db-net --format '{{.Internal}}'`
    - a connection attempt from a container on `bukka-web-net` that **fails**,
      and the same attempt from `bukka-api-1` that **works**
      (`pg_isready -h <address> -p 5432`)
16. Add a short design note to the pull request description, under
    **Anything the reviewer should look at closely?**:
    - Why the database isn't simply on `bukka-web-net` with a strong password
    - Why `bukka-db-allow-api` uses a service account as the source instead
      of the API server's IP address or a network tag
    - What `sslmode=require` protects against
    - What value `Dish.photo_key` should hold for a photo (the key, a URL,
      or something else?) and why

### Submit

17. Work on a branch called `buk-45-private-db-and-storage`, created from
    `upstream/apprentice/<your-github-username>`.
18. With floci-gcp, `bukka-api-1` and `bukka-orders-db` all running, run
    `bash scripts/verify/buk-45.sh`. It writes
    `artifacts/buk-45-data-audit.txt`.
19. Commit `infra/` and the audit file, push, and open a pull request into
    `apprentice/<your-github-username>`, titled
    `feat: move orders to a private database and menu photos to Cloud Storage (BUK-45)`.

## Definition of done

- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved your pull request
- [ ] No password appears anywhere in your commits (check `git log -p`)
- [ ] A security reviewer could read your evidence and agree the database is private

## Notes

- **Why a separate database server?** The API can be restarted, replaced or
  run as three copies; the data must outlive all of that. Once they're
  apart, each can be sized, backed up and secured for what it does. In
  Google Cloud, Cloud SQL runs this server for you (backups, patching,
  failover), but the network rules are the same ones you set here.
- **Why no published port?** `-p 5432:5432` would put the database on your
  machine's network, and in the cloud, on the internet. Most database
  breaches start with a database that was reachable and a weak password.
  Unreachable beats strong.
- **Why `--internal`?** If someone does get into the database server, it
  can't download tools or send your customers' data anywhere. This is the
  same idea as `bukka-db-deny-egress` in BUK-42.
- **TLS on the official image:** it already contains a test certificate.
  Add these to the end of your `docker run` command, after the image name:
  ```
  -c ssl=on -c ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem \
  -c ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
  ```
  In production you'd use a certificate from your own authority (Cloud SQL
  gives you one), and `sslmode=verify-full` to check it.
- **Passwords:** `openssl rand -base64 24 | tr -d '/+='` makes a good one.
  Keep it in your shell (`export BUKKA_DB_PASSWORD=...`) or a password
  manager. If it ever lands in a commit, it's leaked, even if you delete it
  later: change it.
- **Testing a connection from the web network:**
  ```bash
  docker run --rm --network bukka-web-net postgres:16 pg_isready -h <db-ip> -p 5432 -t 3
  ```
  Find the database's address with
  `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' bukka-orders-db`.
- **Why a service account as the source?** An IP address changes when the
  API server is replaced, and anyone who can edit a VM can give it a network
  tag. A service account is an identity: only VMs you allowed to run as
  `bukka-api-server` get in. (Google Cloud doesn't let one rule mix tags and
  service accounts, which is why the database gets its own service account
  as the target.)
- **Encryption:** Cloud Storage encrypts every object at rest with
  Google-managed keys, with nothing to turn on. Customer-managed keys (Cloud
  KMS) are the next step if a customer contract asks for them.
- **Starting floci-gcp** (pinned, as in BUK-38):
  ```bash
  docker run --rm -d --name floci-gcp -p 4588:4588 \
    -v /var/run/docker.sock:/var/run/docker.sock floci/floci-gcp:nightly-11172026
  ```
  Then, from the root of your bukka clone: `source scripts/floci-gcp.env`.
- Useful commands: `docker network create --internal`,
  `docker network connect`, `docker volume ls`, `docker logs bukka-orders-db`,
  `psql`, `gcloud compute firewall-rules create --source-service-accounts
  --target-service-accounts`, `gcloud storage buckets update
  --public-access-prevention --versioning`, `gcloud storage cp`,
  `gcloud storage ls`.
- Windows: run everything from WSL. If Docker won't run on your machine, use
  a GitHub Codespace on your fork: Docker is already installed there.
