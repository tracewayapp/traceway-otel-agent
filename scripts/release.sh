#!/usr/bin/env bash
# Cut a new release:
#   1. Show current version from builder-config.yaml.
#   2. Prompt for the new version.
#   3. Update builder-config.yaml, commit, tag, push.
#
# Usage (from repo root):
#   bash scripts/release.sh
#
# Override the branch (default: main):
#   RELEASE_BRANCH=next bash scripts/release.sh

set -euo pipefail

CONFIG="builder-config.yaml"
BRANCH="${RELEASE_BRANCH:-main}"

err() { printf 'release: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'release: %s\n' "$*"; }

# --- sanity checks -----------------------------------------------------------

[ -f "$CONFIG" ]                      || err "$CONFIG not found — run from repo root"
command -v git >/dev/null 2>&1        || err "git not on PATH"

current_branch="$(git branch --show-current)"
[ "$current_branch" = "$BRANCH" ] \
  || err "on branch '$current_branch', expected '$BRANCH' (override with RELEASE_BRANCH=<name>)"

if ! git diff --quiet || ! git diff --cached --quiet; then
  err "working tree is dirty — commit or stash first"
fi

log "syncing with origin/$BRANCH"
git fetch --quiet origin "$BRANCH"
if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH")" ]; then
  err "local $BRANCH is out of sync with origin/$BRANCH — pull or push first"
fi

# --- current version ---------------------------------------------------------

current="$(awk '/^  version:/ {print $2; exit}' "$CONFIG")"
[ -n "$current" ] || err "could not parse version from $CONFIG"
log "current version: $current"

# --- prompt for new ----------------------------------------------------------

printf 'new version (no leading "v", e.g. 0.2.0): '
read -r new
new="$(printf '%s' "$new" | tr -d '[:space:]')"

# semver-ish: X.Y.Z, optionally -prerelease or +build
if ! printf '%s' "$new" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'; then
  err "'$new' doesn't look like a valid version (expected X.Y.Z)"
fi
[ "$new" != "$current" ] || err "new version matches current ($current)"

tag="v$new"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  err "tag $tag already exists locally"
fi
if git ls-remote --tags --exit-code origin "$tag" >/dev/null 2>&1; then
  err "tag $tag already exists on origin"
fi

# --- summary + confirm -------------------------------------------------------

cat <<SUMMARY

about to:
  • bump   $CONFIG: $current → $new
  • commit "release: $tag"
  • tag    $tag (annotated)
  • push   $BRANCH + $tag to origin

SUMMARY

printf 'proceed? (y/N): '
read -r confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *) log "aborted"; exit 0 ;;
esac

# --- apply -------------------------------------------------------------------

log "updating $CONFIG"
tmp="$(mktemp)"
awk -v v="$new" '
  /^  version:/ && !done { print "  version: " v; done=1; next }
  { print }
' "$CONFIG" > "$tmp"
mv "$tmp" "$CONFIG"

new_in_file="$(awk '/^  version:/ {print $2; exit}' "$CONFIG")"
[ "$new_in_file" = "$new" ] \
  || err "failed to update $CONFIG (still reads '$new_in_file')"

git add "$CONFIG"
git commit -m "release: $tag"
git tag -a "$tag" -m "Release $tag"

log "pushing $BRANCH"
git push origin "$BRANCH"
log "pushing $tag"
git push origin "$tag"

cat <<DONE

✓ $tag pushed.

Next:
  • release.yml builds the 5 platform tarballs (watch: gh run watch)
  • once the GitHub Release is published, publish-install.yml rebakes $tag
    into install.tracewayapp.com/install.sh
DONE
