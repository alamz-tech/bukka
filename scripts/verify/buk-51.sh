#!/usr/bin/env bash
# BUK-51 verify: production on floci-gcp, built and managed by Terraform.
# Run from the root of your bukka clone, with floci-gcp running and the
# stack applied (terraform init + terraform apply in infra/terraform):
#   bash scripts/verify/buk-51.sh
# Writes artifacts/buk-51-terraform-audit.txt. It never changes your
# infrastructure: it only reads, and runs `terraform plan`.

set -uo pipefail

TICKET="BUK-51"
TF="infra/terraform"
OUT="artifacts/buk-51-terraform-audit.txt"
MODULES="network compute database storage billing"
FAILS=0
RESULTS=()
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../floci-gcp.env
[ -f "$HERE/../floci-gcp.env" ] && source "$HERE/../floci-gcp.env"
export TF_IN_AUTOMATION=1
export WORK; WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() { RESULTS+=("PASS  $1"); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      → %s\n' "$2"; FAILS=$((FAILS + 1)); }
check() { local name="$1" hint="$2"; shift 2; if "$@"; then pass "$name"; else fail "$name" "$hint"; fi; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi | cut -d' ' -f1; }
# One fingerprint over every .tf file (path and content), in a fixed order.
tf_sha() {
  find "$TF" -type f -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sha256 "$f")" "$f"
  done | sha256
}
tfc() { terraform -chdir="$TF" "$@"; }
gcpq() { curl -s -m 10 -H "Authorization: Bearer $CLOUDSDK_AUTH_ACCESS_TOKEN" "$FLOCI_GCP$1"; }
jq_py() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

