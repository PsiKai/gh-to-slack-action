# gh-to-slack-action

Resolve a GitHub username to a Slack user ID inside any workflow. Drop the resolved ID — or a safe fallback mention — straight into a Slack message body.

## Quick start

By default the action resolves whoever triggered the workflow (`github.actor`):

```yaml
- uses: PsiKai/gh-to-slack-action@v1
  id: slack
  with:
    slack-token: ${{ secrets.SLACK_BOT_TOKEN }}

- name: Notify
  if: steps.slack.outputs.found == 'true'
  run: |
    curl -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer ${{ secrets.SLACK_BOT_TOKEN }}" \
      -d "channel=${{ steps.slack.outputs.slack-id }}" \
      -d "text=Your PR deploy is ready"
```

That's it. The action mines the user's recent commits in the calling repo to discover the email they author with — typically the corporate email that matches their Slack account — so no `email-domain` configuration is needed for active contributors.

To resolve someone other than the actor — for example the PR author when running on `workflow_run` — pass `github-username` explicitly:

```yaml
- uses: PsiKai/gh-to-slack-action@v1
  with:
    github-username: ${{ github.event.pull_request.user.login }}
    slack-token: ${{ secrets.SLACK_BOT_TOKEN }}
```

When no match is found, `slack-id` is empty and `mention` returns safe fallback text so your workflow keeps moving.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `github-username` | no | `${{ github.actor }}` | The GitHub login to resolve. |
| `slack-token` | yes | — | Slack bot token with `users:read` and `users:read.email`. |
| `email-domain` | no | `''` | Fallback corporate email domain used to derive `{first}.{last}@<domain>` when the user has no commit history in the calling repo and no public email. Safe to omit for most repos. |
| `overrides` | no | `'{}'` | JSON map of `github-login` → `slack-user-id`, applied before any API lookup. Useful for renamed accounts. |
| `github-token` | no | `${{ github.token }}` | Token for reading the GitHub user profile. The default workflow token is sufficient. |
| `fallback-mention-format` | no | see [action.yml](action.yml) | Template returned as `mention` when no match is found. `{login}` is substituted. |

## Outputs

| Output | Description | Example |
|---|---|---|
| `slack-id` | Resolved Slack user ID, or empty string. | `U05UCB72807` |
| `found` | `true` when a Slack user was matched. | `true` |
| `match-method` | Which strategy resolved the user. | `override`, `email-commit`, `email-public`, `email-derived`, `name-search`, `none` |
| `mention` | Drop-in Slack mention syntax if found; otherwise the rendered fallback text. | `<@U05UCB72807>` |

## Resolution order

The action tries strategies in order and returns the first match:

1. **Overrides** — exact match in the `overrides` JSON map.
2. **Commit-author email** — the email the user authored their most recent commits with in the calling repo. This is what GitHub's per-organization notification settings respect, so for monorepos it tends to be the corporate email that also matches Slack.
3. **Public email** — GitHub user's public email, looked up via Slack `users.lookupByEmail`.
4. **Derived email** — `{first}.{last}@<email-domain>` constructed from the GitHub user's `name` field. Only attempted when `email-domain` is provided.
5. **Name search** — match against `real_name` / `display_name` from `users.list`, disambiguated by email domain when multiple candidates share a name.

## Slack app setup

Create a Slack app, install it to your workspace, and grant the bot token these scopes:

- `users:read` — list workspace members
- `users:read.email` — look up users by email

Add any further scopes you need to *use* the resolved ID (e.g. `chat:write` to send a message).

## Examples

- [`examples/notify-pr-author.yml`](examples/notify-pr-author.yml) — DM the PR author when a deploy completes.
- [`examples/notify-failing-actor.yml`](examples/notify-failing-actor.yml) — Mention `github.actor` in a workflow-failure alert.

## License

MIT
