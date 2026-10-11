#!/usr/bin/env bash
# Mints a just-in-time runner config with the GitHub App's key, then starts
# the runner with it. The runner takes one job, deregisters, and exits. The
# container restarts and this runs again.
#
# GITHUB_URL decides the scope:
#   https://github.com/<org>             organization
#   https://github.com/<owner>/<repo>    repository
set -euo pipefail

: "${GITHUB_URL:?set GITHUB_URL to an organization or repository URL}"
: "${GITHUB_APP_ID:?set GITHUB_APP_ID}"
: "${GITHUB_APP_PRIVATE_KEY:?set GITHUB_APP_PRIVATE_KEY}"

url="${GITHUB_URL%/}"
rest="${url#https://}"
if [[ "${rest}" == "${url}" || "${rest}" != */* ]]; then
  echo "GITHUB_URL must look like https://github.com/<org> or https://github.com/<owner>/<repo>" >&2
  exit 1
fi
host="${rest%%/*}"
path="${rest#*/}"

case "${path}" in
  */*/*) echo "GITHUB_URL has too many path segments: ${GITHUB_URL}" >&2; exit 1 ;;
  */*) scope="repos/${path}" ;;
  *) scope="orgs/${path}" ;;
esac

# GitHub Enterprise Server serves its API under /api/v3 of the same host.
if [[ "${host}" == "github.com" ]]; then
  api="https://api.github.com"
else
  api="https://${host}/api/v3"
fi

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Prints the response body. On an HTTP error, prints GitHub's message too.
github() {
  local method="$1" path="$2" auth="$3" data="${4:-}" out status
  out=$(mktemp)
  status=$(curl -sS -o "${out}" -w '%{http_code}' -X "${method}" \
    -H "Authorization: Bearer ${auth}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    ${data:+-d "${data}"} \
    "${api}${path}")
  if [[ "${status}" != 2* ]]; then
    echo "GitHub API ${method} ${path} failed: HTTP ${status}" >&2
    cat "${out}" >&2
    rm -f "${out}"
    return 1
  fi
  cat "${out}"
  rm -f "${out}"
}

# App JWT. iat is in the past to allow for clock skew, and exp - iat must
# stay under ten minutes. The key goes to openssl through a pipe, so it
# never touches the disk.
now=$(date +%s)
header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
claims=$(jq -ncj --arg iss "${GITHUB_APP_ID}" --argjson now "${now}" \
  '{iat: ($now - 30), exp: ($now + 480), iss: $iss}' | b64url)
signature=$(printf '%s' "${header}.${claims}" |
  openssl dgst -sha256 -sign <(printf '%s\n' "${GITHUB_APP_PRIVATE_KEY}") -binary | b64url)
app_jwt="${header}.${claims}.${signature}"

installation_id=$(github GET "/${scope}/installation" "${app_jwt}" | jq -er .id)
installation_token=$(github POST "/app/installations/${installation_id}/access_tokens" "${app_jwt}" | jq -er .token)

# A container that died before its job leaves its runner registered, and a
# second runner of the same name is refused. So every start gets a new name.
name="${RUNNER_NAME:-$(hostname)}-$(openssl rand -hex 3)"
request=$(jq -nc \
  --arg name "${name}" \
  --arg labels "${RUNNER_LABELS:-self-hosted,supervisor}" \
  --argjson group "${RUNNER_GROUP_ID:-1}" \
  '{name: $name, runner_group_id: $group, work_folder: "_work",
    labels: ($labels | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "")))}')
jitconfig=$(github POST "/${scope}/actions/runners/generate-jitconfig" "${installation_token}" "${request}" |
  jq -er .encoded_jit_config)

echo "Registered runner ${name} at ${url}"

# The work directory is a volume, and a volume outlives a container restart.
rm -rf _work/* _work/.[!.]* 2>/dev/null || true

# Jobs are children of run.sh. Without this they could read the App's key.
unset GITHUB_APP_PRIVATE_KEY GITHUB_APP_ID app_jwt installation_token signature

exec ./run.sh --jitconfig "${jitconfig}"
