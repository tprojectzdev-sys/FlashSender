# FileDrop (iOS)

Native SwiftUI app for sending and receiving files with the [FileDrop Rust server](../server/) on Windows over Wi-Fi (mDNS) or USB (`iproxy`).

## CI build (no local Mac required)

Pushes to `main` and manual **workflow_dispatch** run [.github/workflows/build.yml](.github/workflows/build.yml) on `macos-latest`:

1. Xcode 16
2. Unsigned `xcodebuild` (`CODE_SIGNING_ALLOWED=NO`)
3. IPA packaged as `FileDrop.ipa`
4. Artifact retained 7 days

Download the IPA from the GitHub Actions run → **Artifacts** → `FileDrop-ipa`.

Install with [Sideloadly](https://sideloadly.io/) and a free Apple ID.

## Wire protocol

Client messages use `action` (matches the Rust server):

- Upload: `{"action":"upload","filename":"…","size":N}` + binary chunks (512 KB)
- Download: `{"action":"download","filename":"…"}`
- List: `{"action":"list"}`

Server events: `transfer_start`, `transfer_progress`, `transfer_complete`, `file_list`, `file_added`.

## Connection

1. mDNS browse `_filedrop._tcp` for 5 seconds
2. Fallback: `ws://127.0.0.1:8765/` (USB + `iproxy 8765 8765`)
3. Auto-reconnect with exponential backoff (max 30 s)

## Requirements

- iPhone, iOS 18+
- Bundle ID: `com.local.filedrop`
- Zero Swift package dependencies
