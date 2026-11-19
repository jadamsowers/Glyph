# TestFlight

`scripts/testflight.sh` archives the Mac app, signs it for the App Store with team `9247LFQ5JV`, and uploads it to App Store Connect. The project stays ad-hoc signed, so CI and the GitHub releases still build without an Apple account. Only this script signs with the team.

## One-time setup
1. **App ID.** `co.jadam.glyph` is registered as a universal App ID, so the same ID covers iOS and macOS.
2. **App record.** In App Store Connect, go to Apps › **+** › New App and fill it in:
   - Platforms: macOS, plus iOS once there's an iOS build
   - Bundle ID: `co.jadam.glyph`
   - SKU: `glyph`
3. **Testers.** Under TestFlight › Internal Testing, create a group and add yourself. Internal builds don't need Beta App Review.
4. **Signing.** Either sign in to Xcode › Settings › Accounts with the team's Apple ID, or use an App Store Connect API key with the App Manager role. Save the key as `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` with mode 600, then export its IDs:
   ```sh
   export ASC_KEY_ID=<KEY_ID> ASC_ISSUER_ID=<issuer UUID>
   ```
   Set `ASC_KEY_PATH` too if the key lives somewhere else.

## Each upload
```sh
scripts/testflight.sh
```
The script:
- regenerates the project;
- archives a universal Release build with a timestamp build number (`YYYYMMDD.HHMM`), so each upload is newer than the last and there's nothing to commit;
- exports and uploads the build.

The build appears under TestFlight after processing, usually within 5–15 minutes. Install it with the TestFlight app on the Mac.

The marketing version is `MARKETING_VERSION` in `App/project.yml`. Raise it when a version's TestFlight cycle is finished.

## Already handled in `project.yml`
- `ITSAppUsesNonExemptEncryption = NO`: Glyph has no encryption of its own, so App Store Connect doesn't ask about export compliance for each build.
- The Graphics & Design category, which the Mac App Store requires.
- The App Sandbox, with read-write access to files the user picks (`App/Glyph.entitlements`).
