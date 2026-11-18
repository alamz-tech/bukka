#!/usr/bin/env bash
# BUK-42 verify: the production VPC, its web and database subnets, and the
# firewall rules that keep the database tier off the internet, on floci-gcp.
# Run from the root of your bukka clone, with floci-gcp running and your
# network created:
#   bash scripts/verify/buk-42.sh
# Writes artifacts/buk-42-network-audit.txt.

set -uo pipefail

TICKET="BUK-42"
OUT="artifacts/buk-42-network-audit.txt"
S="infra/cli/buk-42.sh"
FAILS=0
RESULTS=()
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../floci-gcp.env
[ -f "$HERE/../floci-gcp.env" ] && source "$HERE/../floci-gcp.env"

pass() { RESULTS+=("PASS  $1"); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      → %s\n' "$2"; FAILS=$((FAILS + 1)); }

if [ ! -d .git ] || [ ! -f tickets/BUK-42.md ]; then
  echo "Run this from the root of your bukka clone (the folder with tickets/ in it)."
  exit 2
fi
echo "== $TICKET verify =="
echo

echo "floci-gcp at $FLOCI_GCP, project $CLOUDSDK_CORE_PROJECT"
VPC=""
if ! curl -s -m 5 -o /dev/null -H 'Authorization: Bearer x' "$FLOCI_GCP/compute/v1/projects/$CLOUDSDK_CORE_PROJECT/global/networks"; then
  fail "floci-gcp is answering" "Start floci-gcp and run: source scripts/floci-gcp.env (see the ticket's Notes)."
else
  pass "floci-gcp is answering"
  while IFS='|' read -r R NAME HINT; do
    case "$R" in
      SECTION) echo; echo "$NAME" ;;
      VPC) VPC="$NAME" ;;
      PASS) pass "$NAME" ;;
      FAIL) fail "$NAME" "$HINT" ;;
    esac
  done < <(python3 "$HERE/buk42_check.py" 2>&1 || echo "FAIL|The checks ran to the end|python3 $HERE/buk42_check.py crashed")
fi

# --- Your script ----------------------------------------------------------------
echo; echo "Your script"
if [ -f "$S" ]; then
  pass "$S exists"
  bash -n "$S" 2>/dev/null && pass "$S is valid bash" || fail "$S is valid bash" "bash -n $S shows the error."
else
  fail "$S exists" "Save every command you ran, in order, in $S."
fi

# --- Branch and identity --------------------------------------------------------
echo
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$BRANCH" == buk-42-* ]]; then pass "On a BUK-42 branch ($BRANCH)"; else
  fail "On a BUK-42 branch" "You're on '$BRANCH'."; fi
GH_USER=""
GH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
if [[ "$GH_OUT" =~ Hi\ ([A-Za-z0-9-]+)! ]]; then
  GH_USER="${BASH_REMATCH[1]}"; pass "GitHub recognises your SSH key as @$GH_USER"
else
  fail "GitHub recognises your SSH key" "Run: ssh-add, then try again (see BUK-14)."
fi

mkdir -p artifacts
{
  echo "# $TICKET audit"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "github_user: ${GH_USER:-unknown}"
  echo "branch: $BRANCH"
  echo "script_sha256: $( [ -f "$S" ] && { sha256sum "$S" 2>/dev/null || shasum -a 256 "$S"; } | cut -d' ' -f1)"
  echo "vpc_id: ${VPC:-none}"
  echo "fails: $FAILS"
  echo
  printf '%s\n' "${RESULTS[@]}"
} > "$OUT"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All checks passed. Wrote $OUT."
  echo "Next: git add $S $OUT && git commit -m \"feat: create production VPC with public and private subnets (BUK-42)\""
  exit 0
else
  echo "$FAILS check(s) failed. Fix the items marked ✗ and run this again."
  exit 1
fi
