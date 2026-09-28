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
if ! [[ "$UPLOAD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "UPLOAD_JOBS must be a positive integer." >&2
  exit 1
fi

API="https://api.atomgit.com/api/v5/repos/${OWNER}/${REPO}"
AUTH="access_token=${ATOMGIT_TOKEN}"
tmpdir=""
uploaded_dir=""
failed_dir=""
release_response=""
cleanup() {
  [[ -z "$tmpdir" ]] || rm -rf "$tmpdir"
  [[ -z "$uploaded_dir" ]] || rm -rf "$uploaded_dir"
  [[ -z "$release_response" ]] || rm -f "$release_response"
}
trap cleanup EXIT

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
release_response=$(mktemp)
release_status=$(curl -sS -o "$release_response" -w '%{http_code}' -X POST \
  "${API}/releases?${AUTH}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")
case "$release_status" in
  2??)
    ;;
  409|422)
    echo "Release ${TAG} already exists on atomgit; continuing."
    echo "Atomgit response:"
    cat "$release_response"
    ;;
  *)
    cat "$release_response" >&2
    echo "Failed to create release on atomgit (HTTP ${release_status})." >&2
    exit 1
    ;;
esac
rm -f "$release_response"
release_response=""

# Add the AtomGit release URL to the GitHub Actions job summary.
RELEASE_URL="https://atomgit.com/${OWNER}/${REPO}/releases/${TAG}"
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
failed_dir=$(mktemp -d)

# Upload one asset to atomgit
upload_asset() {
  local file="$1"
  local name
  name=$(basename "$file")

  # Get pre-signed upload URL
  local upload_info
  if ! upload_info=$(curl -sS --fail-with-body --get \
    "${API}/releases/${TAG}/upload_url?${AUTH}" \
    --data-urlencode "file_name=${name}"); then
    touch "$FAILED_DIR/$name"
    return 1
  fi

  local upload_url
  upload_url=$(echo "$upload_info" | jq -r '.url')
  local header_file
  header_file=$(mktemp)
  echo "$upload_info" | jq -r '.headers | to_entries[] | "header = \"\(.key): \(.value)\""' > "$header_file"

  # PUT file to the pre-signed URL
  echo "Uploading ${name} ..."
  if ! curl -S --fail-with-body -X PUT "$upload_url" \
      --retry 3 \
      --retry-delay 10 \
      --retry-all-errors \
      -K "$header_file" \
      --data-binary "@${file}"; then
    rm -f "$header_file"
    touch "$FAILED_DIR/$name"
    return 1
  fi
  rm -f "$header_file"
  touch "$UPLOADED_DIR/$name"
  echo "Done: ${name}"
}
export -f upload_asset
export API AUTH TAG UPLOADED_DIR="$uploaded_dir" FAILED_DIR="$failed_dir"

# Filter out auto-generated source archives, then upload in parallel
if find "$tmpdir" -type f \
  ! -name "${TAG}.tar.gz" \
  ! -name "${TAG}.zip" \
  ! -name "${TAG}.tar.bz2" \
  ! -name "${TAG}.tar" \
  -print0 \
  | xargs -0 -r -P "$UPLOAD_JOBS" -I {} bash -e -c \
    "upload_asset \"\$1\"" _ {}
then
  upload_status=0
else
  upload_status=$?
fi

if [[ -n "$GITHUB_STEP_SUMMARY" ]]; then
  {
    printf '\n### Uploaded assets\n\n'
    while IFS= read -r -d '' uploaded_file; do
      printf -- "- \`%s\`\n" "$(basename "$uploaded_file")"
    done < <(find "$uploaded_dir" -type f -print0 | sort -z)
    failed_file=$(find "$failed_dir" -type f -print -quit)
    if [[ -n "$failed_file" ]]; then
      printf '\n### Failed assets\n\n'
      while IFS= read -r -d '' failed_file; do
        printf -- "- \`%s\`\n" "$(basename "$failed_file")"
      done < <(find "$failed_dir" -type f -print0 | sort -z)
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if (( upload_status != 0 )); then
  echo "One or more asset uploads failed (exit status: ${upload_status})." >&2
  exit "$upload_status"
fi
echo "Done: ${TAG} synced to atomgit."
