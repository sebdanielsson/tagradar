# App Store submission

Everything App Store Connect asks for before Tågradar can go on sale, in the order its forms ask for it, with the exact value to enter. Work top to bottom; each section says whether the repository already handles it.

The build pipeline itself (TestFlight on every push to `main`, App Store submission when a release is tagged) is `docs/release.md`. This page is only about the listing.

Sources: Apple's [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/), [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/), [age ratings](https://developer.apple.com/help/app-store-connect/reference/age-ratings-values-and-definitions/) and [EU Digital Services Act trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/) references.

## Who fills in what

| Field | Where it comes from |
|---|---|
| App name, subtitle, description, keywords, promotional text, support and marketing URLs, privacy policy URL | `fastlane/metadata/<locale>/*.txt`, uploaded by the App Store job |
| Screenshots | `fastlane/screenshots/<locale>/*.png`, uploaded by the App Store job |
| What's New | The GitHub release body, via `Scripts/ci/release-notes.sh` |
| App Review notes | `fastlane/metadata/review_information/notes.txt` |
| Categories, copyright | `fastlane/metadata/*.txt` |
| IDFA, export compliance, content rights answers | `fastlane/Fastfile` (`submission_information:`) |
| App icon | `Tagradar/AppIcon.icon`, compiled into the build |
| **Trader status, age rating, App Privacy, pricing, availability, review contact details** | **By hand in App Store Connect — no API can set them** |

Everything in the first group is overwritten on every release, so edit it in the repository, not in the browser.

Permission alerts are localized too: the English source strings are the `NS*UsageDescription` keys in `project.yml`, and `Tagradar/Resources/InfoPlist.xcstrings` holds the Swedish.

**Do the by-hand parts before merging the release PR.** `fastlane release` ends with `submit_for_review: true`, and Apple refuses a submission whose age rating or App Privacy answers are missing — the whole App Store job fails at its last step.

## 1. Account, once per developer account

- [ ] **Paid Apple Developer Program membership.** The free Personal Team can build to your own devices but cannot upload to App Store Connect. Everything the app does (App Groups, Live Activities, local notifications, background refresh) works on both.
- [ ] **Agreements.** App Store Connect → Business → Agreements. The Free Apps agreement must be active; the app is free, so no banking or tax details are needed.
- [ ] **EU trader status (Digital Services Act).** App Store Connect → Business → Agreements tab → Compliance section → Digital Services Act → *Complete Compliance Requirements*. Required whether or not you distribute in the EU; apps without a verified status are removed from the EU App Store. Sweden is in the EU, so this is a hard blocker, and Apple's verification takes days — do it first.

  A hobby app given away for free is normally **not** a trader, but the test is about acting for purposes relating to a trade or profession, not about charging money. If you declare trader, the name, address, phone number and email address you enter are shown publicly on the App Store product page.

- [ ] **App Store Connect API key** for CI. Users and Access → Integrations → App Store Connect API → *Team Keys* → Generate, role **Admin**. See `docs/release.md` for the three secrets it becomes.
- [ ] **`DEVELOPMENT_TEAM`** in `.env.local` set to the paid team, and `APPLE_TEAM_ID` set as a GitHub secret.

## 2. Register the app

- [ ] **Bundle ID** `se.tagradar.app` with App Groups (`group.se.tagradar.app`), Keychain Sharing and Background Modes. Xcode's automatic signing registers it on the first archive, and the widget extension's `se.tagradar.app.widgets` with it.
- [ ] **Create the app record.** App Store Connect → Apps → **+** → New App. It must exist before the App Store job runs, or `fastlane release` has nothing to upload to.

  | Field | Value |
  |---|---|
  | Platforms | iOS |
  | Name | `Tågradar` |
  | Primary language | English (U.S.) |
  | Bundle ID | `se.tagradar.app` |
  | SKU | `tagradar` |
  | User access | Full Access |

- [ ] **Add the Swedish localization.** The version page's language selector → Swedish. The App Store job uploads `fastlane/metadata/sv/*.txt` into it; if the locale does not exist yet the upload has nowhere to put the Swedish text.

## 3. App Information

Left sidebar → General → App Information. Fields marked *(uploaded)* are pushed by every release; the value below is what the repository holds, and what you see in the browser before the first upload will be blank.

| Field | Value |
|---|---|
| Name *(uploaded)* | `Tågradar` (8 of 30 characters) |
| Subtitle, English *(uploaded)* | `Live trains across Sweden` (25 of 30) |
| Underrubrik, Swedish *(uploaded)* | `Sveriges tåg i realtid` (22 of 30) |
| Privacy Policy URL *(uploaded)* | `https://github.com/sebdanielsson/tagradar/blob/main/PRIVACY.md` |
| Primary category *(uploaded)* | Travel |
| Secondary category *(uploaded)* | Navigation |
| License agreement | Apple's standard EULA — leave as is |

