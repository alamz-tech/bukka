# BUK-42: Create the production network with web and database subnets

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-2 Move to the cloud |
| **Month** | 2 |
| **Sprint** | 6 |
| **Skills** | gcp-vpc, network-isolation |
| **Reporter** | Hussein Alamutu (Product Manager & Lead DevOps Engineer) |
| **Assignee** | You |
| **Due** | End of sprint 6 |

## Context

### Why this matters

The orders database holds every customer's name, address and phone number,
and right now it sits on a box with a public IP. A port scan found Postgres
answering on 5432 from the internet: one password is all that stands
between our customers' data and the world. That has to end before anything
else moves to Google Cloud.

### What I need from you

- A production VPC with two subnets: one for the website and API, and one
  for the database, where nothing on the internet can reach the database and
  the database can't reach the internet either.
- Laid out so the database can run in two zones when we get there, because
  one data centre having a bad day at lunchtime shouldn't take all of Bukka
  down.
- All of it saved as a script, so it can be rebuilt on a fresh project.

— Hussein Alamutu, Product Manager & Lead DevOps Engineer

## Acceptance criteria

All of this runs on **floci-gcp**, Google Cloud simulated in Docker on your
machine. No Google account, no credit card, no bill. See the Notes for
setup.

### The VPC

1. Create a VPC called `bukka-prod-vpc` in **custom** subnet mode (you
   create every subnet yourself; auto mode would create one in every region
   with ranges you didn't choose).

### Subnets

2. Create two subnets in `us-central1`, inside a `10.0.0.0/16` address plan:

   | Name | Range | Private Google Access |
   |---|---|---|
   | `bukka-web` | `10.0.1.0/24` | off |
   | `bukka-db` | `10.0.10.0/24` | **on** |

   No other subnets in `bukka-prod-vpc`.

### Keep the database tier off the internet

The database servers will carry the network tag `bukka-db`. The firewall
rules decide what that tag can reach and what can reach it.

3. Create a firewall rule called `bukka-db-deny-egress`: egress, **deny**
   all protocols to `0.0.0.0/0`, for the tag `bukka-db`, priority `1000`.
4. No egress rule with a higher priority (a lower number) lets `bukka-db`
   out to the internet again. One exception is allowed: TCP `443` to
   `199.36.153.8/30`, Google's private API range, so the database can reach
   Cloud Storage for backups through Private Google Access.
5. No ingress rule lets the internet in to `bukka-db`. Watch out for rules
   with no target tags: they apply to every VM in the network, the database
   included.

### Write it down

6. Save every command you ran, in order, in `infra/cli/buk-42.sh`, so the
   network can be rebuilt on a fresh floci-gcp with one command.
7. In your pull request description, under **Anything the reviewer should
   look at closely?**, add:
   - A simple diagram of the network (ASCII art or a picture is fine) showing
     the VPC, both subnets, the zones a VM in each could run in, and the
     firewall rules
   - A short design note: why the database tier can't reach the internet,
     why one regional subnet covers two zones, and what would change if the
     database ever needed to download updates from the internet (hint: look
     up Cloud NAT, and what it costs)

### Submit

8. Work on a branch called `buk-42-production-network`, created from
   `upstream/apprentice/<your-github-username>`.
9. With floci-gcp running and your network created, run
   `bash scripts/verify/buk-42.sh`. It writes
   `artifacts/buk-42-network-audit.txt`.
10. Commit the audit file and `infra/cli/buk-42.sh`, push, and open a pull
    request into `apprentice/<your-github-username>`, titled
    `feat: create production VPC with web and database subnets (BUK-42)`.

## Definition of done

- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved your pull request
- [ ] A teammate could look at your diagram and say which subnet and which
      tag a new server needs

## Notes

- **What makes a VM "public" in Google Cloud?** A VPC sends `0.0.0.0/0` to
  the internet gateway for every subnet by default. What stops a VM being
  on the internet is having **no external IP** (nothing can reach it, and
  without Cloud NAT it can't reach out) and **firewall rules** (what may come
  in, what may go out). That's why the firewall rules are the most important
  part of this ticket: they still hold if someone gives a database VM an
  external IP by mistake.
- **Routes and Cloud NAT aren't part of this lab:** floci-gcp doesn't
  simulate them, so you won't create routes or a NAT gateway here. Real
  projects use both, and your design note should still say how Cloud NAT
  would change things.
- **Why a deny rule if there's no NAT?** Defence in depth. If someone gives
  the database an external IP, or adds Cloud NAT for the web tier later, the
  deny rule still keeps the database's data from leaving.
- **Priorities:** `0` is the highest, `65535` the lowest. The rule with the
  lowest number that matches wins, and at the same number a deny beats an
  allow.
- **Why `/16` and `/24`?** `10.0.0.0/16` is the plan the whole VPC grows
  into (about 65,000 addresses). Each `/24` subnet has 256 (Google keeps 4
  of them). Leaving gaps like `10.0.2.0` to `10.0.9.0` means there's room for
  more web subnets later without renumbering.
- **Two zones, one subnet:** a zone is a separate data centre in a region.
  In AWS a subnet lives in one zone; in Google Cloud a subnet covers the whole
  region, so a VM in `us-central1-a` and one in `us-central1-b` can share
  `bukka-db`. A highly available Cloud SQL database does exactly that.
- **Starting floci-gcp** (a free, open-source Google Cloud emulator: no
  account, no token; the image is pinned so everyone gets the same
  behaviour):
  ```bash
  docker run --rm -d --name floci-gcp -p 4588:4588 \
    -v /var/run/docker.sock:/var/run/docker.sock floci/floci-gcp:nightly-11172026
  ```
- **Pointing gcloud at it:** from the root of your bukka clone,
  `source scripts/floci-gcp.env` (see BUK-38).
- floci-gcp forgets everything when it stops, so keep `infra/cli/buk-42.sh`
  up to date. Run it once on a fresh floci-gcp: names are unique in a
  project, so a second run stops at the first thing that already exists.
- Useful commands: `gcloud compute networks create --subnet-mode=custom`,
  `gcloud compute networks subnets create --enable-private-ip-google-access`,
  `gcloud compute firewall-rules create --direction=EGRESS --action=DENY`,
  `gcloud compute firewall-rules list`,
  `gcloud compute firewall-rules describe`.
- If Docker won't run on your machine, use a GitHub Codespace on your fork:
  Docker is already installed there.
