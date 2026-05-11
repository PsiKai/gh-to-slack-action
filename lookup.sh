#!/usr/bin/env bash
# Resolve a GitHub username to a Slack user ID.
#
# Strategy (first match wins):
#   1. Inline override map.
#   2. Email mined from this user's recent commits in $GITHUB_REPOSITORY.
#   3. GitHub user's public email -> Slack users.lookupByEmail.
#   4. Derived `{first}.{last}@<email-domain>` from GitHub `name` -> users.lookupByEmail.
#   5. Name search across Slack users.list with disambiguation by email domain.
#
# Fail-soft: any unrecoverable error returns empty slack_id with method=none.
# Never exits non-zero; the caller decides what to do with a miss.
#
# Required runtime tools (all preinstalled on ubuntu-latest / macos-latest):
#   curl, jq, iconv
#
# Required env:
#   INPUT_GITHUB_USERNAME, INPUT_SLACK_TOKEN
# Optional env:
#   INPUT_GITHUB_TOKEN, INPUT_EMAIL_DOMAIN, INPUT_OVERRIDES,
#   INPUT_FALLBACK_MENTION_FORMAT, GITHUB_OUTPUT

set -uo pipefail

LOGIN="${INPUT_GITHUB_USERNAME:-}"
SLACK_TOKEN="${INPUT_SLACK_TOKEN:-}"
GH_TOKEN="${INPUT_GITHUB_TOKEN:-}"
EMAIL_DOMAIN="${INPUT_EMAIL_DOMAIN:-}"
# NOTE: defaults are assigned on separate lines because the templates contain
# `}` characters, which would close the `${VAR:-default}` expansion early.
OVERRIDES="${INPUT_OVERRIDES:-}"
[[ -z "$OVERRIDES" ]] && OVERRIDES='{}'
FALLBACK_FMT="${INPUT_FALLBACK_MENTION_FORMAT:-}"
[[ -z "$FALLBACK_FMT" ]] && FALLBACK_FMT='`@{login}` _(Slack ID not found)_'

log()  { echo "$*" >&2; }
warn() { echo "WARN: $*" >&2; }

set_output() {
  local key="$1" value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    if [[ "$value" == *$'\n'* ]]; then
      local delim="EOF_GH2SLACK"
      {
        printf '%s<<%s\n' "$key" "$delim"
        printf '%s\n' "$value"
        printf '%s\n' "$delim"
      } >> "$GITHUB_OUTPUT"
    else
      printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    fi
  else
    printf '::set::%s=%s\n' "$key" "$value"
  fi
}

# Always emit outputs, even on early failure.
emit() {
  local slack_id="$1" method="$2"
  local found mention
  if [[ -n "$slack_id" ]]; then
    found="true"
    mention="<@${slack_id}>"
  else
    found="false"
    # GitHub usernames are alphanumeric + hyphens, so this sed is injection-safe.
    mention="$(printf '%s' "$FALLBACK_FMT" | sed "s/{login}/$LOGIN/g")"
  fi
  set_output "slack_id"     "$slack_id"
  set_output "found"        "$found"
  set_output "match_method" "$method"
  set_output "mention"      "$mention"
  log "Resolved \`$LOGIN\` -> ${slack_id:-(none)} via $method"
}

if [[ -z "$LOGIN" ]];       then warn "github-username is empty"; emit "" "none"; exit 0; fi
if [[ -z "$SLACK_TOKEN" ]]; then warn "slack-token is empty";     emit "" "none"; exit 0; fi

# Sanity-check tools.
for cmd in curl jq iconv; do
  command -v "$cmd" >/dev/null 2>&1 || { warn "$cmd not found on PATH"; emit "" "none"; exit 0; }
done

# --- 1. Overrides ------------------------------------------------------------
override_hit="$(jq -r --arg k "$LOGIN" 'if type=="object" and has($k) then .[$k] else empty end' \
                <<<"$OVERRIDES" 2>/dev/null || true)"
if [[ -n "$override_hit" && "$override_hit" != "null" ]]; then
  emit "$override_hit" "override"; exit 0
fi

# --- Fetch GitHub user profile ----------------------------------------------
GH_HEADERS=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
[[ -n "$GH_TOKEN" ]] && GH_HEADERS+=(-H "Authorization: Bearer $GH_TOKEN")

gh_response="$(curl -sS -w '\n%{http_code}' "${GH_HEADERS[@]}" \
               "https://api.github.com/users/$LOGIN" || true)"
gh_code="${gh_response##*$'\n'}"
gh_body="${gh_response%$'\n'*}"

if [[ "$gh_code" != "200" ]]; then
  warn "GitHub /users/$LOGIN returned HTTP $gh_code"
  emit "" "none"; exit 0
fi

public_email="$(jq -r '.email // empty' <<<"$gh_body")"
real_name="$(jq -r '.name // empty' <<<"$gh_body")"