if [ ! -d .git ] || [ ! -f tickets/BUK-51.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi
for cmd in terraform curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd is not installed. See the ticket's Notes."; exit 2; }
done
echo "== $TICKET verify =="
echo

# Secret-looking values in .tf/.tfvars: written-in passwords/keys, and
# variables named like secrets that carry a default.
secret_scan() {
  python3 - "$@" <<'PY'
import re, sys
bad = []
assign = re.compile(r'^\s*"?([A-Za-z0-9_]*(password|passwd|secret|token|access_key|private_key|credentials)[A-Za-z0-9_]*)"?\s*=\s*"([^"$]+)"', re.I)
var = re.compile(r'variable\s+"([^"]+)"\s*\{', re.I)
for path in sys.argv[1:]:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for n, line in enumerate(text.splitlines(), 1):
        if re.search(r'-----BEGIN (RSA |EC )?PRIVATE KEY-----|"private_key(_id)?"\s*:|AIza[0-9A-Za-z_-]{35}', line):
            bad.append(f"{path}:{n}: a private key or API key")
        m = assign.match(line)
        if m and not m.group(1).lower().startswith("skip_"):
            bad.append(f"{path}:{n}: {m.group(1)} is written in")
    for m in var.finditer(text):
        if not re.search(r'password|passwd|secret|token|key', m.group(1), re.I):
            continue
        depth, i = 1, m.end()
        while i < len(text) and depth:
            depth += {"{": 1, "}": -1}.get(text[i], 0); i += 1
        if re.search(r'^\s*default\s*=', text[m.end():i], re.M):
            bad.append(f"{path}: variable \"{m.group(1)}\" has a default value")
print("\n".join(bad))
PY
}

# --- Project layout -------------------------------------------------------------
echo "Project layout"
MISSING=""
for f in versions.tf backend.tf main.tf variables.tf outputs.tf; do [ -f "$TF/$f" ] || MISSING="$MISSING $f"; done
check "$TF has versions.tf, backend.tf, main.tf, variables.tf and outputs.tf" "Missing:$MISSING" [ -z "$MISSING" ]
for m in $MODULES; do
  MISSING=""
  for f in main.tf variables.tf outputs.tf; do [ -f "$TF/modules/$m/$f" ] || MISSING="$MISSING $f"; done
  check "modules/$m has main.tf, variables.tf and outputs.tf" "Missing in $TF/modules/$m:$MISSING" [ -z "$MISSING" ]
done
NOT_CALLED=""
for m in $MODULES; do
  grep -qE "source[[:space:]]*=[[:space:]]*\"\./modules/$m/?\"" "$TF/main.tf" 2>/dev/null || NOT_CALLED="$NOT_CALLED $m"
done
check "The root main.tf calls all five modules" "Not called from $TF/main.tf:$NOT_CALLED" [ -z "$NOT_CALLED" ]
UNDOC=$(python3 - "$TF/variables.tf" <<'PY'
import re, sys
try:
    text = open(sys.argv[1]).read()
except OSError:
    print("(no variables.tf)"); sys.exit()
out = []
for m in re.finditer(r'variable\s+"([^"]+)"\s*\{', text):
    depth, i = 1, m.end()
    while i < len(text) and depth:
        depth += {"{": 1, "}": -1}.get(text[i], 0); i += 1
    body = text[m.end():i]
    if not re.search(r'^\s*type\s*=', body, re.M) or not re.search(r'^\s*description\s*=', body, re.M):
        out.append(m.group(1))
print(" ".join(out))
PY
)
check "Every root variable has a type and a description" "Add them to: $UNDOC" [ -z "$UNDOC" ]
HARD=$(grep -rnoE '"(projects/[^"]*/(networks|subnetworks|firewalls|instances)/[^"]+|[a-z0-9-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com)"' --include='*.tf' "$TF" 2>/dev/null | grep -v '/.terraform/' | head -3)
check "No hard-coded resource IDs or service account emails (modules are wired through outputs)" "Pass IDs from one module's outputs into another in main.tf. Found: $HARD" [ -z "$HARD" ]
if [ -f "$TF/backend.tf" ] && grep -qE 'backend[[:space:]]+"gcs"' "$TF/backend.tf" && grep -qE '^[[:space:]]*prefix[[:space:]]*=' "$TF/backend.tf"; then
  pass "backend.tf uses the gcs backend with a prefix"
else
  fail "backend.tf uses the gcs backend with a prefix" "terraform { backend \"gcs\" { bucket = \"bukka-tfstate-<you>\" prefix = \"prod\" } }"
fi
if [ -f "$TF/backend.tf" ] && ! grep -vE '^[[:space:]]*(#|//)' "$TF/backend.tf" | grep -qiE 'localhost|floci|4588|custom_endpoint|access_token|credentials'; then
  pass "backend.tf has no floci-gcp settings or credentials (they go in a -backend-config file)"
else
  fail "backend.tf has no floci-gcp settings or credentials (they go in a -backend-config file)" "Move storage_custom_endpoint into backend-floci.hcl and pass it to terraform init."
fi

# --- Code quality -----------------------------------------------------------------
echo; echo "Code quality"
if FMT=$(tfc fmt -check -recursive 2>&1); then pass "terraform fmt -check -recursive"; else
  fail "terraform fmt -check -recursive" "Run: terraform -chdir=$TF fmt -recursive (needs formatting: $(echo $FMT | head -c 150))"; fi
INITED=""
if [ -d "$TF/.terraform" ]; then INITED=1; fi
if [ -z "$INITED" ]; then
  fail "terraform validate" "Run terraform init in $TF first (see the ticket's Notes)."
elif VAL=$(tfc validate -no-color 2>&1); then
  pass "terraform validate"
else
  fail "terraform validate" "$(echo "$VAL" | grep -m1 -iE 'error' | head -c 200)"
fi

# --- Secrets and git hygiene --------------------------------------------------------
echo; echo "Secrets and git hygiene"
TRACKED=$(git ls-files)
STATE_FILES=$(echo "$TRACKED" | grep -E '\.tfstate(\.|$)|(^|/)\.terraform/' || true)
check "No state files or .terraform/ directories are tracked by git" "git rm --cached them: $(echo $STATE_FILES | head -c 150)" [ -z "$STATE_FILES" ]
IGN=""
for p in "$TF/terraform.tfstate" "$TF/terraform.tfstate.backup" "$TF/.terraform/providers" "$TF/modules/network/.terraform/x" "$TF/terraform.tfvars" "$TF/secrets.tfvars.json"; do
  git check-ignore -q --no-index "$p" || IGN="$IGN ${p#$TF/}"
done
check ".gitignore covers *.tfstate, .terraform/ and *.tfvars" "Not ignored:$IGN" [ -z "$IGN" ]
if [ -f "$TF/.terraform.lock.hcl" ] && ! git check-ignore -q --no-index "$TF/.terraform.lock.hcl"; then
  pass ".terraform.lock.hcl exists and isn't ignored (commit it)"
else
  fail ".terraform.lock.hcl exists and isn't ignored (commit it)" "terraform init writes it. It pins the provider versions for your teammates."
fi
SCAN_FILES=$( { find "$TF" -type f \( -name '*.tf' -o -name '*.hcl' \) -not -path '*/.terraform/*' 2>/dev/null; echo "$TRACKED" | grep -E '\.tfvars(\.json)?$'; } | sort -u)
# shellcheck disable=SC2086
LEAKS=$(secret_scan $SCAN_FILES)
check "No passwords, secret defaults or access keys in the Terraform code" "$(echo "$LEAKS" | head -3 | tr '\n' ';')" [ -z "$LEAKS" ]
KEY_RE='-----BEGIN (RSA |EC )?PRIVATE KEY-----|"private_key(_id)?"[[:space:]]*:|AIza[0-9A-Za-z_-]{35}'
if git grep -qE -e "$KEY_RE" 2>/dev/null || git log --all -p 2>/dev/null | grep -E -e "$KEY_RE" | grep -q '^+'; then
  fail "No keys (service account keys, private keys, API keys) in any file or commit" "Remove it, and treat that key as leaked."
else
  pass "No keys (service account keys, private keys, API keys) in any file or commit"
fi
OLD=""
for s in buk-38 buk-42 buk-45; do [ -e "infra/cli/$s.sh" ] && OLD="$OLD infra/cli/$s.sh"; done
check "infra/cli/buk-38.sh, buk-42.sh and buk-45.sh are removed" "git rm$OLD" [ -z "$OLD" ]
check "infra/db/orders-db.sh is kept" "Terraform only manages the Google Cloud side. Keep the BUK-45 database script." [ -f infra/db/orders-db.sh ]

# --- Remote state ---------------------------------------------------------------------
echo; echo "Remote state (floci-gcp at $FLOCI_GCP)"
UP=""
if curl -s -m 5 -o /dev/null -H 'Authorization: Bearer x' "$FLOCI_GCP/compute/v1/projects/$CLOUDSDK_CORE_PROJECT/global/networks"; then
  pass "floci-gcp is answering"; UP=1
else
  fail "floci-gcp is answering" "Start floci-gcp and run: source scripts/floci-gcp.env (see the ticket's Notes)."
fi
BE_BUCKET=$(sed -nE 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$TF/backend.tf" 2>/dev/null | head -1)
BE_PREFIX=$(sed -nE 's/^[[:space:]]*prefix[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$TF/backend.tf" 2>/dev/null | head -1)
STATE_BUCKET=""
if [ -n "$UP" ]; then
  SB=$( [ -n "$BE_BUCKET" ] && gcpq "/storage/v1/b/$BE_BUCKET")
  if [[ "$BE_BUCKET" == bukka-tfstate-* ]] && [ "$(jq_py 'd.get("name","")' <<< "${SB:-null}")" = "$BE_BUCKET" ]; then
    STATE_BUCKET="$BE_BUCKET"; pass "The state bucket exists ($STATE_BUCKET)"
  else
    fail "The state bucket exists" "backend.tf names '${BE_BUCKET:-nothing}'. Create bukka-tfstate-<you> before terraform init."
  fi
fi
if [ -n "$STATE_BUCKET" ]; then
  V=$(jq_py '(d.get("versioning") or {}).get("enabled", False)' <<< "$SB")
  check "The state bucket has versioning on" "gcloud storage buckets update gs://$STATE_BUCKET --versioning" [ "$V" = "True" ]
  PRIV=$(jq_py '(d.get("iamConfiguration") or {}).get("publicAccessPrevention") == "enforced" and ((d.get("iamConfiguration") or {}).get("uniformBucketLevelAccess") or {}).get("enabled", False)' <<< "$SB")
  check "The state bucket is private (uniform access, public access prevention enforced)" \
    "gcloud storage buckets update gs://$STATE_BUCKET --uniform-bucket-level-access --public-access-prevention" [ "$PRIV" = "True" ]
  OBJ="${BE_PREFIX:+$BE_PREFIX/}default.tfstate"
  GOT=$(gcpq "/storage/v1/b/$STATE_BUCKET/o/$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$OBJ")" | jq_py 'd.get("name","")')
  check "Terraform's state is in the bucket ($OBJ)" "No object at gs://$STATE_BUCKET/$OBJ. Did terraform init use the gcs backend?" [ "$GOT" = "$OBJ" ]
fi

# --- What's in floci-gcp ------------------------------------------------------------
BUCKET=""
if [ -n "$UP" ]; then
  GH_GUESS=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 | sed -nE 's/^Hi ([A-Za-z0-9-]+)!.*/\1/p')
  while IFS='|' read -r R NAME HINT; do
    case "$R" in
      SECTION) echo; echo "$NAME" ;;
      BUCKET) [ -n "$NAME" ] && BUCKET="$NAME" ;;
      PASS) pass "$NAME" ;;
      FAIL) fail "$NAME" "$HINT" ;;
    esac
  done < <(python3 "$HERE/buk51_check.py" "$GH_GUESS" 2>&1 || echo "FAIL|The checks ran to the end|python3 $HERE/buk51_check.py crashed")
