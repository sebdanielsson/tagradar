# Content state contract

Each file is one Trafikverket response plus the station list, a trip segment and a clock. `expected` is the `TrainActivityAttributes.ContentState` the push server sends for it, as ActivityKit decodes it (dates in seconds since 2001-01-01).

Both implementations run every fixture: `test/contract.test.ts` (TypeScript) and `TagradarTests/PushContractTests.swift` (the app's own `TrainSnapshot` and `ContentState`). If either drifts, its test fails.

After changing the server's output on purpose, regenerate `expected` with `UPDATE_CONTRACT=1 npm test`, then run the app tests to confirm Swift agrees. Keep `ModifiedTime` on whole seconds: the comparison is exact, and fractional seconds round differently in the two languages.
