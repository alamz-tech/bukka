# BUK-51: Manage production infrastructure with Terraform

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-2 Move to the cloud |
| **Month** | 2 |
| **Sprint** | 8 |
| **Skills** | terraform |
| **Reporter** | Hussein Alamutu (Product Manager & Lead DevOps Engineer) |
| **Assignee** | You |
| **Due** | End of sprint 8 |

## Context

### Why this matters

We're about to onboard a lot more restaurants, and our infrastructure is
three shell scripts nobody fully trusts. Last week someone ran `buk-42.sh`
twice and ended up with two VPCs. Nobody can look at a script and say what
production *should* look like, or what a change will do before it happens.
That's how outages and surprise bills start.

### What I need from you

- From now on production is code. Everything from BUK-38, BUK-42 and the
  Google Cloud side of BUK-45 goes into Terraform, in modules (network, compute, database,
  storage, billing) that can be reviewed on their own.
- State lives in a shared, locked bucket, not on a laptop.
- Every change gets a plan that a teammate reads in the pull request before
  anyone applies it.
- Prove it works from scratch: tear the whole thing down and build it again.

— Hussein Alamutu, Product Manager & Lead DevOps Engineer

## Acceptance criteria

All of this runs on **floci-gcp**, Google Cloud simulated in Docker on your
machine. No Google account, no credit card, no bill. See the Notes for
setup.

### Project layout

1. Put the Terraform code in `infra/terraform/`, laid out like this:
   ```
   infra/terraform/
     versions.tf      Terraform and Google provider version constraints
     backend.tf       remote state
     main.tf          calls the modules and wires them together
     variables.tf     inputs, each with a type and a description
     outputs.tf       bukka-prod-vpc, bukka-api-1, bukka-db-allow-api, bucket name
     modules/
       network/       VPC, subnets, the database tier's egress rules (BUK-42)
       compute/       service account and its bucket access, bukka-allow-web, bukka-api-1 (BUK-38)
       database/      bukka-orders-db service account, bukka-db-allow-api (BUK-45)
       storage/       menu photos bucket: uniform access, public access prevention, versioning (BUK-45)
       billing/       Pub/Sub topic and subscription, the budget (BUK-38)
   ```
2. Every module has its own `main.tf`, `variables.tf` and `outputs.tf`.
3. Modules don't hard-code each other's IDs or service account emails. The
   root `main.tf` passes outputs from one module into another (e.g. the
   network module's VPC into the database module, and the compute module's
   service account email into it as the only source allowed on `5432`).

### Same rules as before

4. Everything the verify scripts for BUK-38, BUK-42 and BUK-45 checked
   still holds: the same names, ranges and tags, read-only access to one
   bucket, no keys, `5432` only from the API's service account, the
   database tier kept off the internet, the bucket private and versioned,
   the budget. The API server now runs in the `bukka-web` subnet of
   `bukka-prod-vpc`, and `bukka-allow-web` lives there too: no `default`
   network any more. Terraform manages the bucket, not the photos in it: it
   can start empty.
5. No secrets in the code: no passwords, no keys and no `credentials` file
   anywhere. The database server itself stays in `infra/db/orders-db.sh`
   from BUK-45 (Terraform manages the Google Cloud side only).

### Remote state

6. Store state in a Cloud Storage bucket called
   `bukka-tfstate-<your-github-username>` with versioning on, uniform
   bucket-level access and public access prevention, using the `gcs`
   backend with `prefix = "prod"`. The gcs backend locks state on its own.
   Create this one bucket by hand (or with a small script) before
   `terraform init`.
7. No state files, `.terraform/` directories or `.tfvars` files with
   secrets are committed. Add them to `.gitignore`. Do commit
   `.terraform.lock.hcl`.

### Plan, review, apply, destroy

8. `terraform fmt -check -recursive` and `terraform validate` both pass.
   Use Terraform **1.11 or newer** and say so with `required_version` in
   `versions.tf`.
9. On a fresh floci-gcp, save the plan to a file and commit it:
   `terraform plan -no-color > artifacts/buk-51-terraform-plan.txt`. In your
   pull request description, quote only the `Plan: N to add` line and say in
   a sentence what you'd want a reviewer to check. A teammate reviews the
   plan file in the pull request, not just the code.
10. `terraform apply` builds everything in one go, with no errors.
11. Running `terraform plan` again straight after shows **No changes**.
12. `terraform destroy` removes everything cleanly, and a second
    `terraform apply` builds it all again.
13. Remove `infra/cli/buk-38.sh`, `buk-42.sh` and `buk-45.sh`. Terraform is
    now the only way the Google Cloud side is built. Keep
    `infra/db/orders-db.sh`.

