# FileDrop

Send and receive files between your **iPhone** and a **Windows PC** on the same Wi-Fi network, or over USB. No cloud, no account — just a small PC server and a sideloaded iOS app.

---

## What’s in this repo

| Folder | Purpose |
|--------|---------|
| `server/` | Rust WebSocket server for Windows |
| `FileDrop/` | iOS app (SwiftUI) — built in GitHub Actions |
| `start.bat` | Build and run the PC server in one click |

---

## Windows server setup

### 1. Install Rust

Download and run the installer from [https://rustup.rs](https://rustup.rs). When it finishes, open a **new** Command Prompt or PowerShell window.

### 2. Get the project

Clone this repository (or download it as a ZIP and extract it):

```powershell
git clone <your-repo-url>
cd "Flash Sender"
```

### 3. Start the server

Double-click **`start.bat`**, or run from a terminal:

```powershell
start.bat
```

The script will:

1. Build the release server (`cargo build --release`)
2. Start `filedrop-server.exe`
3. Print your **LAN IP**, **USB** hint, and port (**8765** by default)

**Write down the LAN IP** shown in the terminal (example: `192.168.1.42`).

### 4. Firewall

If Windows Defender Firewall asks, **allow** `filedrop-server.exe` on **private** networks. If the iPhone cannot connect over Wi-Fi, open **Windows Security → Firewall** and add an inbound rule for TCP port **8765**.

### Optional: change receive folder or port

| Variable | Default |
|----------|---------|
| `FILEDROP_OUTPUT_DIR` | `C:\FileDrop\received` |
| `FILEDROP_PORT` | `8765` |

---

## Build the iPhone app (GitHub Actions)

You do **not** need a Mac or Xcode on your PC. The IPA is built in the cloud.

### 1. Push to GitHub

Push this repo to GitHub (a **private** repo is fine).

### 2. Run the workflow

1. Open your repo on GitHub.
2. Go to the **Actions** tab.
3. Select **FileDrop Build**.
4. Click **Run workflow** (or push to the `main` branch to run automatically).
5. Wait about **5 minutes** for the job to finish.

### 3. Download the IPA

1. Open the completed workflow run.
2. Scroll to **Artifacts**.
3. Download **FileDrop-ipa** (contains `FileDrop.ipa`).

The unsigned IPA is valid for **7 days** in Artifacts; download it before it expires.

---

## Sideload with Sideloadly

[Sideloadly](https://sideloadly.io) installs the IPA using your Apple ID (a **free** account works).

### 1. Install Sideloadly

Download from [https://sideloadly.io](https://sideloadly.io) and install on Windows.

### 2. Connect your iPhone

1. Plug the iPhone into the PC with a USB cable.
2. On the iPhone, tap **Trust** when asked.
3. Enter your passcode if prompted.

### 3. Install FileDrop

1. Open **Sideloadly**.
2. Drag **`FileDrop.ipa`** into the Sideloadly window (or use the file picker).
3. Enter your **Apple ID** and password (or app-specific password if you use 2FA).
4. Click **Start** and wait until it reports success.

### 4. Trust the developer on iPhone

1. On the iPhone: **Settings → General → VPN & Device Management** (or **Device Management**).
2. Tap your Apple ID under **Developer App**.
3. Tap **Trust**.

### 5. Launch FileDrop

Open **FileDrop** from the home screen. The status bar should show **Searching**, then **Connected** when the PC server is running on the same network.

---

## USB tunnel (optional)

Use USB when Wi-Fi discovery does not work. The app automatically tries `ws://127.0.0.1:8765` after mDNS times out.

### 1. Install iTunes (Windows)

Install [iTunes for Windows](https://www.apple.com/itunes/download/) so **usbmuxd** can talk to the iPhone over USB.

### 2. Install iproxy

`iproxy` ships with [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice). On Windows you can use a build from that project, or run `iproxy` from WSL/macOS if you already use it there.

### 3. Forward the port

With the iPhone connected by USB:

```bash
iproxy 8765 8765
```

Leave that window open. FileDrop will connect to **`ws://127.0.0.1:8765`** when Bonjour does not find the PC.

> **Note:** The PC server must still be running (`start.bat`). `iproxy` only tunnels the phone’s localhost to the PC port.

---

## Using the app

1. **Start the PC server** (`start.bat`).
2. **Open FileDrop** on the iPhone (same Wi-Fi, or USB + `iproxy`).
3. **Send Files** — pick documents; they stream to `C:\FileDrop\received\` on the PC.
4. **Receive Files** — browse files on the PC and download them to the app’s Documents folder.

Allow **notifications** when asked — you’ll get alerts when transfers finish, even in the background.

---

## Troubleshooting

### “App could not be installed” (Sideloadly)

- A free Apple ID can only sideload a **limited number** of apps (often 3). In Sideloadly, **revoke** an older app or remove one you no longer use, then try again.
- Make sure you downloaded a fresh **FileDrop.ipa** from the latest Actions run.

### “Untrusted Developer”

Go to **Settings → General → VPN & Device Management** and **Trust** your Apple ID.

### App stops opening after ~7 days

Free sideload certificates expire. Connect the phone, open Sideloadly, and install **FileDrop.ipa** again to refresh the signature.

### Status stays on “Searching” or “Disconnected”

- Confirm **`start.bat`** is running on the PC.
- iPhone and PC must be on the **same Wi-Fi** (guest networks often block device-to-device traffic).
- Try **USB + `iproxy 8765 8765`**.
- Allow **FileDrop** to use the **local network** on the iPhone (**Settings → FileDrop → Local Network**).

### mDNS does not find the PC

- Same subnet / no “AP isolation” on the router.
- Use the manual fallback: USB tunnel above, or ensure firewall allows port **8765**.

### Firewall blocking the server

**Windows Security → Firewall → Allow an app** → enable **filedrop-server.exe** on private networks, or add an inbound TCP rule for port **8765**.

### “Connection lost — transfer cancelled”

The WebSocket dropped during a transfer. Tap **Retry** on the banner, ensure the server is still running, and send again.

### “Could not read [filename]”

The file could not be opened from the document picker. Try copying the file to **Files** first, or pick a different copy with read permission.

---

## Developer notes

- **Bundle ID:** `com.local.filedrop`
- **Display name:** FileDrop
- **iOS minimum:** 18.0
- **Server port:** 8765 (WebSocket)
- **mDNS service:** `_filedrop._tcp`

Server details: see [server README](server/) and `npm start` in `package.json` for development builds.