# Slack call helper: prints body, sets rc=0 if ok==true; rc=1 otherwise.
slack_call() {
  local method="$1"; shift
  curl -sS -G "https://slack.com/api/$method" \
       -H "Authorization: Bearer $SLACK_TOKEN" "$@"
}

# --- 2. Commit-author email from the calling repo ---------------------------
# Mining recent commits gives us the email this user actually authors with in
# THIS repo, which is what their org-specific GitHub notification settings
# resolve to. Reliable and avoids needing an `email-domain` input.
GH_REPO="${GITHUB_REPOSITORY:-}"
if [[ -n "$GH_REPO" ]]; then
  commits_body="$(curl -sS "${GH_HEADERS[@]}" \
                  "https://api.github.com/repos/$GH_REPO/commits?author=$LOGIN&per_page=10" || true)"
  # Pick the most recent commit email that isn't GitHub's noreply alias.
  commit_email="$(jq -r 'if type=="array" then .[] | .commit.author.email // empty else empty end' \
                  <<<"$commits_body" 2>/dev/null \
                  | grep -vE 'users\.noreply\.github\.com$' \
                  | head -n 1 || true)"
  if [[ -n "$commit_email" ]]; then
    body="$(slack_call users.lookupByEmail --data-urlencode "email=$commit_email")"
    if [[ "$(jq -r '.ok' <<<"$body")" == "true" ]]; then
      uid="$(jq -r '.user.id // empty' <<<"$body")"
      [[ -n "$uid" ]] && { emit "$uid" "email-commit"; exit 0; }
    fi
  fi
fi

# --- 3. Public email --------------------------------------------------------
if [[ -n "$public_email" ]]; then
  body="$(slack_call users.lookupByEmail --data-urlencode "email=$public_email")"
  if [[ "$(jq -r '.ok' <<<"$body")" == "true" ]]; then
    uid="$(jq -r '.user.id // empty' <<<"$body")"
    [[ -n "$uid" ]] && { emit "$uid" "email-public"; exit 0; }
  fi
fi

# --- Derive {first}.{last} slug ---------------------------------------------
# Handles diacritics via iconv TRANSLIT; only succeeds if name has >= 2 tokens.
slug=""
if [[ -n "$real_name" ]]; then
  # iconv //TRANSLIT on macOS inserts an apostrophe for accents (`ú` -> `'u`).
  # Strip apostrophes and backticks BEFORE tokenizing so we don't split a name.
  slug="$(printf '%s' "$real_name" \
          | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null \
          | tr '[:upper:]' '[:lower:]' \
          | tr -d "'\`\"" \
          | tr -c 'a-z \n' ' ' \
          | awk '{ if (NF >= 2) printf "%s.%s", $1, $NF }')"
fi

# --- 4. Derived email -------------------------------------------------------
if [[ -n "$slug" && -n "$EMAIL_DOMAIN" ]]; then
  derived="${slug}@${EMAIL_DOMAIN}"
  body="$(slack_call users.lookupByEmail --data-urlencode "email=$derived")"
  if [[ "$(jq -r '.ok' <<<"$body")" == "true" ]]; then
    uid="$(jq -r '.user.id // empty' <<<"$body")"
    [[ -n "$uid" ]] && { emit "$uid" "email-derived"; exit 0; }
  fi
fi

# --- 5. Name search ---------------------------------------------------------
if [[ -n "$real_name" ]]; then
  cursor=""
  candidates_json="[]"
  target_lower="$(printf '%s' "$real_name" | tr '[:upper:]' '[:lower:]')"
  for _ in $(seq 1 20); do  # safety cap: ~4000 users
    body="$(slack_call users.list --data-urlencode "limit=200" --data-urlencode "cursor=$cursor")"
    [[ "$(jq -r '.ok' <<<"$body")" == "true" ]] || break
    matches="$(jq --arg t "$target_lower" '
      .members
      | map(select(
          (.deleted // false | not)
          and (.is_bot   // false | not)
          and (.id != "USLACKBOT")
          and ((.profile.real_name    // "" | ascii_downcase) == $t
               or (.profile.display_name // "" | ascii_downcase) == $t)
        ))
    ' <<<"$body")"
    candidates_json="$(jq -s 'add' <<<"$candidates_json"$'\n'"$matches")"
    cursor="$(jq -r '.response_metadata.next_cursor // ""' <<<"$body")"
    [[ -z "$cursor" ]] && break
  done

  count="$(jq 'length' <<<"$candidates_json")"
  if [[ "$count" -ge 1 ]]; then
    # Prefer the one whose email matches EMAIL_DOMAIN, if provided.
    pick="$(jq -r --arg d "$EMAIL_DOMAIN" '
      ( map(select(($d != "") and ((.profile.email // "") | endswith("@" + $d))))
        + . ) | .[0].id // empty
    ' <<<"$candidates_json")"
    [[ -n "$pick" ]] && { emit "$pick" "name-search"; exit 0; }
  fi
fi

emit "" "none"
exit 0
