# BUK-38: Give the API server read access to the menu-photos bucket

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-2 Move to the cloud |
| **Month** | 2 |
| **Sprint** | 5 |
| **Skills** | gcp-iam, gcp-storage, cloud-costs |
| **Reporter** | Hussein Alamutu (Product Manager & Lead DevOps Engineer) |
| **Assignee** | You |
| **Due** | End of sprint 5 |

## Context

### Why this matters

We're starting the move to Google Cloud this month. Last week a security
review found a service account key, a JSON file with a private key in it,
copied onto bukka-prod-1 so the API could read menu photos. Anyone who gets
on that box, or sees that file in a screenshot, can use that key from
anywhere, and it never expires. A leak like that is the kind of headline
that ends a food startup. Finance has also asked for one promise: no
surprise cloud bills.

### What I need from you

- No keys on the API server at all: it runs as a service account attached
  to the VM.
- That service account can **read** the menu photos bucket and nothing
  else.
- Only web traffic gets in from the internet; SSH is closed or limited to
  your own IP.
- A budget that tells us the moment we spend anything.

— Hussein Alamutu, Product Manager & Lead DevOps Engineer

## Acceptance criteria

All of this runs on **floci-gcp**, Google Cloud simulated in Docker on your
machine. No Google account, no credit card, no bill. See the Notes for
setup.

### The bucket

1. Create a Cloud Storage bucket called
   `bukka-menu-photos-<your-github-username>` (all lowercase) in
   `us-central1`, with uniform bucket-level access. It can be empty for now.
   BUK-45 locks it down and fills it.

### An identity for the server, not a key

2. Create a service account called `bukka-api-server`.
3. Give it `roles/storage.objectViewer` **on your bucket only** (a binding
   on the bucket, not on the project):
   - No project-wide roles for the service account. A role on the project
     reaches every bucket, now and later.
   - No other roles on your bucket (no `objectAdmin`, no `objectCreator`),
     and nothing on any other bucket.
   - The bucket isn't public: no `allUsers` or `allAuthenticatedUsers`.
4. The service account has **no keys**, and nobody can act as it:
   nobody holds `roles/iam.serviceAccountTokenCreator`,
   `roles/iam.serviceAccountKeyAdmin` or `roles/iam.serviceAccountUser` on
   it.

### The API server

5. A new Google Cloud project comes with a network called `default`.
   floci-gcp starts empty, so create it yourself: a custom-mode network
   `default` with one subnet, also called `default`, `10.128.0.0/20` in
   `us-central1`.
6. Create a firewall rule called `bukka-allow-web` on `default`:
   - ingress, TCP `80` and `443` from `0.0.0.0/0`, for VMs with the network
     tag `bukka-web`.
   - TCP `22` (SSH) either not open at all, or open **only** to your own IP
     as a `/32`. Never to `0.0.0.0/0`.
   - No other inbound rules reach the API server. A rule with no target
     tags applies to every VM in the network.
7. Create one VM, `bukka-api-1`: `e2-micro` in `us-central1-a`, on the
   `default` subnet, with the network tag `bukka-web`, running as
   `bukka-api-server` with the `cloud-platform` scope, booting
   `projects/debian-cloud/global/images/family/debian-12`.
8. **No keys anywhere.** No service account key files, no private keys and
   no API keys in your startup script, your scripts or your commits.

### No surprise bills

9. Create a Pub/Sub topic called `bukka-billing-alerts` and a subscription
   on it (`bukka-billing-alerts-oncall`), so someone receives the alerts.
10. Create a budget called `bukka-spend-above-zero` on floci-gcp's billing
    account: `1` USD a month, with a threshold rule at `0.01` (1%, so the
    first alert comes at the first cent), that notifies
    `bukka-billing-alerts`.

### Write it down

11. Save every command you ran, in order, in `infra/cli/buk-38.sh`, so you
    (or a teammate) can rebuild all of this on a fresh floci-gcp with one
    command. You will need this in BUK-45.
12. In your pull request description, add a short design note under
    **Anything the reviewer should look at closely?** (a few sentences each):
    - Why a service account on the VM is safer than a key file on the VM
    - What an attacker on the server could and couldn't do as
      `bukka-api-server`
    - Why SSH is closed (or limited to your IP)

