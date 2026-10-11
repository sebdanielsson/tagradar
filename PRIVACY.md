# Privacy Policy / Integritetspolicy

_Last updated: 2026-10-09_

## English

Tågradar does not collect, store or share any personal data beyond what is needed to update the trains you follow (see Live Activities below).

- **No accounts, no analytics, no tracking.** The app contains no third-party SDKs, advertising or analytics.
- **Train data** is fetched directly from Trafikverket's Open API (`api.trafikinfo.trafikverket.se`). Requests contain the train numbers and stations you look at and an API key, but nothing that identifies you. Trafikverket's handling of API traffic is described in their own terms at <https://data.trafikverket.se>.
- **Location** is only used, with your permission, to centre the map on where you are and to find the station nearest to you for the "Near you" departures. Your position is processed on your device and never leaves it. To show those departures, the app asks Trafikverket for that station's board, the same kind of request as for any station you open, so the request names the station but not where you are.
- **Microphone and speech recognition** are only used when you tap the microphone in the search field. Recognition runs on the device when the system supports it; otherwise Apple's speech service processes the audio under Apple's privacy terms. No recordings are stored by the app.
- **Saved trains, favourite stations, settings and notification state** are stored on your device (and in your iCloud device backup if you have backups enabled). They are never sent to us.
- **Live Activities.** When you follow a train, the app sends Tågradar's push server the Live Activity's push token (a random identifier Apple issues for that one activity), the train number and date, the stops you picked and whether you want alerts for it. The server uses them only to send that activity its updates and alerts through Apple's push service, and deletes them when the activity ends, at the latest three days after the trip. Along with them go the activity's own identifier and which build of the app sent it; nothing identifies you. As with any web request, the hosting provider sees the connection's IP address, which the server uses only to limit how many requests one address can make per hour and deletes within two hours. The server runs on Vercel and stores this data in Upstash; both act as processors.
- **Other notifications** are generated locally on your device.

Apart from the followed trains above, the app has no backend, so we cannot see who uses it or what they look at.

Questions: open an issue at <https://github.com/sebdanielsson/tagradar/issues>.

## Svenska

Tågradar samlar inte in, lagrar eller delar några personuppgifter utöver det som behövs för att uppdatera tågen du följer (se Live Activities nedan).

- **Inga konton, ingen analys, ingen spårning.** Appen innehåller inga tredjeparts-SDK:er, annonser eller analysverktyg.
- **Tågdata** hämtas direkt från Trafikverkets öppna API (`api.trafikinfo.trafikverket.se`). Anropen innehåller de tågnummer och stationer du tittar på samt en API-nyckel, men ingenting som identifierar dig. Trafikverkets hantering av API-trafik beskrivs i deras villkor på <https://data.trafikverket.se>.
- **Plats** används bara, med ditt tillstånd, för att centrera kartan där du är och för att hitta stationen närmast dig till avgångarna under "Nära dig". Din position behandlas på din enhet och lämnar den aldrig. För att visa avgångarna hämtar appen stationens tavla från Trafikverket, på samma sätt som för vilken station du än öppnar, så anropet innehåller stationen men inte var du befinner dig.
- **Mikrofon och taligenkänning** används bara när du trycker på mikrofonen i sökfältet. Igenkänningen sker på enheten när systemet stödjer det; annars behandlar Apples taltjänst ljudet enligt Apples integritetsvillkor. Appen sparar inga inspelningar.
- **Sparade tåg, favoritstationer, inställningar och aviseringsstatus** lagras på din enhet (och i din iCloud-säkerhetskopia om du har den påslagen). De skickas aldrig till oss.
- **Live Activities.** När du följer ett tåg skickar appen Live Activityns push-token (en slumpmässig identifierare som Apple utfärdar för just den aktiviteten), tågnummer och datum, de stationer du valt och om du vill ha aviseringar för tåget till Tågradars push-server. Servern använder dem bara för att skicka aktivitetens uppdateringar och aviseringar via Apples push-tjänst och raderar dem när aktiviteten avslutas, senast tre dagar efter resan. Tillsammans med dem skickas aktivitetens egen identifierare och vilken version av appen som skickade dem; inget identifierar dig. Som vid alla webbanrop ser värdtjänsten anslutningens IP-adress, som servern bara använder för att begränsa hur många anrop en adress kan göra per timme och raderar inom två timmar. Servern körs hos Vercel och lagrar uppgifterna hos Upstash; båda är personuppgiftsbiträden.
- **Övriga notiser** skapas lokalt på din enhet.

Utöver följda tåg enligt ovan har appen ingen backend, så vi kan inte se vem som använder den eller vad de tittar på.

Frågor: öppna ett ärende på <https://github.com/sebdanielsson/tagradar/issues>.
