#!/usr/bin/env bash

# Decide whether the release workflow needs to build.
# Exits with 0 to build and 1 to skip.
#
# Reads from the environment:
#   DEVICE_NAME         Device code name
#   GRAPHENEOS_VERSION  GrapheneOS version to release
#   REPOSITORY          GitHub repository as `owner/name`
#   ROOT                "true" builds the magisk flavor, anything else rootless
#   FORCE_UPDATE        "true" rebuilds the current version on module updates
#
# Writes FORCE_REBUILD=true to GITHUB_ENV when an existing asset gets replaced.

set -o nounset -o pipefail -o errexit

build_flavor=$([[ "${ROOT:-false}" == "true" ]] && echo 'magisk' || echo 'rootless')

server_ref=''
for candidate_ref in gh-pages origin/gh-pages; do
  if git rev-parse --verify --quiet "${candidate_ref}^{commit}" >/dev/null; then
    server_ref="${candidate_ref}"
    break
  fi
done

if [[ -n "${server_ref}" ]]; then
  published_location=$(
    git show "${server_ref}:${build_flavor}/${DEVICE_NAME}.json" 2>/dev/null |
      jq -r '.full.location_ota // empty' || true
  )
  published_version=$(sed -nE 's#^.*/releases/download/([0-9]+)/.*#\1#p' <<<"${published_location}")

  if [[ "${published_version}" =~ ^[0-9]+$ && "${GRAPHENEOS_VERSION}" =~ ^[0-9]+$ ]] &&
    ((10#${GRAPHENEOS_VERSION} < 10#${published_version})); then
    echo -e "::error::Refusing to replace published GrapheneOS version ${published_version} with older version ${GRAPHENEOS_VERSION}."
    exit 1
  fi
fi

# Check if the tag exists
if ! git show-ref --tags "${GRAPHENEOS_VERSION}" --quiet; then
  echo -e "Tag with GrapheneOS version ${GRAPHENEOS_VERSION} does not exist. Creating one..."
  exit 0
fi

echo -e "Tag with GrapheneOS version ${GRAPHENEOS_VERSION} already exists. Looking for assets..."
# Fetch the release information for the tag
repo_url="https://api.github.com/repos/${REPOSITORY}/releases/tags/${GRAPHENEOS_VERSION}"
# `.assets[]?` keeps the script alive when the tag has no release
existing_assets=$(curl -sL "${repo_url}" | jq -r '.assets[]?.name')

# Assets of the current flavor, e.g. bluejay-2026081300-rootless-abc1234.zip
zip_regex="^${DEVICE_NAME}-${GRAPHENEOS_VERSION}-${build_flavor}-.*\.zip$"
existing_zip=$(grep -E "${zip_regex}" <<<"${existing_assets}" | head -n1 || true)
existing_csig=$(grep -E "${zip_regex%$}\.csig$" <<<"${existing_assets}" | head -n1 || true)

if [[ -z "${existing_zip}" || -z "${existing_csig}" ]]; then
  echo -e "Assets with \`${build_flavor}\` flavor are missing. Proceeding with build..."
  exit 0
fi

if [[ "${FORCE_UPDATE:-false}" != "true" ]]; then
  echo -e "::error::Asset with \`${build_flavor}\` flavor already exists!"
  exit 1
fi

# FORCE_UPDATE is enabled: rebuild the current GrapheneOS version only if a
# module got an update since the commit that built the existing asset.
# The commit hash is part of the asset name, see generate_ota_info.
last_commit=$(sed -E 's/^.*-([0-9a-f]{7,40})(-dirty)?\.zip$/\1/' <<<"${existing_zip}")

if ! git cat-file -e "${last_commit}^{commit}" 2>/dev/null; then
  echo -e "Commit \`${last_commit}\` from asset \`${existing_zip}\` is unknown. Proceeding with rebuild..."
  echo "FORCE_REBUILD=true" >>"${GITHUB_ENV:-/dev/null}"
  exit 0
fi

module_changes=$(git diff "${last_commit}" HEAD -- src/declarations.sh | grep -E '^[+-]VERSION\[' || true)
if [[ -z "${module_changes}" ]]; then
  echo -e "No module updates since \`${last_commit}\`. Skipping rebuild..."
  exit 1
fi

echo -e "Module updates since \`${last_commit}\`:\n${module_changes}\nProceeding with rebuild..."
echo "FORCE_REBUILD=true" >>"${GITHUB_ENV:-/dev/null}"