- [ ] **Content Rights.** "Does your app contain, show, or access third-party content?" → **Yes**, then confirm you hold the rights. Every screen shows Trafikverket's train data, which is theirs and not yours; CC0 grants exactly the permission the confirmation asks you to attest to. Answering No would be the riskier reading of a question about what the app displays rather than who wrote it. `fastlane/Fastfile` sends the matching `content_rights_contains_third_party_content: true` with every submission — keep the two in step.

### Age rating

App Information → Age Rating → Edit. The questionnaire was expanded in 2025 and now produces 4+, 9+, 13+, 16+ or 18+. Tågradar answers **None / No** to every question, which yields **4+**:

- No cartoon, fantasy or realistic violence; no profanity, crude humour, sexual content, nudity, horror or gambling themes.
- No alcohol, tobacco or drug references, no medical or wellness content, no violent themes.
- **Unrestricted web access:** No. There is no in-app browser and no address bar, so nothing a user types can navigate anywhere. The few links the app does show — Trafikverket's key registration page, the GitHub source and issue tracker, and an operator's own site from a journey's facts — hand a fixed URL to Safari.
- **User-generated content / social features / messaging:** No. There is no account, no server and nothing any user can publish.
- **In-app controls (parental controls, purchases, advertising):** None.
- [ ] Answered, showing 4+.

## 4. Pricing and Availability

- [ ] **Price:** Free (price schedule: Free, no scheduled changes).
- [ ] **Availability:** all countries and regions. The data only covers Sweden, but there is no reason to hide the app from Swedes abroad, and restricting availability adds nothing.
- [ ] **Pre-orders:** off.
- [ ] **Distribution methods:** App Store only — no Custom Apps, no Apple Vision Pro (the app is iPhone and iPad only).

## 5. App Privacy

Left sidebar → App Privacy. This one genuinely cannot be automated, and a missing answer blocks the submission.

- [ ] **Privacy Policy URL:** `https://github.com/sebdanielsson/tagradar/blob/main/PRIVACY.md`
- [ ] **Data collection:** choose **"No, we do not collect data from this app."**

That answer is accurate and worth being able to defend, because the app does touch location, microphone and speech:

- There is no backend and no analytics, so no data reaches the developer by any path.
- Location is used on the device to centre the map and to find the nearest station for "Near you"; the position never leaves the device. Only that station's signature goes to Trafikverket, in the same departure-board request as for any station the user opens.
- Microphone audio and speech recognition are handled by Apple's own services under Apple's privacy terms; the app stores no recordings. Apple's questionnaire asks what *you* collect, not what the system does on the user's behalf.
- Trafikverket receives anonymous API requests carrying train numbers, station signatures and an API key — nothing that identifies the user.

This matches `PRIVACY.md` and `Tagradar/Resources/PrivacyInfo.xcprivacy`, which declares no collected data types, no tracking, and the one required-reason API the app uses (`UserDefaults`, reason `CA92.1` — shared with the widget through the App Group). The widget extension is a separate binary and reaches the same App Group, so `project.yml` builds that manifest into it as well; keep both in step, and update it if a new required-reason API is ever added.

## 6. The version page (1.0.0)

Almost all of this is uploaded, but the fields are listed so you can check them after the job runs.

| Field | Value |
|---|---|
| Promotional text *(uploaded)* | `Every train in Sweden, live, straight from Trafikverket's open data. No account, no ads, no tracking.` (101 of 170) |
| Description *(uploaded)* | `fastlane/metadata/en-US/description.txt` (786 of 4000) and `sv/description.txt` |
| Keywords, English *(uploaded)* | `train,trains,Sweden,SJ,Trafikverket,delay,departures,railway,live map,timetable` (79 of 100) |
| Nyckelord, Swedish *(uploaded)* | `tåg,tågtider,försening,avgångar,Trafikverket,SJ,järnväg,karta,tidtabell,pendeltåg` (81 of 100) |
| Support URL *(uploaded)* | `https://github.com/sebdanielsson/tagradar/issues` |
| Marketing URL *(uploaded)* | `https://github.com/sebdanielsson/tagradar` |
| Copyright *(uploaded)* | `2026 Sebastian Danielsson` |
| What's New *(uploaded)* | The GitHub release body for the tag |
| Version | `1.0.0`, from `version.txt` — release-please owns it |
| Build | The CI run number, picked up automatically after processing |

