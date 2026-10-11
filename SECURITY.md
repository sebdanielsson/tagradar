# Security Policy

## Supported versions

Only the latest release on the `main` branch is supported.

## Reporting a vulnerability

Please do not open public issues for security problems. Use GitHub's private vulnerability reporting on this repository ("Security" tab → "Report a vulnerability"). You should get a response within a week.

## Scope notes

- Tågradar stores the user's Trafikverket API key in the iOS Keychain and never transmits it anywhere other than `api.trafikinfo.trafikverket.se`.
- The app collects no analytics. Its only backend is the Live Activity push server in `server/` (Vercel, Upstash Redis; see `docs/live-activity-push.md`), which receives a followed train's activity push token, run, chosen stops and alert choice and deletes them when the activity ends.
- The app authenticates to that server with a shared secret built into the binary. It can be extracted, so it is not treated as a security boundary: registrations are validated, rate limited per client address, capped and short-lived, and a push only ever reaches the token that was registered. Reports about abusing it are still welcome.
