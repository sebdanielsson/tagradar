# Live Activity push server

iOS does not let a suspended app update its Live Activities on a schedule. The supported way is an ActivityKit push through APNs, which needs a server. `server/` is that server: a small TypeScript project on Vercel that polls Trafikverket for the trains people follow and pushes each activity's new state.

## How it works

1. **Follow.** `LiveActivityController.follow` starts the activity with `pushType: .token` when a server is configured (`ActivityPushRegistrar.isEnabled`).
2. **Register.** The activity's push token (it rotates; `pushTokenUpdates`) goes to `POST /api/activities` with the run (`TrainKey.id`), the saved trip segment, the APNs environment and whether the user wants alerts for that train. The registration is sent again when any of these change and removed with `DELETE /api/activities/:id` when the activity ends, here or on the Lock Screen.
3. **Tick.** An external scheduler calls `POST /api/tick` every minute. The tick claims the runs that are due (a Lua script leases them for 3 minutes, so a slow tick and the next one never work on the same run), loads all of them in one Trafikverket request, builds each activity's `ContentState` for its own segment and pushes it if it changed, or if its stale date is getting close. Each run is then rescheduled at the activity cadence: every minute en route, every 3 minutes in the last 45 minutes before departure, sparser before that. Rescheduling is a second script that leaves a run alone if a registration moved it in the meantime, and only drops a run when nobody follows it any more. A run that throws is retried in 2 minutes without holding up the others. A push that fails for any reason other than a dead token is retried with growing gaps (up to 15 minutes, tracked per activity) until the registration expires, so an APNs outage or a broken key doesn't cost anyone their activity. A tick is bounded by its timeouts (20 s per Trafikverket call, 10 s per push, a run's activities pushed in parallel), about 80 s in the worst case, well inside the lease.
   The app's registration (`activity:<id>`) and the tick's own state for it (`state:<id>`: alert baseline, alerts still to deliver, last pushed hash, APNs environment) live in separate keys. The tick never writes a registration: it saves its state right after each push and only while the registration exists, expiring with it, and it removes an activity only if it still has the token the tick pushed to. The app re-sends an unchanged registration every 30 minutes, so one the server lost comes back.
4. **Alerts.** For saved trains with alerts on, the tick runs the `TrainAlertEngine` rules and attaches an `alert` to the push (priority 10), one push per alert when a poll yields several, each with a newer `timestamp`. Alerts after a failed push wait in the state for the next attempt; the ones already delivered are not sent again. The text is a `loc-key` from `Localizable.xcstrings`, so it shows in the phone's language; unlike the app's own notifications it has no map or actions. While the server sends a train's alerts, `TrainMonitor` keeps updating that train's alert state but doesn't post them. When the server stops (the activity ended or was dismissed), the app's first pass is silent too and re-baselines the state, because the server may have told the user things while the app was suspended (`TrainAlerts.process(remote:)`).
5. **End.** On arrival or cancellation (or an hour after the expected arrival when that is never reported) the tick sends `"event": "end"` and deletes the activity's data. The activity leaves the Lock Screen five minutes after the trip's arrival (at once if that has passed); a cancellation stays a quarter of an hour so it is seen. The app ends activities the same way when it sees the arrival first (`LiveActivityController.dismissal`).

Routine progress is pushed at priority 5. Status changes, a new next stop, alerts and the end go at priority 10. `NSSupportsLiveActivitiesFrequentUpdates` raises the priority-10 budget.

### Keeping the app and the server in step

The server ports `TrainJourney`, `TrainStop`, `TrainSnapshot`, `TripSegment.range`, `ContentState` and `TrainAlertEngine` (`server/src/`). The fixtures in `server/test/fixtures/contract/` run through both implementations: `server/test/contract.test.ts` and `TagradarTests/PushContractTests.swift`, which decodes the server's expected output the way ActivityKit does (`JSONDecoder`, dates as seconds since 2001-01-01). Change one side and the other's test fails until the port follows. See the fixtures' README to regenerate them.

A change to `ContentState` needs care beyond that: phones on an older build decode new pushes with their own struct. Add fields as optionals and never remove or rename one.

## Budget

Everything is sized for Vercel Hobby and Upstash's free plan:

- **Function invocations:** about 43,000 ticks a month (1M included).
- **Active CPU:** 4 CPU-hours a month, about 0.33 s per tick. Waiting on the network doesn't count, and a tick with nothing due returns after one Redis command.
- **Redis commands:** 500k a month. An empty tick uses 1 (the claim script). A tick with due runs uses about 3, plus 1 per run, plus 1 per activity that was pushed or whose alert state moved. A registration uses about 10, including the rate limit. This counts each script run (`EVAL`) as one command; if Upstash counts the calls inside a script, add about 2 per run.
- **Per tick:** at most 40 runs, so a backlog spreads over several ticks instead of one long one.

`/api/tick` returns its counts (`due`, `activities`, `pushed`, `alerts`, `ended`, `failed`, and whether anything went wrong), and the Vercel logs show them, error text included, for every tick that had work. Hobby is for non-commercial use; if Tågradar ever makes money, it has to move to Pro.

## Setup

### 1. APNs key

In the Apple Developer account that owns the bundle ID (Jesper's team for `se.tagradar.app`): Certificates, Identifiers & Profiles → Keys → **+** → enable **Apple Push Notifications service (APNs)**, environment **Sandbox & Production**. Download the `.p8` (only once) and note the key ID and the team ID.

A developer on another paid team (`APP_BUNDLE_ID` in `.env.local`) needs a key from that team too; `APNS_KEYS` takes one entry per team.

The app's `aps-environment` entitlement makes Xcode's automatic signing add the Push Notifications capability to the App ID. A free Personal Team cannot have it and cannot create an APNs key: set `PERSONAL_TEAM=YES` in `.env.local` (then `Scripts/bootstrap.sh`) to sign with `Tagradar/TagradarPersonalTeam.entitlements` instead. Those builds follow trains without push and only update them while the app runs; test the push path with TestFlight builds.

### 2. Vercel project

The project is `tagradar-push` on Sebastian's Hobby account, production URL `https://tagradar-push.vercel.app`, connected to this repository with **Root Directory** `server`, framework preset **Other** and the Ignored Build Step `git diff --quiet HEAD^ HEAD -- .`, so only commits that touch `server/` deploy. Functions run in `arn1` (Stockholm), set in the project (Settings → Functions → Function Region); the project setting wins over `regions` in `server/vercel.json`, which only documents it. Pushes to `main` deploy to production; other branches get protected preview deployments, which have no environment variables.

Deploys normally come from Git. `vercel deploy --prod` from the repository root (after `vercel link --project tagradar-push`) deploys the working tree instead, uploading the repository; don't add a `.vercelignore` to trim it, because Git deployments apply it too and it strips `.git`, which the Ignored Build Step needs.

Environment variables (Production, all sensitive):

| Variable | Value |
| --- | --- |
| `TRV_API_KEY` | A Trafikverket API key |
| `APNS_KEYS` | `[{"teamId":"…","keyId":"…","privateKey":"-----BEGIN PRIVATE KEY-----\n…","bundleIds":["se.tagradar.app"]}]`. Newlines in the key can be written as `\n`. Until it is set, the server accepts no registrations and the app keeps its activities local. |
| `APP_SECRET` | A long random string (`openssl rand -hex 32`); also `PUSH_SERVER_SECRET` for the app |
| `CRON_SECRET` | Another random string, sent by the scheduler |
| `UPSTASH_REDIS_REST_URL`, `UPSTASH_REDIS_REST_TOKEN` | The Redis database below |
| `MAX_ACTIVITIES` | Optional, default 2000: stored activities at most |
| `REGISTRATIONS_PER_HOUR` | Optional, default 300: registration requests per client address and hour (a phone sends about two; carrier NAT shares addresses) |

### Redis

The Vercel Marketplace only offers Upstash's paid plans to this account, so the database is created in Upstash's own console on the **free** plan (500k commands a month and 250 MB of data, no card): `tagradar-push`, region `eu-central-1` (Frankfurt, the closest to `arn1`). Its REST URL and token go into the two `UPSTASH_REDIS_REST_*` variables. The server also reads the Marketplace's `KV_REST_API_*` names, should it ever move there.

### 3. Scheduler

Hobby cron only runs once a day, so the tick comes from [cron-job.org](https://cron-job.org) (free, one-minute schedules): job **Tågradar push tick**, `POST https://tagradar-push.vercel.app/api/tick` every minute with the header `Authorization: Bearer <CRON_SECRET>`, failure notifications on.

### 4. App

- CI: repository variable `PUSH_SERVER_HOST` (`tagradar-push.vercel.app`) and secret `PUSH_SERVER_SECRET` (the `APP_SECRET`), used by the TestFlight and App Store jobs. Both are set.
- Local builds on a paid team: add `PUSH_SERVER_HOST=tagradar-push.vercel.app` (host only, no `https://`; xcconfig treats `//` as a comment) and `PUSH_SERVER_SECRET=<APP_SECRET>` to `.env.local`, then run `Scripts/bootstrap.sh`. A Personal Team build can't receive pushes, so leave them out there.

Without them the app builds and works as before, minus background updates.

## Security

The app secret ships inside the app, so anyone can extract it and register activities. What that buys an attacker is limited: registrations are validated (token, run within two days, known bundle ID, station signatures), rate limited per client address (`REGISTRATIONS_PER_HOUR`; IPv6 per /64), capped by `MAX_ACTIVITIES` and expire after the run; fake tokens are dropped at their first push, and pushes only reach the token that was registered. Someone with many addresses could still use up the month's Redis commands, which pauses the server until the month turns. The next step, if abuse shows up, is App Attest on registration.

The server stores the push token, the run, the trip segment and the alert choice per activity, and deletes them when the activity ends, three days after the run at the latest. It keeps no logs of registrations; the rate limit keeps a per-address counter, deleted within two hours.

## Local development

```sh
cd server
npm ci
npm test            # contract, alert, tick and APNs tests
npm run typecheck
```

`npx vercel dev` runs the functions locally against the real Redis and APNs if the environment variables are pulled with `npx vercel env pull`.
