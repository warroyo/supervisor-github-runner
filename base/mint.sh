#!/usr/bin/env bash
# The minter: the only container with the GitHub App's key. It mints a
# just-in-time runner config, hands it to the runner container through the
# handoff volume, and waits. It mints the next one only after the runner that
# used the last one has left GitHub, so a job can never pick up a config for
# a runner of its own.
#
# GITHUB_URL decides the scope:
#   https://github.com/<org>             organization
#   https://github.com/<owner>/<repo>    repository
set -euo pipefail

: "${GITHUB_URL:?set GITHUB_URL to an organization or repository URL}"
: "${GITHUB_APP_ID:?set GITHUB_APP_ID}"
: "${GITHUB_APP_PRIVATE_KEY:?set GITHUB_APP_PRIVATE_KEY}"

handoff=/handoff/jitconfig
# Which runner was minted last. Its own volume, so a restart of this
# container does not mint a second runner beside one that is still there.
state=/state/runner-id
poll=10
# A runner that took its config and has been offline this long died without
# leaving GitHub. It's removed, so the next one can be minted.
stale_after=180

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


# The installation token lasts an hour. It's minted again after 50 minutes.
# The key goes to openssl through a pipe, so it never touches the disk.
token=""
token_at=0
refresh_token() {
  local now header claims signature app_jwt installation_id
  now=$(date +%s)
  (( now - token_at < 3000 )) && return 0
  # iat is in the past to allow for clock skew, and exp - iat must stay
  # under ten minutes.
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  claims=$(jq -ncj --arg iss "${GITHUB_APP_ID}" --argjson now "${now}" \
    '{iat: ($now - 30), exp: ($now + 480), iss: $iss}' | b64url)
  signature=$(printf '%s' "${header}.${claims}" |
    openssl dgst -sha256 -sign <(printf '%s\n' "${GITHUB_APP_PRIVATE_KEY}") -binary | b64url) || return 1
  app_jwt="${header}.${claims}.${signature}"
  installation_id=$(github GET "/${scope}/installation" "${app_jwt}" | jq -er .id) || return 1
  token=$(github POST "/app/installations/${installation_id}/access_tokens" "${app_jwt}" | jq -er .token) || return 1
  token_at=${now}
}

# Prints the runner's status, online or offline, or gone once GitHub no
# longer has it.
runner_status() {
  local status out
  out=$(mktemp)
  status=$(curl -sS -o "${out}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${api}/${scope}/actions/runners/$1") || { rm -f "${out}"; return 1; }
  case "${status}" in
    200) jq -r .status "${out}" ;;
    404) echo gone ;;
    *) echo "GitHub API GET /${scope}/actions/runners/$1 failed: HTTP ${status}" >&2
       cat "${out}" >&2; rm -f "${out}"; return 1 ;;
  esac
  rm -f "${out}"
}

mint() {
  local name request response
  # Every runner gets a new name: a runner that died before its job stays
  # registered for a while, and a second runner of the same name is refused.
  name="${RUNNER_NAME:-$(hostname)}-$(openssl rand -hex 3)"
  request=$(jq -nc \
    --arg name "${name}" \
    --arg labels "${RUNNER_LABELS:-self-hosted,supervisor}" \
    --argjson group "${RUNNER_GROUP_ID:-1}" \
    '{name: $name, runner_group_id: $group, work_folder: "_work",
      labels: ($labels | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "")))}')
  response=$(github POST "/${scope}/actions/runners/generate-jitconfig" "${token}" "${request}") || return 1
  # Written beside the handoff file and renamed, so the runner never reads
  # half a config.
  jq -er .encoded_jit_config <<<"${response}" > "${handoff}.tmp" || return 1
  jq -er .runner.id <<<"${response}" > "${state}" || return 1
  mv "${handoff}.tmp" "${handoff}"
  echo "Minted runner ${name}"
}

offline_since=0
while true; do
  if ! refresh_token; then
    echo "Cannot get an installation token. Trying again in 30 seconds." >&2
    sleep 30
    continue
  fi

  if [[ ! -s "${state}" ]]; then
    if ! mint; then
      echo "Cannot mint a runner. Trying again in 30 seconds." >&2
      sleep 30
    fi
    continue
  fi

  id=$(<"${state}")
  if ! status=$(runner_status "${id}"); then
    sleep "${poll}"
    continue
  fi
  case "${status}" in
    gone)
      # The job is over. The runner container kills what the job left
      # running as soon as its runner exits: give it a few seconds first.
      rm -f "${state}"
      offline_since=0
      sleep 5
      continue
      ;;
    offline)
      # Offline is normal before the runner has taken its config, and for
      # the few seconds it takes to connect.
      if [[ ! -e "${handoff}" ]]; then
        now=$(date +%s)
        (( offline_since == 0 )) && offline_since=${now}
        if (( now - offline_since > stale_after )); then
          echo "Runner ${id} has been offline for ${stale_after} seconds. Removing it." >&2
          github DELETE "/${scope}/actions/runners/${id}" "${token}" > /dev/null || true
          rm -f "${state}"
          offline_since=0
          continue
        fi
      fi
      ;;
    *)
      offline_since=0
      ;;
  esac
  sleep "${poll}"
done
