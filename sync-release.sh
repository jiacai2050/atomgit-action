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

# Initialize and validate environment variables.
: "${TAG:?TAG is required}"
: "${OWNER:?OWNER is required}"
: "${REPO:?REPO is required}"
: "${ATOMGIT_TOKEN:?ATOMGIT_TOKEN is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
ATOMGIT_USER="${ATOMGIT_USER:-$OWNER}"
UPLOAD_JOBS="${UPLOAD_JOBS:-4}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-}"

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
# AtomGit requires a non-empty release body.
if [[ -z "${BODY//[[:space:]]/}" ]]; then
  BODY="Release ${TAG}"
fi

# Create release on atomgit
# https://docs.atomgit.com/docs/apis/post-api-v-5-repos-owner-repo-releases
PAYLOAD=$(jq -n --arg tag "$TAG" --arg body "$BODY" \
  '{tag_name: $tag, name: $tag, body: $body}')
echo "Creating release on atomgit ..."
# || true: release may already exist when re-running the workflow
curl -Sf -X POST \
  "${API}/releases?${AUTH}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" || true

# Add the AtomGit release URL to the GitHub Actions job summary.
RELEASE_URL="https://atomgit.com/${OWNER}/${REPO}/releases/tag/${TAG}"
if [[ -n "$GITHUB_STEP_SUMMARY" ]]; then
  {
    printf '## AtomGit Release\n\n'
    printf '[%s](%s)\n' "$RELEASE_URL" "$RELEASE_URL"
  } >> "$GITHUB_STEP_SUMMARY"
fi

# Download release assets from GitHub
tmpdir=$(mktemp -d)
gh release download "$TAG" --dir "$tmpdir/"
uploaded_dir=$(mktemp -d)

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
    --retry 3 \
    --retry-delay 10 \
    --retry-all-errors \
    -K "$header_file" \
    --data-binary "@${file}"
  rm -f "$header_file"
  touch "$UPLOADED_DIR/$name"
  echo "Done: ${name}"
}
export -f upload_asset
export API AUTH TAG UPLOADED_DIR="$uploaded_dir"

# Filter out auto-generated source archives, then upload in parallel
if find "$tmpdir" -type f \
  ! -name "${TAG}.tar.gz" \
  ! -name "${TAG}.zip" \
  ! -name "${TAG}.tar.bz2" \
  ! -name "${TAG}.tar" \
  | xargs -P "$UPLOAD_JOBS" -I {} bash -e -c 'upload_asset "$@"' _ {}
then
  upload_status=0
else
  upload_status=$?
fi

if [[ -n "$GITHUB_STEP_SUMMARY" ]]; then
  {
    printf '\n### Uploaded assets\n\n'
    while IFS= read -r -d '' uploaded_file; do
      printf -- '- `%s`\n' "$(basename "$uploaded_file")"
    done < <(find "$uploaded_dir" -type f -print0)
  } >> "$GITHUB_STEP_SUMMARY"
fi

rm -rf "$tmpdir"
rm -rf "$uploaded_dir"
if (( upload_status != 0 )); then
  echo "One or more asset uploads failed (exit status: ${upload_status})." >&2
  exit "$upload_status"
fi
echo "Done: ${TAG} synced to atomgit."
