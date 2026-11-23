# macbook_fan — Native macOS Fan Control & Thermal Monitor

**macbook_fan** is a lightweight, native SwiftUI fan control and hardware thermal monitoring utility built specifically for **Apple Silicon Macs (M1 – M5)**, including full support for updated **Apple M5** SMC data types and `IOHID` thermal sensors.

---

## ✨ Features

* **Real-Time AppleSMC & IOHID Monitoring:**
  * Reads live **Fan RPM** (`F0Ac`, `F1Ac`) and hardware limits (`Min` / `Max` RPM).
  * Displays individual **CPU Efficiency & Performance Cores**, **GPU Clusters**, **Battery & Gas Gauge**, **Power Manager**, **Trackpad**, and **NVMe SSD** temperatures.
* **Custom Fan Speed Control:**
  * **Automatic Mode:** Hands control back to macOS `thermalmonitord`.
  * **Constant RPM Mode:** Lock fan speeds to a fixed target RPM.
  * **Sensor-Based Curve:** Dynamically adjusts fan RPM between a start temperature and maximum temperature based on any chosen sensor.
* **Menu Bar Utility:** Quick access to live temperatures and fan speeds directly from the macOS top menu bar.
* **Zero External Dependencies:** Written in pure Swift using native `IOKit` and `IOHIDEventSystem` APIs.

---

## 📥 Installation (via `.dmg`)

1. Download **`MacBookFan-<version>.dmg`** from the [Releases](../../releases) page.
2. Open the `.dmg` file and drag **`MacbookFan.app`** into your **Applications** folder.

### ⚠️ First-Time Launch (Bypassing macOS Gatekeeper)
Because this open-source build is not notarized with a paid Apple Developer account, macOS may display a *"developer cannot be verified"* or *"damaged"* warning on first launch. To allow it:

* **Option A (Terminal - Recommended):**
  Open **Terminal** and run:
  ```bash
  xattr -cr /Applications/MacbookFan.app
  ```
* **Option B (System Settings):**
  Try opening `macbook_fan` once, then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

> **Note on Fan Speed Control:** Changing fan speeds on Apple Silicon Macs needs root privileges. macbook_fan handles this with a small background helper instead of running the whole app as root (macOS hides menu bar items of apps running as root). On first use, click **Enable Fan Control** in the macbook_fan menu, then turn on **macbook_fan** in **System Settings → General → Login Items & Extensions → Allow in the Background**. This is needed only once.
>
> Do **not** run macbook_fan with `sudo` — it will work in the background but disappear from the menu bar.

## 🛠️ Building from Source

### Requirements
* Xcode 16.0+
* Apple Silicon Mac (M1 / M2 / M3 / M4 / M5)

### Build in Xcode
Open `MacBookFan.xcodeproj` and run the `MacbookFan` scheme. **App Sandbox** must stay off (under *Signing & Capabilities*) so `IOKit` can talk to `AppleSMC`.

### Build the installer `.dmg`
```bash
./scripts/build-dmg.sh
```

Builds a fresh Release app from the current source, checks that the fan control helper is inside and the signature is valid, and writes `dist/MacBookFan-<version>.dmg` plus a `.sha256` file. Needs only Xcode. Release steps are in [Notes.md](Notes.md).

---

## 📂 Project Structure

```text
MacBookFan/
├── MacBookFan.xcodeproj
├── MacBookFan-Info.plist       # Extra Info.plist keys (kept outside the source folder)
├── MacBookFan/                 # App source (synced into the target by Xcode)
│   ├── SMCManager.swift        # Low-level AppleSMC (80-byte IOKit) & IOHID sensor reader
│   ├── FanController.swift     # M1-M5 Ftst unlock, manual RPM write & sensor curve logic
│   ├── HelperClient.swift      # App side of the root helper (SMAppService + XPC)
│   ├── HelperDaemon.swift      # Root helper that performs SMC writes
│   ├── FanHelperProtocol.swift # XPC protocol shared by app and helper
│   ├── ContentView.swift       # Details window, fan control card & shared UI pieces
│   ├── MenuBarViews.swift      # macOS status bar UI
│   ├── SingleInstance.swift    # Prevents duplicate app instances
│   ├── macbook_fanApp.swift           # SwiftUI app
│   ├── main.swift              # Entry point (app or --helper)
│   └── Assets.xcassets
├── Helper/
│   └── macbook_fan.helper.plist       # launchd job, copied into Contents/Library/LaunchDaemons
├── Docs/                       # Technical documentation (HTML), logo, icon
├── scripts/
│   └── build-dmg.sh            # Release build + DMG packaging
├── build/                      # Build output (ignored)
├── dist/                       # DMG + SHA-256 (ignored)
├── Notes.md                    # How to publish a GitHub release
└── README.md
```

---

## ⚠️ Disclaimer
Controlling hardware fan speeds overrides macOS default thermal management. Always keep minimum RPM values within safe manufacturer limits and monitor system temperatures under heavy workloads.
