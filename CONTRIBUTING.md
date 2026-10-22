# Development and releases

`main` is the production branch. Its source must match the supported features in the README.
Release tags identify the exact source used for downloadable packages.

`codex/develop` is the local working branch. It preserves ongoing experiments separately
from production. Keep unpublished work local; do not push this branch or use `git push --all`.
Promote reviewed, tested changes individually to `main`, rather than merging the entire
experimental branch. Do not merge production cleanup back into development blindly.

Before a release:

1. Run `swift test -c release --package-path apps/macos`. For file-transfer changes,
   use `RUN_LARGE_TRANSFER_TESTS=1 swift test -c release --package-path apps/macos`
   to stream a full 1 GB file through the production send/receive code and verify resumption.
2. With JDK 17 and Android SDK 36 configured, run
   `./gradlew :core:test :app:assembleDebug :app:lintDebug` from `apps/android`.
3. Verify the supported features on paired devices. Keep synthetic test data out of personal messages.
4. Update Android versionName/versionCode and the Mac packaging script version together.
5. Build packages from a clean production commit and verify their versions and signatures.
6. Tag that commit, publish checksums alongside both packages, and mark the release latest.

The current packages use development signing. Preserve the Android signing key for upgrade
compatibility. Developer ID signing/notarization and store distribution require separate setup.