- [ ] **App Review Information → contact details.** First name, last name, phone number and email address. Entered by hand once; App Store Connect keeps them for later versions. Leave "Sign-in required" **off** — the app has no account.
- [ ] **App Review Information → notes.** Uploaded from `fastlane/metadata/review_information/notes.txt`. Check it reads sensibly after the first upload.
- [ ] **Version Release:** "Manually release this version". The Fastfile sets this (`automatic_release: false`) so the store listing and the GitHub release can go out together.
- [ ] **Export compliance:** no question is asked. `ITSAppUsesNonExemptEncryption` is already `false` in `project.yml`, and the Fastfile repeats `export_compliance_uses_encryption: false` with the submission.
- [ ] **Advertising identifier:** No. The app contains no IDFA; the Fastfile sends `add_id_info_uses_idfa: false`.

### Screenshots

App Store Connect needs one set per device family the app runs on; `TARGETED_DEVICE_FAMILY` is `1,2`, so both are required. Alpha channels are not allowed and 1–10 images fit each size.

| Family | Simulator | Pixels (portrait) | In the repo |
|---|---|---|---|
| iPhone 6.9" | iPhone 17 Pro Max | 1320 × 2868 | 5 per locale |
| iPad 13" | iPad Pro 13-inch (M5) | 2064 × 2752 | 4 per locale |

Smaller iPhone and iPad sizes are scaled by Apple from these two, so nothing else has to be produced.

`Scripts/screenshots.sh` regenerates the whole set — both devices, both locales — and strips the alpha channel the simulator always writes (`Scripts/strip-alpha.swift`). It needs `TRV_API_KEY` in `.env.local` and [`idb`](https://fbidb.io): the iPhone shots drag the bottom card to the height that frames each subject, and the iPad shots open the sidebar.

```bash
Scripts/screenshots.sh                    # everything
TRAIN=560 Scripts/screenshots.sh          # pin the featured train instead of picking a live one
LOCALES=sv Scripts/screenshots.sh "iPhone 17 Pro Max"
```

Because the data is live, the script picks a train that is actually moving and pins two of them in Saved, so no screen is empty. Rerun it whenever the UI changes; the images are committed and uploaded with every release.

## 7. App icon

Nothing to upload — `Tagradar/AppIcon.icon` is an Icon Composer package and Xcode compiles every size and all six iOS 26 appearances (default, dark, clear light, clear dark, tinted light, tinted dark) from it, including the 1024 × 1024 App Store icon.

- Colours: default background Trafikverket red `#D70000` (the main red in Trafikverket's graphic manual), dark appearance `#AF0000`. Clear and tinted variants are derived by the system from the white layers.
- The glyph is original artwork drawn by `Scripts/make-app-icon.swift`. Apple's SF Symbols licence forbids using SF Symbols, or glyphs confusingly similar to them, in an app icon.
- Regenerate the layers with `swift Scripts/make-app-icon.swift`; preview an appearance with Icon Composer (Xcode → Open Developer Tool) or:

  ```bash
  "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
    Tagradar/AppIcon.icon --export-image --output-file out.png --platform iOS --rendition Dark \
    --width 1024 --height 1024 --scale 1
  ```

  Renditions: `Default`, `Dark`, `ClearLight`, `ClearDark`, `TintedLight`, `TintedDark` (the tinted ones take `--tint-color 0.6 --tint-strength 0.75`).
- `Marketing/AppIcon-1024.png` is a flattened fallback with no alpha, in case App Store Connect ever asks for a file.

## 8. Release day

1. Land everything you want in 1.0.0 on `main`. Each push builds a TestFlight build and updates the release PR.
2. Finish sections 1–5 above. Trader status has to be verified by Apple, so start it early.
3. Run a TestFlight round on a real device: notifications, Live Activity, widgets, and background refresh after the app has been backgrounded for a while.
4. Check that the release PR says the version you want. The first store release should be `1.0.0`; release-please picks it up from a `Release-As: 1.0.0` footer on a commit on `main`, or you can edit the version in the PR.
5. Merge the release PR. That tags `v1.0.0`, creates the GitHub release, and the App Store job archives, uploads, pushes metadata and screenshots, and submits for review.
6. Wait for approval, then press **Release This Version** in App Store Connect.

## Still worth doing

- [ ] Accessibility pass: Dynamic Type at the largest sizes, VoiceOver on the map controls, delay badges and the stop timeline.
- [ ] Trademark hygiene: "Trafikverket" appears only as the source of the data, with a non-affiliation note in both descriptions, and the red is a colour rather than their logotype. Never put the Trafikverket logotype in the app or the listing.
