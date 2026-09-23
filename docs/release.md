# Releasing Tågradar

How builds get to TestFlight and the App Store, and what a maintainer has to set up once. The pipeline is `.github/workflows/ci.yml`; nothing is built or signed on anyone's Mac.

## The flow

```text
push / PR ──▶ verify (lint, format, tests, simulator build)
                 │
   push to main ─┼──▶ testflight     archive → upload to TestFlight (build = run number)
                 │
                 └──▶ release-please  keeps a "chore(main): release X.Y.Z" PR up to date
                          │
      merge that PR ──────┴──▶ tag vX.Y.Z + GitHub release
                                  └──▶ appstore  archive → upload → metadata + screenshots → submit for review
```

- **Every push to `main`** produces a TestFlight build. Internal testers see it after Apple's processing; the build number is the workflow run number, the version is `version.txt`. The App Store build from a release run gets `<run number>.<run attempt>` (for example `202.1`), because the TestFlight job of that same run, which runs in parallel, also uploads the release version, as build `<run number>`; the suffix keeps the two uploads from colliding whichever finishes first.
- **Releases** are driven by [release-please](https://github.com/googleapis/release-please). It reads the commit messages on `main` and maintains a release pull request that bumps `version.txt`, `project.yml` (`MARKETING_VERSION`) and `CHANGELOG.md`. Merging that PR creates the tag and the GitHub release, and the same workflow run then submits the tagged build to App Store Review.
- After Apple approves, **release it manually** in App Store Connect (the workflow sets `automatic_release: false`), so the store listing and the GitHub release can go out together.

### Commit messages decide the version

release-please uses [Conventional Commits](https://www.conventionalcommits.org/):

| Commit | Effect |
|---|---|
| `fix: ...` | patch bump, listed under Bug Fixes |
| `feat: ...` | minor bump, listed under Features |
| `feat!: ...` or a `BREAKING CHANGE:` footer | major bump (minor while still on 0.x) |
| `docs:`, `chore:`, `ci:`, `refactor:`, `test:`, `build:` | no release on their own, hidden from the changelog |

Squash-merge pull requests and make the PR title a conventional commit; that title becomes the commit on `main`. To pick an exact version (for example the first `1.0.0`), add a footer `Release-As: 1.0.0` to any commit on `main`, or edit the version in the release PR.

## One-time setup

### 1. Apple Developer / App Store Connect

- Paid Apple Developer Program membership. Bundle identifier `se.tagradar.app` (plus `.widgets`) is registered by Xcode's automatic signing on the first archive, together with App Groups (`group.se.tagradar.app`), Keychain Sharing and Background Modes.
- In App Store Connect, create the app once: name **Tågradar**, bundle ID `se.tagradar.app`, SKU e.g. `tagradar`, primary language English, availability Sweden (and anywhere else). The workflow fills in metadata, screenshots and the What's New text; **age rating** (4+) and the **App Privacy** questionnaire ("no data collected", see `PRIVACY.md`) must be answered by hand in App Store Connect the first time.
- **API key**: App Store Connect → Users and Access → Integrations → App Store Connect API → *Team Keys* → Generate. Role **Admin** (cloud-managed signing needs Admin; App Manager is enough for uploads but not for creating the distribution certificate). Download the `.p8` once; note the Key ID and the Issuer ID.
- TestFlight: add internal testers under the app's TestFlight tab. Every upload becomes available to them automatically.

### 2. GitHub secrets

Repository → Settings → Secrets and variables → Actions → *Repository secrets*:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | 10-character team ID (also hard-coded as `teamID` in `ExportOptions*.plist`) |
| `APP_STORE_CONNECT_KEY_ID` | Key ID of the API key |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID shown above the key list |
| `APP_STORE_CONNECT_KEY_BASE64` | The `.p8` file, base64 encoded: `base64 -i AuthKey_XXXXXXXXXX.p8 \| pbcopy`. Pasting the raw PEM works too. |
| `TRV_API_KEY` | Trafikverket Open API key baked into the build |
| `DISTRIBUTION_CERTIFICATE_P12_BASE64` | The pinned Apple Distribution certificate, base64 encoded — see below |
| `DISTRIBUTION_CERTIFICATE_PASSWORD` | The export password chosen when creating that `.p12` |
| `DEVELOPMENT_CERTIFICATE_P12_BASE64` | The pinned Apple Development certificate, base64 encoded — see below |
| `DEVELOPMENT_CERTIFICATE_PASSWORD` | The export password chosen when creating that `.p12` |

`Scripts/ci/write-asc-key.sh` checks that the decoded key is a PEM file before Xcode uses it. "Authentication failed: Make sure a bearer token was provided" from `xcodebuild` means the key, key ID and issuer ID do not belong together, the key was revoked, or it is an *individual* key instead of a *team* key.

#### Why pinned certificates

Provisioning profiles are still fully cloud-managed (`-allowProvisioningUpdates`), but the certificates themselves are pinned rather than left for Xcode to create automatically. GitHub-hosted runners are ephemeral — a fresh VM every run, with no keychain from the previous run — so cloud-managed signing can never reuse a certificate it created earlier; it has to ask Apple for a brand new one each time it can't find a matching private key locally. Apple caps how many certificates of each type an account can hold at once, so this eventually fails with `Choose a certificate to revoke. Your account has reached the maximum number of certificates.`

Both an Apple Distribution *and* an Apple Development certificate need pinning. Archiving only the Release configuration isn't enough to dodge this: `-allowProvisioningUpdates` syncs every signing style referenced anywhere in the project, including the Apple Development one the Debug configuration uses (`CODE_SIGN_STYLE: Automatic` sits on `settings.base` in `project.yml`, so it applies to every config) — so an ephemeral runner with only the distribution certificate pinned still mints a fresh development certificate on every run and eventually exhausts that limit instead.

`Scripts/ci/import-signing-certificate.sh` imports both certificates + private keys into a temporary keychain before every archive, so Xcode always finds valid local identities and only has to manage provisioning profiles — which don't count against the certificate limit.

To create a pinned certificate once (repeat for both Distribution and Development):

1. developer.apple.com → Certificates, Identifiers & Profiles → Certificates → if the account is already at the limit, revoke an old/unused certificate of that type first to free a slot.
2. On a Mac with this account signed into Xcode, either let Xcode create one (Settings → Accounts → Manage Certificates → **+** → Apple Distribution / Apple Development) or create it in the portal from a CSR (Keychain Access → Certificate Assistant → *Request a Certificate From a Certificate Authority*).
3. In Keychain Access, find that certificate under **My Certificates** (it must show the private key nested under it — export fails otherwise), select it, *File → Export Items…*, save as `DistributionCertificate.p12` / `DevelopmentCertificate.p12` with an export password.
4. `base64 -i DistributionCertificate.p12 | pbcopy` → paste as the `DISTRIBUTION_CERTIFICATE_P12_BASE64` secret; the export password becomes `DISTRIBUTION_CERTIFICATE_PASSWORD`. Same pattern for the development certificate's two secrets.

Each certificate is valid for a year; when one expires, repeat steps 2–4 for that type and update its two secrets.

### 3. GitHub settings

- Settings → Actions → General → *Workflow permissions*: tick **Allow GitHub Actions to create and approve pull requests** (release-please opens the release PR with the built-in token).
- Environments `testflight` and `app-store` are created automatically on first use. Optionally add yourself as a **required reviewer** on `app-store` to get an approval step before anything is submitted to Apple.

## Day to day

- Merge work into `main` with conventional commit messages → TestFlight build appears, release PR is updated.
- When ready to ship: merge the release PR → wait for the *App Store* job → approve/release in App Store Connect.
- On-demand TestFlight from any branch: Actions → CI/CD → *Run workflow*.
- Store text lives in `fastlane/metadata/<locale>/*.txt` (English `en-US`, Swedish `sv`); screenshots in `fastlane/screenshots/<locale>/` (`Scripts/screenshots.sh` regenerates them at the sizes App Store Connect requires; `LOCALES=sv` for Swedish only). Both are uploaded with every release and overwrite what is in App Store Connect.
- App Privacy details cannot be updated through the API key; change them in App Store Connect if the app ever starts collecting data.

## Building to your own device from another team

Bundle IDs and App Groups are unique across Apple teams, so a developer who is not on the release team cannot sign `se.tagradar.app`. Put your own prefix in `.env.local` and run `Scripts/bootstrap.sh`:

```bash
APP_BUNDLE_ID=se.example.tagradar
DEVELOPMENT_TEAM=XXXXXXXXXX
```

Everything derived from it (widget bundle ID, App Group, Keychain group, background task identifier) follows. CI and release builds do not set `APP_BUNDLE_ID` and therefore use `se.tagradar.app`.

## Local equivalents

```bash
Scripts/bootstrap.sh                 # Secrets.xcconfig + Xcode project
Scripts/screenshots.sh               # App Store screenshots
fastlane release ipa:… version:…     # what the appstore job runs (needs the same env vars)
```