fi

# --- Terraform owns it -----------------------------------------------------------------
echo; echo "Terraform owns it"
if [ -n "$INITED" ] && [ -n "$UP" ]; then
  STATE=$(tfc state list 2>/dev/null)
  NOSTATE=""
  for m in $MODULES; do echo "$STATE" | grep -q "^module\.$m\." || NOSTATE="$NOSTATE $m"; done
  check "Every module has resources in the Terraform state" "Nothing in state for:$NOSTATE. Did terraform apply finish?" [ -z "$NOSTATE" ]
  OUTS=$(tfc output -json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(str(v["value"]) for v in json.load(sys.stdin).values()))' 2>/dev/null)
  MISSING_OUT=""
  for v in "networks/bukka-prod-vpc" "instances/bukka-api-1" "firewalls/bukka-db-allow-api" "${BUCKET:-bukka-menu-photos-?}"; do
    [[ " $OUTS " == *"$v"* ]] || MISSING_OUT="$MISSING_OUT ${v##*/}"
  done
  check "Outputs give bukka-prod-vpc, bukka-api-1, bukka-db-allow-api and the bucket name" "Missing from terraform output:$MISSING_OUT" [ -z "$MISSING_OUT" ]
  tfc plan -detailed-exitcode -input=false -no-color > "$WORK"/plan.txt 2>&1; RC=$?
  if [ "$RC" -eq 0 ]; then
    pass "terraform plan shows no changes"
  elif [ "$RC" -eq 2 ]; then
    fail "terraform plan shows no changes" "$(grep -m1 -E '^Plan:' "$WORK/plan.txt"). Something drifted, or the code doesn't match what's built. Run terraform plan and read it."
  else
    fail "terraform plan shows no changes" "terraform plan failed: $(grep -m1 -iE 'error' "$WORK/plan.txt" | head -c 200)"
  fi
