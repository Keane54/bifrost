# Bifrost Slack app

This folder holds the Slack app that the Bifrost chat panels use (milestone M6). The panels show Slack channels and private channels, as the Local and Corp chat windows do in EVE. They never show DMs or group DMs. You read and send messages as yourself.

The full research, with a source for each fact, is in `.superpowers/research-slack.md` (not in git).

## Why Bifrost needs its own app

- Every supported way to read and send as a user needs a Slack app.
- Slack stopped new legacy tokens on 5 May 2020, and new classic apps on 4 June 2024.
- The official Slack MCP server also needs a registered app, and it gives no live messages.
- Browser session tokens (`xoxc` and `xoxd`) are not supported. They go around the app approval rules. Bifrost does not use them.
- Bifrost must not use the app of another company, for example the app of the Claude Slack plugin. The Slack Developer Policy does not allow an app that presents itself as the product of another company.

Use a free, internal app. Slack charges nothing for an app. An internal app that you do not distribute keeps the full rate limits.

## Files

| File | Content |
|---|---|
| `bifrost-slack-app-manifest.yaml` | The app manifest: name, user scopes, user events, Socket Mode. |
| `README.md` | This file. |

## Set up the app

Before you start: you must be a member of the company workspace. If the workspace has app approval on, an admin must approve the app.

1. Open <https://api.slack.com/apps>.
2. Click **Create New App**, then **From a manifest**.
3. Select the company workspace.
4. Paste the content of `bifrost-slack-app-manifest.yaml`. Click **Next**, then **Create**.
5. Go to **Basic Information** > **App-Level Tokens**. Click **Generate Token and Scopes**.
6. Name the token `bifrost-socket`. Add the scope `connections:write`. Click **Generate**. Copy the `xapp-` token.
7. Go to **Install App**. Click **Install to Workspace**. If an admin must approve the app, click **Request to Install** and wait for the approval.
8. After the install, go to **OAuth & Permissions**. Copy the **User OAuth Token** (`xoxp-`).

CAUTION: Do not paste a token into a chat, a ticket or a file in git. A user token gives full read and send access as you.

CAUTION: Do not turn on PKCE in the app settings. Only Slack support can turn it off. Bifrost does not support the PKCE sign-in yet.

CAUTION: Do not turn on public distribution. An internal app keeps the full rate limits. A distributed app outside the Slack Marketplace gets a limit of 1 history request each minute.

## Keep the tokens (first test only)

Until M6 adds a Settings field that stores the tokens in the macOS Keychain, keep them in a private file.

1. Run `touch ~/.bifrost/slack.env && chmod 600 ~/.bifrost/slack.env`.
2. Run `open -e ~/.bifrost/slack.env`.
3. Type the two lines below with your tokens, then save the file:

```text
SLACK_USER_TOKEN=xoxp-...
SLACK_APP_TOKEN=xapp-...
```

After M6 stores the tokens in the Keychain, delete this file.

## Permissions

User token scopes (no bot scopes):

| Scope | Use |
|---|---|
| `channels:read`, `groups:read` | List your channels and private channels. |
| `channels:history`, `groups:history` | Read their messages. |
| `chat:write` | Send a message as you. |
| `users:read` | Show the names of the senders. |

App-level token: `connections:write` (the Socket Mode connection).

User events: `message.channels`, `message.groups`.

Bifrost never reads or sends DMs or group DMs (user decision, 2026-11-09). The app has no `im` or `mpim` scope and no DM events. Bifrost also refuses each conversation ID that starts with `D`, and sends only to the channels that `conversations.list` gives for the types `public_channel` and `private_channel`.

## Limits

| Item | Limit |
|---|---|
| Read history (`conversations.history`, `conversations.replies`, `conversations.info`) | 50+ requests each minute (Tier 3) |
| List channels and users (`conversations.list`, `users.list`) | 20+ requests each minute (Tier 2) |
| Look up one user (`users.info`) | 100+ requests each minute (Tier 4) |
| Send (`chat.postMessage`) | 1 message each second for each channel; several hundred each minute for the workspace |
| Scope of the rate limits | Each limit applies for each method, for each workspace, for each app. All users of one app in one workspace share it. |
| The 2025 cut (1 request each minute, 15 messages) | Applies only to apps that are distributed outside the Slack Marketplace. An internal app is not affected. |
| Message text | 4,000 characters recommended. Slack cuts the text above 40,000 characters. |
| Blocks | 50 blocks in one message |
| History page | 100 messages by default, 999 maximum, 200 or fewer recommended. Pages use a cursor. |
| Live events | 30,000 events each hour, for each workspace, for each app. After 3 failed retries, Slack drops an event. |
| Socket Mode | Up to 10 open connections for each app. Slack renews each connection every few hours. Slack gives each event to one open connection only. |
| User token life | No expiry while token rotation is off. With rotation, 12 hours. |
| Free workspace plan | 90 days of visible history, and 10 apps at most. Paid plans do not have these limits. |
| App removal | Slack removes an app with user scopes if the person who installed it leaves the workspace or becomes a guest. |

## Open points for the first test

1. Socket Mode with user events: all related facts say that it works. But no Slack page says it in one sentence. The first test checks it. If it fails, Bifrost polls `conversations.history` for the open panels.
2. App label: the first test checks if Slack shows an app label on a message that Bifrost sends.

## Give Bifrost to colleagues

The full research, with a source for each fact, is in `.superpowers/research-slack-distribution.md` (not in git).

Two Slack facts set the method:

- The rate limits apply for each app. All users of one app share them.
- Socket Mode gives each event to only one open connection of the app. So two people must never share the Socket Mode token of one app. The events of one person could go to the Bifrost of the other person.

How other products do it:

| Product type | Method |
|---|---|
| Linear, Notion, GitHub, Zendesk | One app. An admin installs it one time. Each user connects. The vendor server gets the Slack events over HTTP and routes them. |
| Raycast | One app with a sign-in for each user. It reads messages only when the user opens a command. No live messages. |
| Ferdium, Franz, Rambox, Station | The Slack web client in a webview. No app and no API. |
| Beeper, Texts.com | The browser login token. Slack does not support this method. Bifrost does not use it. |
| Older clients | The RTM API. New apps cannot use it. Classic apps stop on 16 November 2026. |

The plan for Bifrost:

| Stage | Method | Users |
|---|---|---|
| 1 (M6) | One company app. The user signs in. Live messages come over Socket Mode. | The user only. Do not give the app-level token to a second person. |
| 2 (later) | The same company app. Each user clicks "Connect Slack" (OAuth with PKCE). A small company relay server gets the Events API over HTTP. It checks `apps.event.authorizations.list` and sends each event only to the Bifrost of the users who can see it. Each Mac reads history and sends messages with its own user token. | All staff. The admin approves the app one time. |

Notes for stage 2:

- Cost: a small server, under about USD 20 each month, plus the build work.
- Risk: a fault in the event filter can show a private message to the wrong person. The filter needs strong tests.
- At 200 users, the history load at the start of the day reaches the shared Tier 3 limit. The relay or the clients need a load limit.
- Test these first:
  - PKCE with user events.
  - The authorizations for private channels.
  - The stop of events when a user leaves a private channel.

Methods that do not work:

- Polling with no server: all staff share 50 history requests each minute. At 50 users, a panel updates every 8 minutes.
- Socket Mode in each Bifrost with one shared app-level token: a privacy fault.
- Browser session tokens: not supported by Slack.

Outside the company: the Slack Marketplace rejects third-party Slack clients. An unlisted app gets 1 history request each minute. So Bifrost stays a company tool for Slack. Get a legal review before any other plan.
