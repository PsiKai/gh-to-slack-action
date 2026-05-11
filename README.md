# GitHub → Slack Lookup Action

Resolve a GitHub username to a Slack user ID on-the-fly inside any workflow. No mapping file to maintain.

```yaml
- uses: PsiKai/gh-to-slack-action@v1
  id: slack
  with:
    github-username: ${{ github.event.pull_request.user.login }}
    slack-token: ${{ secrets.SLACK_BOT_TOKEN }}
    email-domain: yourcompany.io

- name: Notify
  if: steps.slack.outputs.found == 'true'
  run: |
    curl -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer ${{ secrets.SLACK_BOT_TOKEN }}" \
      -d "channel=${{ steps.slack.outputs.slack-id }}" \
      -d "text=Your PR deploy is ready"
```

## How it works

Four strategies, first match wins:

1. **Overrides** — inline JSON map for edge cases (renamed accounts, etc.)
2. **GitHub public email** → Slack `users.lookupByEmail`
3. **Derived corporate email** — `{first}.{last}@<email-domain>` from GitHub `name`
4. **Name search** — scan `users.list` for an exact real-name match, disambiguated by email domain

If nothing matches, `slack-id` is empty and `mention` falls back to safe text — the caller decides what to do.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `github-username` | yes | — | The login to resolve. |
| `slack-token` | yes | — | Bot token (xoxb-) with `users:read` and `users:read.email`. |
| `github-token` | no | `${{ github.token }}` | Default token is sufficient. |
| `email-domain` | no | `''` | Skip step 3 if empty. |
| `overrides` | no | `'{}'` | JSON object: `{"login":"U..."}`. |
| `fallback-mention-format` | no | see [action.yml](action.yml) | `{login}` is substituted. |

## Outputs

| Output | Example |
|---|---|
| `slack-id` | `U05UCB72807` (empty if no match) |
| `found` | `true` / `false` |
| `match-method` | `override` / `email-public` / `email-derived` / `name-search` / `none` |
| `mention` | `<@U05UCB72807>` if found, else the rendered fallback text |

## Runner requirements

Pure bash — no setup step, no language runtime. Uses `curl`, `jq`, and `iconv`,
all preinstalled on `ubuntu-latest` and `macos-latest` runners.

## Required Slack scopes

Create a Slack app, add a Bot Token, install to your workspace, and grant:

- `users:read` — list workspace members
- `users:read.email` — match by email

Plus whatever scopes you need to *use* the resulting ID (e.g. `chat:write` to DM).

## Why this beats a mapping file

A static `slackIds.json`:

- Goes stale silently when people leave or change handles
- Requires PRs to update
- Is one of the [hard things in computer science](https://martinfowler.com/bliki/TwoHardThings.html) (cache invalidation)

This action looks up live data every run. It's also a no-op when there's no match — your workflow just falls back gracefully.

## Examples

- [`examples/notify-pr-author.yml`](examples/notify-pr-author.yml) — DM the PR author when a deploy completes
- [`examples/notify-failing-actor.yml`](examples/notify-failing-actor.yml) — Mention `github.actor` in a failure message

## License

MIT
