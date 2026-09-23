# Security

Headroom reads the sign-in tokens of Claude Code and Codex CLI. Anyone who could change what Headroom does could steal those tokens, so the project is set up to make that hard. This page explains how, and how to check a download yourself.

## Supply-chain protections

| Risk | What protects Headroom |
| --- | --- |
| A malicious or hijacked **dependency** (the npm/PyPI-style attack) | Headroom has **no third-party packages**: only Apple's frameworks. CI fails if `Package.swift` gains a package dependency or a `Package.resolved` appears (`scripts/check-no-dependencies.sh`). |
| A compromised **GitHub Action** (e.g. a tag re-pointed to malicious code, as happened to `tj-actions/changed-files` in 2025) | Only GitHub's own `actions/*` are used, each **pinned to a full commit SHA**, which can't be moved. Dependabot proposes updates as PRs with a 7-day cooldown, so a freshly published malicious version isn't picked up straight away. |
| A workflow **leaking or misusing its token** | Workflows default to a read-only `GITHUB_TOKEN`. Only the release job can write, and only to create the release. `persist-credentials: false` keeps the token out of the checkout. No `pull_request_target`, and no secrets. |
| A **release built from unreviewed code** | The release workflow only runs for `v*` tags, refuses tags that aren't on `main`, and requires the tag to match the version in `Info.plist`. It runs the tests and a launch check before publishing. |
| A **tampered download** | Each release publishes the SHA-256 of `Headroom.zip`. While the repository is public, it also publishes a signed [build provenance attestation](https://docs.github.com/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds) that proves which commit and workflow produced the zip. |
| **Code injection** into the running app | The app is signed with the **hardened runtime** (CI checks this), so macOS refuses `DYLD_INSERT_LIBRARIES`, unsigned libraries and debugger attach. |
| A hijacked **update channel** | There is none. Headroom never downloads or runs code. Updating means downloading a new release yourself. |

At runtime Headroom only talks to `api.anthropic.com` and `chatgpt.com`, reads tokens without writing or refreshing them, and never includes token values in error messages.

### Not covered: Apple notarization

Releases are **ad-hoc signed, not notarized**, because notarization needs a paid Apple Developer account. macOS therefore warns on first launch, and Gatekeeper can't vouch for the app. Checking the SHA-256 (and, for a public repo, the attestation) is what tells you the zip came from this repository's CI. With a Developer ID certificate, the release workflow could sign and notarize instead.

## Verifying a download

Put Headroom.zip in your Downloads folder and run these commands in Terminal.

1. Compare this hash with the one on the release page:

   ```sh
   shasum -a 256 ~/Downloads/Headroom.zip
   ```

2. Public repositories only: check the build provenance (needs the [GitHub CLI](https://cli.github.com)):

   ```sh
   gh attestation verify ~/Downloads/Headroom.zip --repo jengguru/claude-usage-menubar
   ```

3. After unzipping, check the signature and hardened runtime (look for `flags=0x10002(adhoc,runtime)`):

   ```sh
   codesign -dv ~/Downloads/Headroom.app
   ```

## Settings to enable on GitHub (repository owner)

These protections live in the repository settings, not in code:

- **Settings → General → Default branch:** `main`.
- **Settings → Rules → Rulesets:** a branch ruleset for `main` (require a pull request, require the `macos` status check, block force pushes and deletions), plus a tag ruleset for `v*` that only you can create, update or delete.
- **Settings → Actions → General:** allow only actions created by GitHub, and set workflow permissions to "Read repository contents".
- **Settings → Code security:** Dependabot alerts and security updates on, plus secret scanning and push protection where your plan offers them.
- Your GitHub account: two-factor authentication with a passkey or security key.

## Reporting a vulnerability

Please report it privately through GitHub's **Report a vulnerability** button on the Security tab (or contact the repository owner directly), not in a public issue.