else
  fail "Every module has resources in the Terraform state" "Needs terraform init and floci-gcp."
  fail "Outputs give bukka-prod-vpc, bukka-api-1, bukka-db-allow-api and the bucket name" "Needs terraform init and floci-gcp."
  fail "terraform plan shows no changes" "Needs terraform init and floci-gcp."
fi

# --- Branch and identity ------------------------------------------------------------------
echo
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$BRANCH" == buk-51-* ]]; then pass "On a BUK-51 branch ($BRANCH)"; else
  fail "On a BUK-51 branch" "You're on '$BRANCH'."; fi
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then
  GH_USER="${BASH_REMATCH[1]}"; pass "GitHub recognises your SSH key as @$GH_USER"
else
  fail "GitHub recognises your SSH key" "Run: ssh-add, then try again (see BUK-14)."
fi
if [ -n "$GH_USER" ]; then
  ME=$(echo "$GH_USER" | tr '[:upper:]' '[:lower:]')
  [ -n "${BUCKET:-}" ] && [ "$BUCKET" != "bukka-menu-photos-$ME" ] && fail "The photos bucket is named after you" "Expected bukka-menu-photos-$ME, found $BUCKET."
  [ -n "$BE_BUCKET" ] && [ "$BE_BUCKET" != "bukka-tfstate-$ME" ] && fail "The state bucket is named after you" "Expected bukka-tfstate-$ME, backend.tf says $BE_BUCKET."
fi

mkdir -p artifacts
{
  echo "# $TICKET audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "terraform_sha256: $(tf_sha)"
  echo "terraform_version: $(terraform version 2>/dev/null | head -1)"
  echo "fails: $FAILS"
  echo
  printf '%s\n' "${RESULTS[@]}"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add infra/ $OUT && git commit -m \"feat: manage production infrastructure with Terraform (BUK-51)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  exit 1
fi
