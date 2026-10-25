# Install Forge from Windows (xtool)

One-time setup is about 45 minutes, most of it downloads. After that, reinstalling takes one command.

## 1. Windows side (one time)

Open **PowerShell as Administrator** and run:

```powershell
wsl --install -d Ubuntu
winget install usbipd
```

Restart the PC. Ubuntu opens; pick a username and password.

Also install **iTunes** (apple.com/itunes or the Microsoft Store). It provides the iPhone USB drivers.

## 2. Download Xcode (one time)

In your browser go to **https://developer.apple.com/download/all/?q=Xcode**, sign in with your Apple ID,
and download **Xcode 27.1** (`.xip`, ~4 GB). Leave it in your Downloads folder.

## 3. Ubuntu side (one time)

Open **Ubuntu** from the Start menu and paste these, one block at a time:

```bash
# Tools
sudo apt-get update && sudo apt-get install -y git curl usbmuxd libimobiledevice-utils libfuse2t64

# Swift (official installer, say yes to the prompts)
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz && ./swiftly init
. ~/.local/share/swiftly/env.sh && hash -r
swift --version

# xtool
curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o xtool
chmod +x xtool && sudo mv xtool /usr/local/bin/
```

Then run:

```bash
xtool setup
```

- Login mode: choose **1 (Password)** and enter your Apple ID, password and 2FA code.
- Path to Xcode.xip: `/mnt/c/Users/<YOUR-WINDOWS-NAME>/Downloads/Xcode_27.1.xip`

## 4. Get the app code (one time)

```bash
cd ~
git clone -b claude/new-session-3zxnei https://github.com/alwaysdragons/testingg.git
cd testingg/ios
```

(If the repo is private, Git asks you to sign in. Use a GitHub personal access token as the password.)

## 5. Connect your iPhone

1. iPhone: **Settings → Privacy & Security → Developer Mode → On** (it restarts). One time only.
2. Plug the iPhone into the PC with USB. Tap **Trust** on the phone.
3. In **PowerShell (Admin)**:
   ```powershell
   usbipd list                          # find "Apple Mobile Device" / iPhone, note its BUSID e.g. 2-3
   usbipd bind --busid 2-3              # first time only
   usbipd attach --wsl --busid 2-3
   ```
4. In **Ubuntu**, check that it sees the phone:
   ```bash
   sudo usbmuxd; ideviceinfo -k DeviceName
   ```

## 6. Install

```bash
cd ~/testingg/ios
xtool dev
```

The first build takes a few minutes. When it finishes, the app is on your phone.

First launch only: iPhone **Settings → General → VPN & Device Management → your Apple ID → Trust**.

## Every 7 days (free Apple ID)

The app stops opening after 7 days. Plug in, run `usbipd attach --wsl --busid 2-3` in PowerShell, then in Ubuntu:

```bash
cd ~/testingg/ios && git pull && xtool dev
```

Your data stays on the phone.

## If something goes wrong

- **"bundle ID not available"**: edit `xtool.yml` and change `bundleID` to something else unique, e.g. `com.raoul2.forge`.
- **`AFCClient.Error.muxError`**: follow https://github.com/xtool-org/xtool/issues/19#issuecomment-2898986718 (connects through iTunes instead of usbipd).
- **AppImage won't start / FUSE error**: run `sudo apt-get install -y libfuse2t64` (older Ubuntu: `libfuse2`).
- **Apple Health shows nothing**: open the iPhone **Health app → Profile → Apps → Forge** and turn everything on.
- **Build errors**: copy the error text and send it to Claude.
