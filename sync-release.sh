#!/usr/bin/env bash
#
# Sync a GitHub release (tag, body, and assets) to atomgit.
#
# Required environment variables:
#   TAG            - release tag (e.g. v1.2.0)
#   OWNER          - repository owner (used in API paths)
#   REPO           - repository name
#   ATOMGIT_TOKEN  - atomgit API token
#   ATOMGIT_USER   - atomgit username for git push (may differ from OWNER
#                    when the repo belongs to an organization)
#   GH_TOKEN       - GitHub token (for gh CLI)
#   UPLOAD_JOBS    - max concurrent uploads (default: 4)

set -euo pipefail

# Default ATOMGIT_USER to OWNER when not set (personal repos)
ATOMGIT_USER="${ATOMGIT_USER:-$OWNER}"

API="https://api.atomgit.com/api/v5/repos/${OWNER}/${REPO}"
AUTH="access_token=${ATOMGIT_TOKEN}"

# Push tag to atomgit first.
# ATOMGIT_USER is the HTTP push username, which may differ from OWNER when
# the repository belongs to an organization.
echo "Pushing tag ${TAG} to atomgit ..."
git push --force \
  "https://${ATOMGIT_USER}:${ATOMGIT_TOKEN}@atomgit.com/${OWNER}/${REPO}.git" \
  "refs/tags/${TAG}:refs/tags/${TAG}"

# Get release notes from GitHub
BODY=$(gh release view "$TAG" --json body -q .body)

# Create release on atomgit (POST; PATCH returns 405)
PAYLOAD=$(jq -n --arg tag "$TAG" --arg body "$BODY" \
  '{tag_name: $tag, name: $tag, body: $body}')
echo "Creating release on atomgit ..."
# || true: release may already exist when re-running the workflow
curl -Sf -X POST \
  "${API}/releases?${AUTH}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" || true

# Download release assets from GitHub
tmpdir=$(mktemp -d)
gh release download "$TAG" --dir "$tmpdir/"

# Upload one asset to atomgit
upload_asset() {
  local file="$1"
  local name
  name=$(basename "$file")

  # Get pre-signed upload URL
  local upload_info
  upload_info=$(curl -Sf \
    "${API}/releases/${TAG}/upload_url?${AUTH}&file_name=${name}")

  local upload_url
  upload_url=$(echo "$upload_info" | jq -r '.url')
  local header_file
  header_file=$(mktemp)
  echo "$upload_info" | jq -r '.headers | to_entries[] | "header = \"\(.key): \(.value)\""' > "$header_file"

  # PUT file to the pre-signed URL
  echo "Uploading ${name} ..."
  curl -Sf -X PUT "$upload_url" \
    -K "$header_file" \
    --data-binary "@${file}"
  rm -f "$header_file"
  echo "Done: ${name}"
}
export -f upload_asset
export API AUTH TAG

# Filter out auto-generated source archives, then upload in parallel
find "$tmpdir" -type f \
  ! -name "${TAG}.tar.gz" \
  ! -name "${TAG}.zip" \
  ! -name "${TAG}.tar.bz2" \
  ! -name "${TAG}.tar" \
  | xargs -P "${UPLOAD_JOBS:-4}" -I {} bash -c 'upload_asset "$@"' _ {}

rm -rf "$tmpdir"
echo "Done: ${TAG} synced to atomgit."
