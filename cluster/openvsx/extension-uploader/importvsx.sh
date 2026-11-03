#!/usr/bin/env bash

QUERY_RESULT_SIZE=200

function checkLocalVSX() {
  echo "Waiting for OpenVSX server..."
  until curl -sf "${OVSX_REGISTRY_URL}/user" > /dev/null 2>&1
  do
    echo "  ...not ready, retrying in 5s"
    sleep 5
  done
  echo "OpenVSX server is ready"
}

function createNamespace() {
  local namespace=${1}
  local check_namespace=$(curl -sLS "${OVSX_REGISTRY_URL}/api/${namespace}" -H 'accept: application/json' | jq -c '. | has("error")')
  if [[ ${check_namespace} == "true" ]]
  then
    ovsx create-namespace ${namespace}
  fi
}

function publishExtension() {
  local vsix_file=${1}
  ovsx publish --skip-duplicate ${WORK_DIR}/${vsix_file}
}

function downloadExtension() {

  local url=${1}
  local fileName=${2}
  local namespace=${3}

  echo "Downloading: ${url}"
  curl -sL "${url}" -o "${WORK_DIR}/${fileName}"
  createNamespace ${namespace}
  publishExtension ${fileName}
}

function checkVersionCompatibility() {
  local min_ver=${1}
  
  IFS='.' read -ra MIN_VER_PARTS <<< "${min_ver}"
  IFS='.' read -ra VSCODE_VER_PARTS <<< "${VSCODE_VERSION}"
  
  while [[ ${#MIN_VER_PARTS[@]} -lt 3 ]]; do
    MIN_VER_PARTS+=("0")
  done
  while [[ ${#VSCODE_VER_PARTS[@]} -lt 3 ]]; do
    VSCODE_VER_PARTS+=("0")
  done
  
  if [[ ${VSCODE_VER_PARTS[0]} -gt ${MIN_VER_PARTS[0]} ]]; then
    echo "true"
    return 0
  elif [[ ${VSCODE_VER_PARTS[0]} -eq ${MIN_VER_PARTS[0]} ]]; then
    if [[ ${VSCODE_VER_PARTS[1]} -gt ${MIN_VER_PARTS[1]} ]]; then
      echo "true"
      return 0
    elif [[ ${VSCODE_VER_PARTS[1]} -eq ${MIN_VER_PARTS[1]} ]]; then
      if [[ ${VSCODE_VER_PARTS[2]} -ge ${MIN_VER_PARTS[2]} ]]; then
        echo "true"
        return 0
      fi
    fi
  fi
  echo "false"
}

function getCompatibleRelease() {
  local ext_id=${1}
  local results=0
  local index=0
  local offset=0
  local num_releases=0
  local total_available=0

  while [[ ${num_releases} == 0 ]]
  do
    local ext_data=$(curl -X GET "https://open-vsx.org/api/v2/-/query?extensionId=${ext_id}&includeAllVersions=true&targetPlatform=${ARCH}&size=${QUERY_RESULT_SIZE}&offset=${offset}" -H 'accept: application/json')
    total_available=$(echo "${ext_data}" | jq -r '.totalSize')
    results=$(echo "${ext_data}" | jq -r '.totalSize')
    if [[ ${results} -eq 0 ]]
    then
      ext_data=$(curl -X GET "https://open-vsx.org/api/v2/-/query?extensionId=${ext_id}&includeAllVersions=true&targetPlatform=universal&size=${QUERY_RESULT_SIZE}&offset=${offset}" -H 'accept: application/json')
      total_available=$(echo "${ext_data}" | jq -r '.totalSize')
      results=$(echo "${ext_data}" | jq -r '.totalSize')
      if [[ ${results} -eq 0 ]]
      then
        echo "not-found"
        return 1
      fi
    fi

    # Check if we've exhausted all results without finding stable releases
    if [[ ${offset} -ge ${total_available} ]]
    then
      echo "no-stable-release-found"
      return 1
    fi

    ext_data=$(echo "${ext_data}" | jq -c '.extensions[] | select(.preRelease==false)')
    num_releases=$(echo "${ext_data}" | jq -c -s '. | length')
    offset=$(( ${offset} + ${QUERY_RESULT_SIZE} ))
  done
  while [[ ${index} -lt ${num_releases} ]]
  do
    vscode_min_ver=$(echo "${ext_data}" | jq -c -s ".[${index}]" | jq -r '.engines.vscode' | sed 's/\^//g')
    if [[ ${vscode_min_ver} == "*" ]]
    then
      ext_compat=$(echo "${ext_data}" | jq -c -s ".[${index}]")
      break
    fi
    # Handle common version specifiers by taking just the version number
    vscode_min_ver=$(echo ${vscode_min_ver} | sed -E 's/[<>=~^].*//')
    # If after stripping we have nothing, it was just a specifier like "^"
    if [[ -z ${vscode_min_ver} ]]; then
      vscode_min_ver="0.0.0"
    fi
    compatible=$(checkVersionCompatibility ${vscode_min_ver})
    if [[ ${compatible} == "true" ]]
    then
      ext_compat=$(echo "${ext_data}" | jq -c -s ".[${index}]")
      break
    fi
    index=$(( ${index} + 1 ))
  done
  echo "${ext_compat}"
}

# Return the pinned version for ext_id from EXTENSION_FILE, or empty if unpinned.
function getPinnedVersion() {
  local ext_id=${1}
  jq -r --arg id "${ext_id}" '
    .extensions[]
    | select(.id == $id and has("version"))
    | .version
  ' "${EXTENSION_FILE}" | head -n1
}

# Resolve a release JSON object for ext_id. Uses ext_version when set; otherwise
# the newest vscode-compatible stable release from public Open VSX.
function resolveExtensionRelease() {
  local ext_id=${1}
  local ext_version=${2:-}
  local ext_data
  local count

  if [[ -n ${ext_version} ]]
  then
    echo "Resolving ${ext_id}@${ext_version} (pinned)" >&2
    ext_data=$(curl -sL -X GET "https://open-vsx.org/api/v2/-/query?extensionId=${ext_id}&targetPlatform=${ARCH}&extensionVersion=${ext_version}&offset=0" -H 'accept: application/json')
    count=$(echo "${ext_data}" | jq -r '.totalSize // 0')
    if [[ ${count} -eq 0 ]]
    then
      ext_data=$(curl -sL -X GET "https://open-vsx.org/api/v2/-/query?extensionId=${ext_id}&targetPlatform=universal&extensionVersion=${ext_version}&offset=0" -H 'accept: application/json')
      count=$(echo "${ext_data}" | jq -r '.totalSize // 0')
      if [[ ${count} -eq 0 ]]
      then
        echo "ERROR: Extension ${ext_id}@${ext_version} not found" >&2
        echo "not-found"
        return 1
      fi
    fi
    echo "${ext_data}" | jq -c ".extensions[0]"
    return 0
  fi

  echo "Resolving ${ext_id} (latest compatible)" >&2
  getCompatibleRelease ${ext_id}
}

function fetchDependencies() {
  local ext_release="${1}"
  local index=0
  local pinned_version
  local dep_release
  local dep_url

  num_deps=$(echo "${ext_release}" | jq '.dependencies | length')
  while [[ ${index} -lt ${num_deps} ]]
  do
    dep_namespace=$(echo "${ext_release}" | jq -r ".dependencies[${index}].namespace")
    dep_extension=$(echo "${ext_release}" | jq -r ".dependencies[${index}].extension")
    dep_id="${dep_namespace}.${dep_extension}"
    # Prefer an explicit pin from extension-list.json so deps cannot publish a
    # newer "latest compatible" build (e.g. mta-core 8.3.3 via mta-java).
    pinned_version=$(getPinnedVersion ${dep_id})
    dep_release=$(resolveExtensionRelease ${dep_id} "${pinned_version}")
    if [[ ${dep_release} == "not-found" || ${dep_release} == "no-stable-release-found" || -z ${dep_release} ]]
    then
      echo "ERROR: Skipping dependency ${dep_id}; could not resolve a release" >&2
      index=$(( ${index} + 1 ))
      continue
    fi
    dep_url=$(echo "${dep_release}" | jq -r '.files.download')
    downloadExtension ${dep_url} ${dep_id//./-}.vsix $(echo ${dep_id} | cut -d"." -f1)
    index=$(( ${index} + 1 ))
  done
}

function download() {
  WORK_DIR=$(mktemp -d)
  VSCODE_VERSION=$(jq -r ".vscode" ${EXTENSION_FILE})
  ARCH=$(jq -r '.architecture' ${EXTENSION_FILE})
  local index=0
  local num_ext=$(jq -r '.extensions | length' ${EXTENSION_FILE})
  local ext_version
  local ext_release
  local ext_url

  while [[ ${index} -lt ${num_ext} ]]
  do
    ext_id=$(jq -r ".extensions[${index}].id" ${EXTENSION_FILE})
    has_url=$(jq ".extensions[${index}] | has(\"url\")" ${EXTENSION_FILE})
    if [[ ${has_url} == "true" ]]
    then
      ext_url=$(jq -r ".extensions[${index}].url" ${EXTENSION_FILE})
      downloadExtension ${ext_url} ${ext_id//./-}.vsix $(echo ${ext_id} | cut -d"." -f1)
      index=$(( ${index} + 1 ))
      continue
    fi
    ext_version=$(getPinnedVersion ${ext_id})
    ext_release=$(resolveExtensionRelease ${ext_id} "${ext_version}")
    if [[ ${ext_release} == "not-found" || ${ext_release} == "no-stable-release-found" || -z ${ext_release} ]]
    then
      echo "ERROR: Skipping ${ext_id}; could not resolve a release" >&2
      index=$(( ${index} + 1 ))
      continue
    fi
    fetchDependencies "${ext_release}"
    ext_url=$(echo "${ext_release}" | jq -r '.files.download')
    downloadExtension ${ext_url} ${ext_id//./-}.vsix $(echo ${ext_id} | cut -d"." -f1)
    index=$(( ${index} + 1 ))
  done
  rm -rf ${WORK_DIR}
}

function initPG() {
  psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" <<'EOSQL'
INSERT INTO user_data (id, login_name, role)
  VALUES (1001, 'admin', 'admin')
  ON CONFLICT (id) DO NOTHING;

INSERT INTO personal_access_token (id, user_data, value, active, created_timestamp, accessed_timestamp, description)
  VALUES (1001, 1001, 'admin_upload_token', true, NOW(), NOW(), 'Extension upload token')
  ON CONFLICT (id) DO UPDATE SET active = true;
EOSQL
}

# Make sure the OpenVSX server is online before proceeding
# TODO - This will hang forever if the OpeVSX server does not start.

checkLocalVSX

for i in "$@"
do
  case $i in
    -f=*|--file=*)
      EXTENSION_FILE="${i#*=}"
    ;;
    -d|--download)
      download
    ;;
    -i|--init)
      initPG
    ;;
  esac
done