### Submit

13. Work on a branch called `buk-38-api-server-photo-access`, created from
    `upstream/apprentice/<your-github-username>`.
14. With floci-gcp running and your resources created, run
    `bash scripts/verify/buk-38.sh`. It writes
    `artifacts/buk-38-iam-audit.txt`.
15. Commit the audit file and `infra/cli/buk-38.sh`, push, and open a pull
    request into `apprentice/<your-github-username>`, titled
    `feat: give the API server read-only access to menu photos (BUK-38)`.

## Definition of done

- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved your pull request
- [ ] Your design note would convince a security reviewer that the old key problem can't
      happen again

## Notes

- **Why a service account instead of a key?** A VM that runs as a service
  account gets short-lived tokens from Google's metadata server, refreshed
  for it every hour. There is nothing to leak in a file, and when the VM is
  deleted the access goes with it.
- **Why so narrow?** If someone breaks into the API server, the service
  account decides how much damage they can do. Read-only on one bucket
  means the worst case is someone looking at pictures of jollof, not
  deleting them or reading the rest of the project. This is called least
  privilege. Granting on the bucket rather than the project is what keeps it
  to one bucket.
- **Why does "nobody can act as it" matter?** Anyone with Token Creator on
  the service account can mint its tokens from their laptop, and anyone with
  Key Admin can make it a key. That is the leaked-key problem by another
  route.
- **Starting floci-gcp** (a free, open-source Google Cloud emulator: no
  account, no token). The image is pinned so everyone gets the same
  behaviour; it's a dated build because the budgets API isn't in a release
  yet:
  ```bash
  docker run --rm -d --name floci-gcp -p 4588:4588 \
    -v /var/run/docker.sock:/var/run/docker.sock floci/floci-gcp:nightly-11172026
  ```
- **Pointing gcloud at it:** install the
  [gcloud CLI](https://cloud.google.com/sdk/docs/install), then, from the
  root of your bukka clone:
  ```bash
  source scripts/floci-gcp.env
  gcloud iam service-accounts list   # answers from floci-gcp: an empty list
  ```
  It sets the project (`bukka-prod`), a dummy access token and one endpoint
  per API, in this shell only. The token is a placeholder floci-gcp accepts:
  it isn't a secret and works nowhere else. Never `gcloud auth login` for
  these labs.
- **The budget:** `gcloud billing budgets create` can't be pointed at
  floci-gcp, so send the same request to the REST API with `curl`:
  ```bash
  curl -s -X POST "$FLOCI_GCP/v1/billingAccounts/$BUKKA_BILLING_ACCOUNT/budgets" \
    -H 'Content-Type: application/json' -d @budget.json
  ```
  `budget.json` holds `displayName`, `amount.specifiedAmount`
  (`currencyCode`, `units`), `thresholdRules` and `notificationsRule`
  (`pubsubTopic` as `projects/bukka-prod/topics/bukka-billing-alerts`,
  `schemaVersion` `"1.0"`). See the Budget API reference for the shape. On
  real Google Cloud the gcloud command does the same.
- floci-gcp forgets everything when it stops. That's why you save your
  commands in `infra/cli/buk-38.sh`: run it again and you're back. Run it on
  a fresh floci-gcp: names in a project are unique, so a second run stops
  at the first thing that already exists.
- The VM is simulated, so you won't SSH into it. The verify script checks
  how it's configured.
- Useful commands: `gcloud storage buckets create`,
  `gcloud iam service-accounts create`,
  `gcloud storage buckets add-iam-policy-binding`,
  `gcloud storage buckets get-iam-policy`,
  `gcloud projects get-iam-policy bukka-prod`,
  `gcloud iam service-accounts keys list`,
  `gcloud compute networks create --subnet-mode=custom`,
  `gcloud compute networks subnets create`,
  `gcloud compute firewall-rules create`,
  `gcloud compute instances create --service-account --scopes --tags`,
  `gcloud pubsub topics create`, `gcloud pubsub subscriptions create`.
- If Docker won't run on your machine, use a GitHub Codespace on your fork:
  Docker is already installed there.
