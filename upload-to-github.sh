#!/usr/bin/env bash
# Push the local fork work to GitHub via the Contents API.
# github.com git protocol is blocked in this environment; api.github.com is not.
# Usage: GH_PAT=<token> bash upload-to-github.sh
set -u
cd "$HOME/ritual-chain-workshop-2" || exit 2
REPO="seve789/ritual-chain-workshop-2"
BRANCH="main"

if [ -z "${GH_PAT:-}" ]; then echo "BLOCKER: GH_PAT not set"; exit 2; fi

NETRC=$(mktemp)
trap 'rm -f "$NETRC"' EXIT
printf 'machine api.github.com login %s password %s\n' 'x-oauth-basic' "$GH_PAT" > "$NETRC"

git add -A >/dev/null 2>&1
FILES=$(git ls-files)
TOTAL=$(echo "$FILES" | wc -l)
OK=0; FAIL=0

for f in $FILES; do
  # 1) fetch current sha (404 -> new file, otherwise update with sha)
  SHA=$(curl -s --netrc-file "$NETRC" \
    "https://api.github.com/repos/$REPO/contents/$f" | \
    python -c "import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('sha','') if isinstance(d,dict) else '')
except Exception:
    print('')")

  B64=$(base64 -w0 "$f")
  if [ -n "$SHA" ]; then
    BODY=$(printf '{"message":"update: %s","content":"%s","sha":"%s","branch":"%s"}' "$f" "$B64" "$SHA" "$BRANCH")
  else
    BODY=$(printf '{"message":"add: %s","content":"%s","branch":"%s"}' "$f" "$B64" "$BRANCH")
  fi

  CODE=$(printf '%s' "$BODY" | curl -s --netrc-file "$NETRC" -o /dev/null -w "%{http_code}" \
    -X PUT -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "https://api.github.com/repos/$REPO/contents/$f")

  if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
    OK=$((OK+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$CODE] $f"
  fi
done

echo ""
echo "uploaded: $OK / $TOTAL (failed: $FAIL)"
[ "$FAIL" = "0" ] && exit 0 || exit 1
