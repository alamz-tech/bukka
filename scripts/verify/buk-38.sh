#!/usr/bin/env bash
# BUK-38 verify: a service account (not a key) for the API server with read-only
# access to one bucket, a tight firewall, and a budget alert, all on floci-gcp.
# Run from the root of your bukka clone, with floci-gcp running and your
# resources created:
#   bash scripts/verify/buk-38.sh
# Writes artifacts/buk-38-iam-audit.txt. It only reads: nothing is changed.

set -uo pipefail

TICKET="BUK-38"
OUT="artifacts/buk-38-iam-audit.txt"
S="infra/cli/buk-38.sh"
FAILS=0
RESULTS=()
# Private keys (service account key files, PEM) and Google API keys.
KEY_RE='-----BEGIN (RSA |EC )?PRIVATE KEY-----|"private_key(_id)?"[[:space:]]*:|AIza[0-9A-Za-z_-]{35}'
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../floci-gcp.env
[ -f "$HERE/../floci-gcp.env" ] && source "$HERE/../floci-gcp.env"

pass() { RESULTS+=("PASS  $1"); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      → %s\n' "$2"; FAILS=$((FAILS + 1)); }
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

if [ ! -d .git ] || [ ! -f tickets/BUK-38.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi
echo "== $TICKET verify =="
echo

# Who you are on GitHub (reported at the end; used to find your bucket).
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
[[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]] && GH_USER="${BASH_REMATCH[1]}"

BUCKET=""
echo "floci-gcp at $FLOCI_GCP, project $CLOUDSDK_CORE_PROJECT"
if ! curl -s -m 5 -o /dev/null -H 'Authorization: Bearer x' "$FLOCI_GCP/compute/v1/projects/$CLOUDSDK_CORE_PROJECT/global/networks"; then
  fail "floci-gcp is answering" "Start floci-gcp and run: source scripts/floci-gcp.env (see the ticket's Notes)."
else
  pass "floci-gcp is answering"
  while IFS='|' read -r R NAME HINT; do
    case "$R" in
      SECTION) echo; echo "$NAME" ;;
      BUCKET) BUCKET="$NAME" ;;
      PASS) pass "$NAME" ;;
      FAIL) fail "$NAME" "$HINT" ;;
    esac
  done < <(python3 "$HERE/buk38_check.py" "$GH_USER" 2>&1 || echo "FAIL|The checks ran to the end|python3 $HERE/buk38_check.py crashed")
fi

# --- Your script and your repo ----------------------------------------------------
echo; echo "Your script and your repo"
if [ -f "$S" ]; then
  pass "$S exists"
  bash -n "$S" 2>/dev/null && pass "$S is valid bash" || fail "$S is valid bash" "bash -n $S shows the error."
  if grep -qE 'keys[[:space:]]+create|create-access-key' "$S"; then
    fail "$S doesn't create keys" "Remove 'gcloud iam service-accounts keys create': the server gets access from its service account."
  else
    pass "$S doesn't create keys"
  fi
else
  fail "$S exists" "Save every command you ran, in order, in $S."
fi
if git grep -qIE -e "$KEY_RE" 2>/dev/null || { [ -f "$S" ] && grep -qE -e "$KEY_RE" "$S"; }; then
  fail "No keys in your files" "git grep -nE 'PRIVATE KEY|private_key' shows where. Delete it, and treat that key as leaked."
else
  pass "No keys in your files"
fi
if git log --all -p 2>/dev/null | grep -E -e "$KEY_RE" >/dev/null; then
  fail "No keys in your commit history" "A key is in an old commit. Deleting the file isn't enough: the key is leaked. Ask your lead for help."
else
  pass "No keys in your commit history"
fi

# --- Branch and identity --------------------------------------------------------
echo
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$BRANCH" == buk-38-* ]]; then pass "On a BUK-38 branch ($BRANCH)"; else
  fail "On a BUK-38 branch" "You're on '$BRANCH'."; fi
if [ -n "$GH_USER" ]; then
  pass "GitHub recognises your SSH key as @$GH_USER"
else
  fail "GitHub recognises your SSH key" "Run: ssh-add, then try again (see BUK-14)."
fi
if [ -n "$GH_USER" ] && [ -n "$BUCKET" ] && [ "$BUCKET" != "bukka-menu-photos-$(lc "$GH_USER")" ]; then
  fail "The bucket is named after you" "Expected bukka-menu-photos-$(lc "$GH_USER"), found $BUCKET."
fi

mkdir -p artifacts
{
  echo "# $TICKET audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "script_sha256: $( [ -f "$S" ] && { sha256sum "$S" 2>/dev/null || shasum -a 256 "$S"; } | cut -d' ' -f1)"
  echo "fails: $FAILS"
  echo
  printf '%s\n' "${RESULTS[@]}"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add $S $OUT && git commit -m \"feat: give the API server read-only access to menu photos (BUK-38)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  exit 1
fi
