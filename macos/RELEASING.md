# Native macOS builds and releases

The native artifact is `com.komoliddin.ZapFastMac`, with the
`com.komoliddin.ZapFastMac.Share` extension. It supports Apple Silicon and
macOS 15 or later. The root egui binary is a different interface.

`make ci` in `macos/` uses the same checks as the Native macOS workflow:
engine-only tests and clippy, bridge tests and clippy, Swift tests, a fresh
source warning check, dependency inventory consistency, and an unsigned
native Release build. Xcode 26+ / Swift 6.2+, Rust 1.98+, XcodeGen, CMake,
and the Xcode command line tools are required. Dependency locks are enforced.
The generated Xcode workspace receives the Swift package's committed pins.
CI uses the [macos-26 arm64 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
The inherited root CI checks remain alongside the native job.

The build validator checks the bundle identifiers, arm64 slices, native
framework links, Share extension and bundled license resources. An unsigned
CI build verifies compilation; it is not a distribution signature.

## License review

`DEPENDENCY-LICENSES.md` records the native Rust graph, Swift pins and
available license texts. Generate it after resolving Swift dependencies:

```sh
python3 macos/Scripts/license-inventory.py
```

Some packages do not carry full license texts in their packaged sources.
Those entries and bundled assets require review too. The inventory describes
declarations, including their ambiguities; it does not establish compatibility.

`wacore-libsignal` declares MIT while retaining Signal AGPL-3.0-only headers
at the locked revision. Upstream clarification is still pending. Do not
relicense the dependency here or describe the complete binary as MIT-only.
The release gate currently fails deliberately. Record a substantiated decision
in `release-license-review.json` only after resolving the review, with status
`resolved` and hashes matching both native locks. Changing dependencies
invalidates that review. No binary is uploaded by normal CI.

## Distribution workflow

1. Set the native `MARKETING_VERSION` and build number in `project.yml`.
   Run all checks and write reviewed notes to `macos/release-notes/v<version>.md`.
   Follow AGENTS.md's note style, read the previous two stable Spotifast
   releases first, and use synthetic content for any media. No generated or
   placeholder release notes are published. Commit and push to `origin/main`.
2. Only tag a commit already reachable from `origin/main`. The `v*` tag must
   match the native version, optionally with `-alpha.N`, `-beta.N` or `-rc.N`.
   The root engine's version is independent. The workflow verifies ancestry,
   version, reviewed release notes and license review before building.
3. Configure the `native-release` GitHub environment and its secrets:
   `MAC_CERTIFICATE_P12` (base64 P12 with private key),
   `MAC_CERTIFICATE_PASSWORD`, `MAC_SIGN_IDENTITY` (Developer ID Application),
   `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD` (app-specific).
4. The workflow checks the native build, signs nested components and the app
   with hardened runtime and their entitlements, submits to Apple's notary
   service, staples and validates the ticket, then assesses Gatekeeper.
   The temporary signing keychain is deleted on exit.
5. It prepares a **draft** GitHub release containing only the notarized
   `ZapFast-native-macos-arm64-v<version>.zip` and SHA-256 checksums.
   Review the notes and install/call/media behavior before publishing it.

See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
Developer ID signing, notarization, Gatekeeper assessment on another Mac and
the hosted workflow still require a real release rehearsal. Local tests do
not prove that those credential-dependent operations work.

Native in-app updating is not implemented. The inherited egui updater and
its release signatures are not a native update mechanism. Install native
releases manually until a separately scoped native updater is implemented.
