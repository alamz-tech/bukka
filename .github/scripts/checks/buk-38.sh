#!/usr/bin/env bash
# BUK-38 checks on the pull request: the audit (the API server's service
# account, firewall and budget), and that the committed infra/cli/buk-38.sh
# is the one that was audited and has no keys in it.

set -uo pipefail

F="artifacts/buk-38-iam-audit.txt"
S="infra/cli/buk-38.sh"
EXPECTED_PASSES=29
FAILS=0
ok()  { echo "✓ $1"; }
bad() { echo "::error::$1"; echo "✗ $1"; FAILS=$((FAILS + 1)); }
lc()  { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
TICKET_N=$(basename "$0" .sh)

[ -f "$F" ] || { bad "$F is missing. Run 'bash scripts/verify/$TICKET_N.sh' with floci-gcp running and commit what it writes."; exit 1; }
ok "$F is present"

if grep -q '^FAIL' "$F"; then
  bad "The audit has failed checks:"; grep '^FAIL' "$F" | sed 's/^/    /'
fi
PASSES=$(grep -c '^PASS' "$F" || true)
[ "$PASSES" -ge "$EXPECTED_PASSES" ] && ok "All $EXPECTED_PASSES checks passed" \
  || bad "Expected $EXPECTED_PASSES passed checks in the audit, found $PASSES."

GH_USER=$(sed -n 's/^github_user: //p' "$F")
[ -n "$GH_USER" ] && [ "$(lc "$GH_USER")" = "$(lc "$PR_AUTHOR")" ] && ok "The audit was made with @$PR_AUTHOR's SSH key" \
  || bad "The audit says it was run by @$GH_USER, but this pull request is from @$PR_AUTHOR."

if [ ! -f "$S" ]; then
  bad "$S is missing from the pull request."
else
  [ "$(sha256sum "$S" | cut -d' ' -f1)" = "$(sed -n 's/^script_sha256: //p' "$F")" ] \
    && ok "$S is the version that was audited" \
    || bad "$S changed after the audit. Rebuild on a fresh floci-gcp with it, run the verify script again and commit the new audit."
  if grep -nE 'keys[[:space:]]+create|create-access-key' "$S"; then
    bad "$S creates a key. The server gets its access from its service account, not a key."
  else
    ok "$S creates no keys"
  fi
fi

# Keys anywhere in the pull request's files: service account key files,
# PEM private keys, Google API keys.
LEAKS=$(git grep -nIE -e '-----BEGIN (RSA |EC )?PRIVATE KEY-----|"private_key(_id)?"[[:space:]]*:|AIza[0-9A-Za-z_-]{35}' 2>/dev/null || true)
if [ -n "$LEAKS" ]; then
  bad "There's a key in the pull request. Remove it, and treat it as leaked: it must be deleted on the service account."
  echo "$LEAKS" | cut -d: -f1,2 | sed 's/^/    /'
else
  ok "No keys in the repo"
fi

[ "$FAILS" -eq 0 ]
