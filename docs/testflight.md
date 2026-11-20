# TestFlight

`scripts/testflight.sh` archives Glyph for Mac and for iPhone and iPad, signs both for the App Store with team `9247LFQ5JV`, and uploads them to App Store Connect. Both platforms share the "Glyph Vectorizer" app record. The project stays ad-hoc signed, so CI and the GitHub releases still build without an Apple account. Only this script signs with the team.

## One-time setup
1. **App ID.** `co.jadam.glyph` is registered as a universal App ID, so the same ID covers iOS and macOS.
2. **App record.** In App Store Connect, go to Apps › **+** › New App and fill it in:
   - Platforms: macOS and iOS
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
scripts/testflight.sh          # Mac, iPhone and iPad
scripts/testflight.sh ios      # or one platform: macos | ios
```
The script:
- regenerates the project;
- archives each platform in Release with one timestamp build number per run (`YYYYMMDD.HHMM`), so each upload is newer than the last and there's nothing to commit;
- exports and uploads each build.

The build appears under TestFlight after processing, usually within 5–15 minutes. Install it with the TestFlight app on Mac, iPhone and iPad.

The marketing version is `MARKETING_VERSION` in `App/project.yml`. Raise it when a version's TestFlight cycle is finished.

## Already handled in `project.yml`
- `ITSAppUsesNonExemptEncryption = NO`: Glyph has no encryption of its own, so App Store Connect doesn't ask about export compliance for each build.
- The Graphics & Design category, which the Mac App Store requires.
- The App Sandbox on macOS, with read-write access to files the user picks (`App/Glyph.entitlements`).
- On iOS, the increased memory limit entitlement (`App/Glyph-iOS.entitlements`), which gives full-resolution phone photos headroom, and the camera usage string.