### Write it down

14. Add a short design note to your pull request description, under
    **Anything the reviewer should look at closely?**:
    - Why you split the modules the way you did, and what each one outputs
    - Why state lives in Cloud Storage and not on your laptop, and why it
      needs locking
    - Why state files are treated as secrets: look inside yours, and say
      what would end up there if Terraform also created the database
      password

### Submit

15. Work on a branch called `buk-51-terraform-production`, created from
    `upstream/apprentice/<your-github-username>`.
16. With floci-gcp running and the stack applied, run
    `bash scripts/verify/buk-51.sh`. It writes
    `artifacts/buk-51-terraform-audit.txt`.
17. Commit the audit file and your Terraform code, push, and open a pull
    request into `apprentice/<your-github-username>`, titled
    `feat: manage production infrastructure with Terraform (BUK-51)`.

## Definition of done

- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed your plan output and approved your pull
      request
- [ ] You have destroyed and rebuilt the whole stack at least once
- [ ] A teammate could clone your branch and build production with
      `terraform init` and `terraform apply`

## Notes

- **Why Terraform?** A script says *how* to build something. Terraform
  says *what* should exist, works out the difference from what does exist,
  and shows you that difference as a plan. Running it twice doesn't give
  you two VPCs.
- **Why review the plan?** Code that looks harmless can still replace a
  database. The plan says `must be replaced` in plain words. Reading it
  before apply is the habit that saves you.
- **Why remote state?** State is Terraform's memory of what it built. On
  one laptop it's lost when the laptop is, and two people applying at once
  can corrupt it. A shared, versioned, locked bucket fixes both.
- **Starting floci-gcp** (pinned, as in BUK-38):
  ```bash
  docker run --rm -d --name floci-gcp -p 4588:4588 \
    -v /var/run/docker.sock:/var/run/docker.sock floci/floci-gcp:nightly-11172026
  ```
  Then, from the root of your bukka clone: `source scripts/floci-gcp.env`.
  It also sets `GOOGLE_OAUTH_ACCESS_TOKEN`, the dummy token Terraform uses.
- **Pointing Terraform at it:** the Google provider needs one endpoint per
  API. Make floci-gcp's address a variable, so the same code works on real
  Google Cloud when it's set to `""` (a `null` endpoint means "use the
  default"):
  ```hcl
  locals {
    floci = var.floci_gcp_url == "" ? null : var.floci_gcp_url
  }

  provider "google" {
    project               = var.project_id
    region                = var.region
    user_project_override = false

    compute_custom_endpoint          = local.floci == null ? null : "${local.floci}/compute/v1/"
    storage_custom_endpoint          = local.floci == null ? null : "${local.floci}/storage/v1/"
    iam_custom_endpoint              = local.floci == null ? null : "${local.floci}/"
    iam_beta_custom_endpoint         = local.floci == null ? null : "${local.floci}/v1/"
    pubsub_custom_endpoint           = local.floci == null ? null : "${local.floci}/v1/"
    resource_manager_custom_endpoint = local.floci == null ? null : "${local.floci}/v1/"
    billing_budgets_custom_endpoint  = local.floci == null ? null : "${local.floci}/v1/"
  }
  ```
  For the backend, keep the floci-gcp setting in a separate file and pass it
  at init, so `backend.tf` stays the same for real Google Cloud:
  ```hcl
  # backend-floci.hcl
  storage_custom_endpoint = "http://localhost:4588/storage/v1/"
  ```
  ```bash
  terraform init -backend-config=backend-floci.hcl
  ```
- **Inputs:** your GitHub username and the billing account are inputs, not
  hard-coded. Put them in `infra/terraform/terraform.tfvars` (ignored by
  git) and commit a `terraform.tfvars.example` so a teammate knows what to
  fill in. The one exception is the state bucket name in `backend.tf`:
  backends can't read variables.
- **Image:** `debian-cloud/debian-12` is in floci-gcp's image catalogue. Make
  it a variable with a default.
- **The budget** is `google_billing_budget`, with `all_updates_rule` for the
  Pub/Sub topic. floci-gcp's billing account is `000000-000000-000000`.
- Start small: get the network module planning and applying first, then
  add one module at a time.
- Useful commands: `terraform init`, `terraform fmt -recursive`,
  `terraform validate`, `terraform plan`, `terraform apply`,
  `terraform state list`, `terraform output`, `terraform destroy`.
- If Docker won't run on your machine, use a GitHub Codespace on your fork:
  Docker is already installed there.
