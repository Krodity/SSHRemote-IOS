# SSH Remote for iOS

Turn an iPhone into a remote control, touchpad, keyboard and file browser for
any computer you can reach over SSH. Every button runs a shell command of your
choosing on the computer, so nothing needs to be installed there beyond an SSH
server.

This is an unofficial iOS port of **SSH Remote** for Android by Stefan Sundin
([github.com/stefansundin/SSHRemote](https://github.com/stefansundin/SSHRemote)),
licensed GPL-3.0 like the original. It reads the Android app's settings export,
so an existing setup moves over in one step. It also adds features the Android
app doesn't have: custom pages, a touchpad tile, a fullscreen mode, direct
keyboard typing and a Files tab.

---

## Contents

1. [Features](#features)
2. [Requirements](#requirements)
3. [Building and installing](#building-and-installing)
4. [First run: adding a computer](#first-run-adding-a-computer)
5. [Setting up the computer (Linux input tools)](#setting-up-the-computer-linux-input-tools)
6. [Setting up a Windows computer (OpenSSH + NirCmd)](#setting-up-a-windows-computer-openssh--nircmd)
7. [Setting up a Mac (cliclick)](#setting-up-a-mac-cliclick)
8. [Using the remote](#using-the-remote)
9. [Customising: edit mode, buttons, pages and tabs](#customising-edit-mode-buttons-pages-and-tabs)
10. [The Files tab](#the-files-tab)
11. [Mounting drives over SSH (polkit rule)](#mounting-drives-over-ssh-polkit-rule)
12. [How it works](#how-it-works)
13. [Security notes](#security-notes)
14. [Troubleshooting](#troubleshooting)
15. [Project layout](#project-layout)
16. [License and credits](#license-and-credits)

---

## Features

- **Remote tab:** D-pad, OK, volume, mute, back, home, menu, previous, play/pause and
  next. Each one is an SSH command you choose, with presets for `ydotool`, `wtype`
  and `xdotool`.
- **Mouse tab:** a full touchpad. Drag to move, tap to click, two-finger tap to
  right-click, two fingers to scroll.
- **Keyboard tab:** type text and send it in one go, plus special keys (Esc, Tab,
  arrows, Page Up/Down, F5, F11…).
- **Commands tab:** a list of saved commands, plus a box for one-off commands. The
  output can be shown on the phone.
- **Files tab:** browse the computer's files and play any video, audio or image
  either **on the computer** or **streamed into the app**. It also has a drive
  picker that can mount plugged-in drives.
- **Custom buttons and pages:** add your own buttons to the Remote tab, and create
  as many extra pages as you like. Every button supports tap, long-press, repeat
  while held, and separate press/release commands.
- **Special buttons** you can place anywhere: **Keyboard** (pops up the iPhone
  keyboard and types live on the computer), **Fullscreen**, **Touchpad**
  (full-width) and **Blank spot** (an invisible gap, for lay-out).
- **Layout editing:** drag to reorder, insert before, change a button's type,
  copy and paste buttons, and duplicate any tab into a new page.
- **Tabs:** reorder them, remove the built-in ones (you can add them back later)
  and pick which one opens first.
- **Fullscreen mode:** hides every bar so the whole screen is remote.
- **Authentication:** a per-device Ed25519 key kept in the Keychain, or a
  password, or both. The app can install its own key on the computer for you.
- **Host-key checking** with trust-on-first-use, and a warning if a key changes.
- **Auto-reconnect:** switching apps doesn't drop the remote. If the connection
  did die (a long time in the background, a network change, the computer
  rebooting), it reconnects by itself while the remote is on screen.

---

## Requirements

**Phone:** iPhone running **iOS 17 or later**.

**Computer:** any machine running an **SSH server**. What each feature needs:

| Feature | Needs on the computer |
|---|---|
| Remote, Mouse, Keyboard buttons | Whatever the commands call: on Linux `ydotool` (any session), `wtype` (Wayland) or `xdotool` (X11); on Windows [NirCmd](#setting-up-a-windows-computer-openssh--nircmd); on macOS [cliclick](#setting-up-a-mac-cliclick) |
| Commands tab | Nothing beyond a shell |
| Files: browse, stream into the app | Linux with GNU coreutils + findutils (`find -printf`, `dd iflag=skip_bytes`), which covers every mainstream distribution |
| Files: **Play on PC** | A Linux desktop session with `xdg-open` |
| Files: thumbnails (optional) | `ffmpegthumbnailer` (video), `pdftoppm` from poppler (PDF), ImageMagick `magick`/`convert` (large or unusual images). Without them you get icons. |
| Files: drive picker | `lsblk` (util-linux). Mounting also needs `udisksctl` (udisks2) plus the [polkit rule](#mounting-drives-over-ssh-polkit-rule) |

**Windows** and **macOS** work for buttons, the touchpad, keyboard and commands.
See [Windows (OpenSSH + NirCmd)](#setting-up-a-windows-computer-openssh--nircmd) and
[Mac (cliclick)](#setting-up-a-mac-cliclick). The Files tab currently needs Linux
GNU tools (see [Troubleshooting](#troubleshooting)).

**To build:** [xtool](https://github.com/xtool-org/xtool) on **Linux** or
**macOS**, a Swift 6 toolchain, and a free or paid **Apple ID**.

---

## Building and installing

The project is a Swift Package built and signed with **xtool**, which can build
and install iOS apps from Linux (and macOS) without Xcode's IDE. It only needs
the iOS SDK extracted from `Xcode.xip`.

### 1. Install the toolchain

**Linux**

1. Install **Swift 6.x**. Use the official toolchain from
   [swift.org](https://www.swift.org/install/linux/), or your distribution's
   package (e.g. `swift-bin` on Arch's AUR).
2. Install **usbmuxd**, so the computer can talk to an iPhone over USB. On Arch
   that's `pacman -S usbmuxd`; on Debian/Ubuntu, `apt install usbmuxd`.
3. Install **xtool**. Download the AppImage from its releases page, make it
   executable and put it on your `PATH`, e.g. as `~/.local/bin/xtool`.

**macOS:** install Xcode (or just the Command Line Tools) and xtool
(see xtool's README for its macOS install options), then follow the same steps.

### 2. Set xtool up (one time)

```sh
# Download Xcode.xip from https://developer.apple.com/download/all/ (needs a
# free Apple developer sign-in), then:
xtool setup            # points xtool at Xcode.xip and extracts the iOS SDK
xtool auth login       # signs in with your Apple ID (used for code signing)
xtool sdk status       # should report the SDK as installed
```

### 3. Prepare the iPhone (one time)

1. Connect it with a USB cable, unlock it and tap **Trust This Computer**.
2. Turn on **Settings → Privacy & Security → Developer Mode** and restart when
   asked. The option only appears after the phone has been connected to a
   development tool once, so run step 5 first if you can't see it.

### 4. Choose your bundle ID

Open `xtool.yml` and change `bundleID` from the placeholder to something unique
to you, in reverse-DNS form:

```yaml
bundleID: com.yourname.sshremote
```

Apple rejects IDs that are already taken, and `com.example.*` is not usable for
real signing. The app's Keychain entries follow the bundle ID automatically, so
two builds with different IDs never share keys or passwords.

### 5. Build and install

```sh
./install.sh          # build, sign and install on the connected iPhone
./install.sh build    # build only (checks that it compiles)
```

`install.sh` is a thin wrapper around `xtool dev`. It fixes up `PATH` so the
build finds Swift's helper tools (see [Troubleshooting](#troubleshooting)).

The first install then needs two taps on the phone:

- **Settings → General → VPN & Device Management → *your Apple ID* → Trust.**
- Open **SSH Remote**. On first connection iOS asks for **Local Network** access;
  allow it, or computers on your LAN can't be reached.

### Free Apple ID limits

With a free (non-paid) Apple ID:

- The installed app **expires after 7 days**. Run `./install.sh` again to
  refresh it; your hosts and settings are kept.
- You can have at most **3 sideloaded apps** at a time.
- The first install may ask to **revoke an existing development certificate**.
  That's normal for free accounts. Answer yes if you don't use that certificate
  elsewhere.

A paid developer account raises these limits to one year and more apps.

---

## First run: adding a computer

1. Tap **+** on the host list and fill in:
   - **Name** (optional): what the list shows.
   - **Hostname or IP**, **Port** (default 22) and **User**.
   - **Use this device's key** (on by default) and/or a **Password**.
2. New hosts start with the **ydotool** command preset, so the remote works on any
   Linux session once ydotool is running. Pick another preset under **Remote
   commands → Presets**, or edit any command yourself.
3. Tap **Save**, then tap the host to connect.
4. The first connection shows the computer's **host-key fingerprint**. Check it
   against the server, e.g. `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`,
   then tap **Trust**. A *changed* key later shows a warning instead: someone may
   be impersonating the computer, or it was reinstalled.

### Logging in with the device key (recommended)

The app generates its own **Ed25519 key** the first time it needs one. The key is
kept in the iOS Keychain as *this device only*, so it is never synced or backed
up. To let it log in:

- **Easiest:** save the host with a password once, connect, then choose
  **⋯ → Install key on host**. The app appends its public key to
  `~/.ssh/authorized_keys` (only if it isn't already there). After that you can
  remove the password.
- **Manual:** on the host list choose **⋯ → This device's SSH key**, copy or share
  the line, and add it to `~/.ssh/authorized_keys` on the computer.

The key is tried first, then the password. Passwords are stored in the Keychain,
one per host, and never leave the phone except to log in.

### Importing from the Android app

On Android use **Settings → Export**. Then on iOS, from the host list's **⋯**:

- **Import settings file:** the exported JSON file, e.g. via Files or AirDrop.
- **Paste settings:** the JSON, or Android's compact export string (base64 of
  gzip).

Hosts, remote commands, custom buttons, custom pages and known host keys are all
imported. Passwords and SSH keys are not imported, so set up authentication
again on the phone (see above).

---

## Setting up the computer (Linux input tools)

Buttons only run commands, so the computer needs something that can inject key
presses and mouse movement. The three presets:

| Preset | Works on | Notes |
|---|---|---|
| **ydotool** | Any session: Wayland, X11, even a text console | Needs the `ydotoold` daemon running and permission to use `/dev/uinput`. Commands use Linux key codes (`ydotool key 28:1 28:0` = Enter). |
| **wtype** | Wayland only | No daemon. Some compositors restrict virtual keyboards; there's no mouse support. |
| **xdotool** | X11 only | The preset prefixes `DISPLAY=:0`, because an SSH session has no display. |

For ydotool, a typical setup on a systemd distribution is to run `ydotoold` as a
user service and make sure your user can write to `/dev/uinput`. Distributions
package this differently, so check yours. If buttons do nothing, run the same
command in an SSH shell yourself: an error there is the whole story.

### Placeholders in commands

| Placeholder | Used by | Replaced with |
|---|---|---|
| `%s` | *Type text*, *Key press*, custom Keyboard tab keys | The typed text, single quotes escaped for use inside `'…'`; or a key's X keysym name (wtype/xdotool) |
| `%d` | *Key press*, *Key down/up* | The key's Linux input code (ydotool) |
| `%dx`, `%dy` | *Mouse move* | The horizontal and vertical movement in pixels |

---

## Setting up a Windows computer (OpenSSH + NirCmd)

Windows needs two things: the **OpenSSH server** built into Windows, so the app
can log in, and **[NirCmd](https://www.nirsoft.net/utils/nircmd.html)**, a free
command-line tool from NirSoft that does ydotool's job there: key presses, mouse
movement, clicks, scrolling and volume.

What works on Windows:

| Works | Doesn't work |
|---|---|
| Remote tab, custom buttons and pages, Mouse tab and Touchpad tiles, volume/media keys, Keyboard tab keys, typing text, Commands tab | **Files tab** (it relies on Linux tools), **Install key on host** (it runs Linux shell commands), horizontal scrolling |

Expect a little more delay than on Linux: each press passes through the Windows
Task Scheduler (see step 4), which adds roughly a tenth to a few tenths of a second.

### 1. Install and start the OpenSSH server

Open **PowerShell as Administrator** (right-click Start → Terminal (Admin)) and run:

```powershell
# Install the server (the client is usually already installed)
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

# Start it now and at every boot
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Installation normally creates this firewall rule; check it's there and enabled
Get-NetFirewallRule -Name *OpenSSH-Server* | Select-Object Name, Enabled
```

You can also use **Settings → System → Optional features → View features → "OpenSSH
Server"**, then start the **OpenSSH SSH Server** service in *Services*.

Find the PC's address with `ipconfig`, then add it in the app with your **Windows
user name**. For a Microsoft account, that's the short name of the user folder
under `C:\Users`. The password is your Windows account password; a Windows Hello
PIN won't work.

The default remote shell is **cmd.exe**. All the commands below are written for it.

### 2. Log in with the app's key (optional, recommended)

**Install key on host** doesn't work on Windows, so add the key by hand. On the
host list, open **⋯ → This device's SSH key** and copy the line. Where it goes depends
on your account type:

- **Standard user:** `C:\Users\<you>\.ssh\authorized_keys` (create the `.ssh`
  folder if needed; one key per line).
- **Administrator account:** Windows ignores the file above. Put the line in
  `C:\ProgramData\ssh\administrators_authorized_keys` instead, then lock the file
  down, or sshd refuses to use it. In an elevated PowerShell:

  ```powershell
  icacls.exe "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
  ```

### 3. Install NirCmd

1. Download NirCmd (64-bit) from
   [nirsoft.net/utils/nircmd.html](https://www.nirsoft.net/utils/nircmd.html) and
   extract the zip.
2. Run `nircmd.exe` once and click **Copy To Windows Directory** (it asks for
   administrator rights). That puts it at `C:\Windows\nircmd.exe`, so plain `nircmd`
   works from any command.

### 4. Route commands to your desktop

**Why this step exists.** The Windows SSH server is a background service. Commands
you run over SSH execute in the SSH login's own session, **not in the desktop
session you're looking at**. Anything that sends keys or clicks from there lands on
an invisible desktop and does nothing. The same limit stops you starting a visible
program over SSH.

**The fix:** a scheduled task set to run **in your desktop session**
(*"run only when the user is logged on"*). Buttons append their command to a
queue file and start the task; the task runs everything in the queue, on your
screen. Nothing runs at a higher privilege than your own account.

1. Create a folder `C:\SSHRemote` containing these three files.

   **`C:\SSHRemote\send.cmd`** is what buttons call. It queues a command and starts
   the task:

   ```bat
   @echo off
   >> "%~dp0queue.txt" echo %*
   schtasks /run /tn "SSHRemote" >nul
   ```

   **`C:\SSHRemote\run.cmd`** is run by the task in your desktop session. It works
   through the queue until the queue is empty:

   ```bat
   @echo off
   cd /d "%~dp0"
   :loop
   if not exist queue.txt exit /b
   move /y queue.txt work.txt >nul 2>&1 || (ping -n 1 127.0.0.1 >nul & goto loop)
   for /f "usebackq delims=" %%C in ("work.txt") do %%C
   del work.txt
   goto loop
   ```

   **`C:\SSHRemote\key.cmd`** turns the key names the app sends (e.g. `Escape`,
   `Return`, `Prior`) into NirCmd's names, for the Keyboard tab and the live
   keyboard:

   ```bat
   @echo off
   set "k=%~1"
   if /i "%k%"=="Escape"    set "k=esc"
   if /i "%k%"=="Return"    set "k=enter"
   if /i "%k%"=="BackSpace" set "k=backspace"
   if /i "%k%"=="space"     set "k=spc"
   if /i "%k%"=="Prior"     set "k=pageup"
   if /i "%k%"=="Next"      set "k=pagedown"
   call "%~dp0send.cmd" nircmd sendkey %k% press
   ```

2. Register the task. Run this in **normal (non-admin) PowerShell, while logged in
   at the PC as the user the app logs in as**:

   ```powershell
   $action    = New-ScheduledTaskAction -Execute "C:\Windows\nircmd.exe" -Argument 'exec hide "C:\SSHRemote\run.cmd"'
   $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
   $settings  = New-ScheduledTaskSettingsSet -MultipleInstances Parallel -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
   Register-ScheduledTask -TaskName "SSHRemote" -Action $action -Principal $principal -Settings $settings -Force
   ```

   - `nircmd exec hide` runs the queue without flashing a console window.
   - `-LogonType Interactive` is what puts it in your desktop session.
   - `Parallel` means a press that arrives while the task is busy isn't dropped.

3. Test it from the app's **Commands** tab:
   `C:\SSHRemote\send.cmd nircmd sendkey down press`. The Down arrow should reach
   whatever window is focused on the PC.

Someone must be logged in at the PC (a locked screen is fine; being signed out isn't).

### 5. Enter the commands

Enter these under **⋯ → Edit host & commands → Remote commands**. The built-in
presets are Linux-only.

| Button / action | Command | Repeat while held |
|---|---|---|
| Up / Down / Left / Right | `C:\SSHRemote\send.cmd nircmd sendkey up press` (`down`, `left`, `right`) | ✓ |
| Select (OK) | `C:\SSHRemote\send.cmd nircmd sendkey enter press` | |
| Volume down / up | `C:\SSHRemote\send.cmd nircmd changesysvolume -2000` / `2000` | ✓ |
| Mute (toggle) | `C:\SSHRemote\send.cmd nircmd mutesysvolume 2` | |
| Back | `C:\SSHRemote\send.cmd nircmd sendkeypress alt+left` | |
| Home | `C:\SSHRemote\send.cmd nircmd sendkey home press` | |
| Menu | `C:\SSHRemote\send.cmd nircmd sendkey apps press` | |
| Previous / Play-Pause / Next | `C:\SSHRemote\send.cmd nircmd sendkeypress 0xB1` / `0xB3` / `0xB0` (media-key codes) | |
| Mouse move | `C:\SSHRemote\send.cmd nircmd sendmouse move %dx %dy` | |
| Left click / Right click | `C:\SSHRemote\send.cmd nircmd sendmouse left click` / `right click` | |
| Left down / up, Right down / up | `C:\SSHRemote\send.cmd nircmd sendmouse left down` (`left up`, `right down`, `right up`) | |
| Scroll up / down | `C:\SSHRemote\send.cmd nircmd sendmouse wheel 120` / `-120` | |
| Key press (`%s`) | `C:\SSHRemote\key.cmd %s` | |
| Type text (`%s`) | see below | |

Custom buttons work the same way. Anything NirCmd can do goes after
`C:\SSHRemote\send.cmd`, e.g. `nircmd sendkeypress ctrl+shift+esc` (Task
Manager) or `nircmd monitor off`. For a **press & release** button, use
`nircmd sendkey <key> down` as *On press* and `nircmd sendkey <key> up` as *On
release*. Key names: `a`–`z`, `0`–`9`, `F1`–`F24`, `enter`, `esc`, `tab`,
`backspace`, `delete`, `home`, `end`, `pageup`, `pagedown`, `up`/`down`/`left`/`right`,
`shift`, `ctrl`, `alt`, `lwin`, `apps`, `spc`, or any virtual-key code such as
`0xB3` (full list in the
[sendkey reference](https://www.nirsoft.net/nircmd/sendkey.html)).

**Typing text.** NirCmd can't type a string, so *Type text* uses Windows'
`SendKeys` through PowerShell:

```
C:\SSHRemote\send.cmd powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait('%s')"
```

This types letters, numbers, spaces and most punctuation, but has limits:

- An apostrophe (`'`) breaks the command, because the app escapes it for Linux
  shells.
- `SendKeys` treats `+ ^ % ~ ( ) { } [ ]` as special keys.
- `cmd.exe` mangles `% & | < > ^`.
- Each chunk starts PowerShell, so the live-typing Keyboard button is noticeably
  slower than on Linux.

For heavy typing, send text in larger chunks from the Keyboard tab, or install
[AutoHotkey](https://www.autohotkey.com/) and call a script of your own from
`send.cmd`.

---

## Setting up a Mac (cliclick)

macOS has everything except the input tool. **[cliclick](https://github.com/BlueM/cliclick)**
is a free command-line tool that moves the mouse, clicks, types and presses keys,
including the volume and media keys.

What works on macOS:

| Works | Doesn't work |
|---|---|
| Remote tab, custom buttons and pages, Mouse tab and Touchpad tiles (move and click), volume/media keys, Keyboard tab, typing text, Commands tab, Install key on host | **Scrolling** (cliclick has no scroll wheel), **Files tab** (it expects GNU `find`/`dd`, and `xdg-open` rather than `open`) |

### 1. Turn on Remote Login

**System Settings → General → Sharing → Remote Login** → on. Note the address it
shows (e.g. `you@your-mac.local`), and add that host and user name in the app.
**Install key on host** works on a Mac.

### 2. Install cliclick

With [Homebrew](https://brew.sh):

```sh
brew install cliclick
```

SSH commands don't read your shell's login profile, so Homebrew's folder isn't on
`PATH` there. **Always use the full path:** `/opt/homebrew/bin/cliclick` on Apple
Silicon Macs, `/usr/local/bin/cliclick` on Intel Macs. `which cliclick` in Terminal
shows which. The tables below use the Apple Silicon path.

### 3. Allow SSH to control the Mac (Accessibility)

macOS blocks synthetic input from any program that lacks Accessibility permission.
Without it, cliclick runs over SSH without error but nothing happens on screen.

1. **System Settings → Privacy & Security → Accessibility → +**.
2. In the file picker press **⌘⇧G**, enter `/usr/libexec/sshd-keygen-wrapper`, add it
   and switch it on. That's the program macOS runs SSH sessions under.
3. Reconnect in the app (⋯ → Reconnect), so a fresh SSH session picks up the
   permission.

Someone must be logged in to the Mac's desktop.

### 4. A helper for key names

The Keyboard tab and the live keyboard send key names like `Escape`, `Return` and
`Prior`. Save this on the Mac as `~/bin/sshremote-key`, then run
`chmod +x ~/bin/sshremote-key`:

```sh
#!/bin/sh
# Translate the app's key names into cliclick's, then press the key.
case "$1" in
  Escape) k=esc ;;          Return) k=return ;;     Tab) k=tab ;;
  BackSpace) k=delete ;;    Delete) k=fwd-delete ;; space) k=space ;;
  Home) k=home ;;           End) k=end ;;
  Prior) k=page-up ;;       Next) k=page-down ;;
  Left) k=arrow-left ;;     Right) k=arrow-right ;;
  Up) k=arrow-up ;;         Down) k=arrow-down ;;
  F[0-9]*) k=$(echo "$1" | tr 'F' 'f') ;;
  *) k=$1 ;;
esac
exec /opt/homebrew/bin/cliclick "kp:$k"
```

### 5. Enter the commands

| Button / action | Command | Repeat while held |
|---|---|---|
| Up / Down / Left / Right | `/opt/homebrew/bin/cliclick kp:arrow-up` (`arrow-down`, `arrow-left`, `arrow-right`) | ✓ |
| Select (OK) | `/opt/homebrew/bin/cliclick kp:return` | |
| Volume down / up | `/opt/homebrew/bin/cliclick kp:volume-down` / `kp:volume-up` | ✓ |
| Mute | `/opt/homebrew/bin/cliclick kp:mute` | |
| Back | `/opt/homebrew/bin/cliclick kd:cmd t:[ ku:cmd` (⌘[, back in browsers and Finder) | |
| Home | `/opt/homebrew/bin/cliclick kp:home` | |
| Previous / Play-Pause / Next | `/opt/homebrew/bin/cliclick kp:play-previous` / `kp:play-pause` / `kp:play-next` | |
| Mouse move | `/opt/homebrew/bin/cliclick "m:$(printf %+d %dx),$(printf %+d %dy)"` | |
| Left click / Right click | `/opt/homebrew/bin/cliclick c:.` / `rc:.` (`.` = where the pointer is) | |
| Left down / up | `/opt/homebrew/bin/cliclick dd:.` / `du:.` | |
| Key press (`%s`) | `~/bin/sshremote-key %s` | |
| Type text (`%s`) | `/opt/homebrew/bin/cliclick t:'%s'` | |

Notes:

- **Mouse move:** cliclick treats a coordinate as *relative* only when it has a
  leading `+` or `-`. `printf %+d` adds that sign to the app's `%dx`/`%dy` values,
  so `-5` stays `-5` and `5` becomes `+5`.
- **Typing:** the app escapes quotes for single-quoted shell strings, which is
  exactly what `t:'%s'` needs, so apostrophes type correctly on a Mac.
- **Any other key:** `cliclick kp:<key>`, and hold modifiers with
  `kd:cmd,shift … ku:cmd,shift`. Run `cliclick -h` for every key name,
  including `brightness-up`/`-down`.
- **Alternative without cliclick:** keystrokes and volume also work through the
  built-in AppleScript, e.g.
  `osascript -e 'tell application "System Events" to keystroke "hello"'` or
  `osascript -e 'set volume output volume 50'`. The same Accessibility
  permission is needed.

---

## Using the remote

Tap a host to open its remote. The top area shows:

- **Connection status**, with a **Connect** button if it dropped.
- The **tab bar**: Remote, Mouse, Keyboard, Commands, Files, then your own pages.
- **⤢** fullscreen, **Edit**, and **⋯** (add page, arrange tabs, keyboard, edit host,
  install key, reconnect).

### Buttons: tap, hold, repeat, press/release

Every button, built-in or custom, behaves like a real key:

- **Tap** runs its command.
- **Long-press command** (optional) runs instead when held for half a second.
- **Repeat while held** fires once, pauses, then repeats steadily until you let go.
  This suits volume and arrows.
- **Press & release** replaces tap: *On press* runs when your finger goes down and
  *On release* when it comes up, for holding a key or mouse button down
  (e.g. `ydotool key 42:1` / `ydotool key 42:0` for Shift).
- **Show output** opens the command's output (stdout, stderr tagged, exit status)
  in a sheet.

Swiping that starts on a button **scrolls the page** and doesn't press the
button. Only a real tap or hold does.

Buttons with no command assigned are drawn **transparent**, with only a faint
icon, so an unused slot doesn't clutter the remote.

### Mouse tab

Drag to move, tap to left-click, two-finger tap to right-click, and drag with two
fingers to scroll. The slider sets pointer speed (shared with every Touchpad tile).
Movements are merged while a command is in flight, so a slow link lags slightly
instead of queueing seconds of movement.

### Keyboard tab

Type into the box and tap send: the whole text goes over in one *Type text*
command. iOS "smart" punctuation (curly quotes, long dashes, …) is turned back
into plain ASCII first. The keys below the box send single special keys.

### Keyboard button (live typing)

A **Keyboard** button, which you can place on any page, pops up the iPhone keyboard
with **no text box**. Every keystroke goes straight to the computer:

- Letters and symbols are sent as you type. Anything typed while the previous
  keystroke is still in flight is merged, and **order is always preserved**.
- ⌫ sends BackSpace and Return sends Enter.
- A bar above the keyboard has **Esc, Tab, ←, ↑, ↓, →** and a button to hide the
  keyboard.
- Autocorrect, auto-capitalisation, smart quotes and smart dashes are all off.

### Commands tab

A saved list of commands. Tap to run; in edit mode, tap to edit, swipe to delete
and drag to reorder. The box at the top runs a one-off command and shows its
output.

### Fullscreen

Tap **⤢** in the top bar, or a **Fullscreen** button on a page. The navigation
bar, status line, tab bar and iOS status bar all disappear. Two small controls
stay in the top-right corner, beside the camera cut-out:

- **⋯:** switch tabs, show the keyboard, toggle edit mode.
- **⤡:** leave fullscreen.

---

## Customising: edit mode, buttons, pages and tabs

Tap **Edit** to enter edit mode. Buttons get a dashed outline and a **+** tile
appears at the end of each grid. **Outside edit mode, holding a button is just
holding a key.** No menus pop up.

### Adding buttons

The **+** tile offers:

| Type | What it is |
|---|---|
| **Command button** | A normal button: label, tap / long-press / repeat / press-release commands |
| **Keyboard** | Pops up the iPhone keyboard for [live typing](#keyboard-button-live-typing) |
| **Fullscreen** | Toggles [fullscreen](#fullscreen) |
| **Touchpad** | A full-width trackpad (Small / Medium / Large / Extra large), same gestures as the Mouse tab |
| **Blank spot** | An invisible gap that holds one grid slot; shown as a faint dashed box only in edit mode |
| **Paste** | Appears when you have copied a button |

Buttons sit **three to a row**. A Touchpad always takes a whole row of its own.

### Arranging buttons

In edit mode:

- **Tap** a button to edit it. For special buttons this offers resize (touchpad),
  change type and delete.
- **Hold and drag** a button to move it. The others shift into the gap live as it
  passes over them.
- **Long-press** (without moving) for the menu:
  - **Edit / Options**
  - **Copy**, **Paste before**, **Paste after**. The copied button can be pasted on
    another page or even another host, until the app is closed.
  - **Move left / Move right**
  - **Insert before ▸**: any button type, placed right before this one.
  - **Change type ▸**: turn this slot into another type, e.g. a blank spot into a
    command button. Changing to a command button opens the editor, and the old
    button stays until you tap Save.
  - **Delete**

The built-in D-pad and media keys on the Remote tab keep their positions; tap
them in edit mode to change their commands. To lay those out freely too,
[duplicate the Remote tab](#tabs-and-pages) into a page.

### Tabs and pages

- **⋯ → Add page** creates a new, empty page tab. Fill it with **+**.
- **Long-press a tab** for:
  - **Arrange tabs…**: drag to reorder, swipe to remove.
  - **Rename page** (your own pages).
  - **Remove tab** (built-in tabs are only hidden) or **Delete page** (your own
    pages are deleted along with their buttons).
  - **Duplicate as new page** (edit mode only): copies the tab into a new page
    right after it. A built-in tab becomes an ordinary page you can rearrange:
    - *Remote* → D-pad (with blank spots keeping its shape), media keys and your
      custom buttons.
    - *Mouse* → a touchpad plus Left and Right click buttons.
    - *Keyboard* → a Keyboard button plus every special key.
    - *Commands* → one button per saved command.
- **Adding hidden tabs back:** **⋯ → Edit host & commands → Tabs**. Every removed
  built-in tab has an **Add back** row there, plus the full Arrange tabs screen.
- The last visible tab can't be removed.

---

## The Files tab

Browse the computer's files and open them **on the computer** or **on the
phone**. Nothing is installed on the computer: every action is an ordinary shell
command over the same SSH connection.

### The toolbar

| Control | Does |
|---|---|
| ↑ | Up one folder |
| ☆ | Places: Home, Downloads, Videos, Music, Pictures, Desktop, Root |
| Drive icon | [Drive picker](#drives) |
| ↻ | Refresh (or pull down on the list) |
| **Play on PC / Play in app** | What tapping a file does; tap the pill to switch |
| ⋯ | List/grid view, show/hide dotfiles |

The bar below is the current path; tap any part of it to jump there. The app
remembers the last folder for each host.

### Tapping a file

**Play on PC** opens the file with the computer's default application: a video
in its video player, a PDF in its viewer, a folder in its file manager.

**Play in app:**

| File | Opens as |
|---|---|
| Video / audio (MP4, M4V, MOV, 3GP, MP3, M4A, AAC, FLAC, WAV, AIFF, ALAC, CAF) | The iOS player, **streamed**, with seeking. Nothing is downloaded first. |
| Other video (MKV, WebM, AVI, …) | iOS can't decode these, so you're offered **Play on PC** or **Download & open with…**, e.g. to VLC |
| Images | A full-screen viewer: swipe through the folder, pinch or double-tap to zoom, and a button to show the current image on the PC |
| Text files | A read-only viewer (first 2 MB) |
| PDF and everything else | Downloaded, then shown in Quick Look |

**Long-press a file** for: Play on PC, Play in app, **Open with… / Save** (download,
then the iOS share sheet: save to Files, send to another app, AirDrop…) and
**Copy path**.

### Drives

The drive icon lists **every connected drive with a filesystem**: label, size,
filesystem type and where it's mounted. Swap, encrypted (LUKS) containers,
RAID/LVM members and boot/EFI partitions are left out.

- **Mounted** drives open straight away.
- **Connected, not mounted** drives (a freshly plugged-in USB stick, say) are
  mounted with `udisksctl mount`, exactly as a desktop file manager does it, under
  `/run/media/<user>/<label>`, and then opened. **Mounting never formats or
  changes a drive.**

Mounting over SSH is refused by default on most distributions; see the next
section.

---

## Mounting drives over SSH (polkit rule)

**The symptom:** tapping an unmounted drive shows *"Not allowed to mount … over
SSH (polkit)"*.

**Why it happens:** udisks asks polkit for permission. A user sitting at the
desktop is in an **active** local session and may mount removable drives freely.
An SSH login is an **inactive, other-seat** session, so polkit's default answer
is `auth_admin` (an administrator password). The app can't answer a password
prompt, so the mount is refused.

**The fix:** a small polkit rule that lets **your user only** mount and unmount
drives through udisks, from any session. It grants nothing else: no formatting,
no partition editing, and no mounting of internal system disks.

1. Create `/etc/polkit-1/rules.d/50-udisks-mount-over-ssh.rules` as root, and
   replace `YOUR_USERNAME` with the account the app logs in as:

   ```javascript
   // Let one user mount/unmount removable drives via udisks from an SSH
   // session. Mount/unmount only: no format, modify or internal-disk rights.
   polkit.addRule(function(action, subject) {
       if (subject.user == "YOUR_USERNAME" &&
           (action.id == "org.freedesktop.udisks2.filesystem-mount" ||
            action.id == "org.freedesktop.udisks2.filesystem-mount-other-seat" ||
            action.id == "org.freedesktop.udisks2.filesystem-unmount-others")) {
           return polkit.Result.YES;
       }
   });
   ```

   For example:

   ```sh
   sudo nano /etc/polkit-1/rules.d/50-udisks-mount-over-ssh.rules
   sudo chmod 644 /etc/polkit-1/rules.d/50-udisks-mount-over-ssh.rules
   ```

2. polkit reloads rules automatically; no restart is needed. Check it, as the
   same user:

   ```sh
   pkcheck --action-id org.freedesktop.udisks2.filesystem-mount-other-seat --process $$ && echo allowed
   ```

   This prints `allowed` once the rule is in place.

3. Tap the drive in the app again.

**Variations:**

- **Several users:** use `subject.isInGroup("somegroup")` instead of
  `subject.user == "…"`, and put those users in that group.
- **Internal (non-removable) drives:** these use a separate action,
  `org.freedesktop.udisks2.filesystem-mount-system`. It's deliberately left out
  above. Add it only if you want the phone to be able to mount internal disks too.
- **To undo:** delete the file.

On older distributions still using polkit < 0.106 (`.pkla` files) the syntax is
different; any distribution from the last several years uses the JavaScript
rules shown here.

---

## How it works

### SSH

- The app uses **apple/swift-nio-ssh** directly. Each host keeps **one SSH
  connection** open once connected, and every button press opens a
  short-lived **exec channel** on that connection. That's why presses are fast:
  there's no new login per command.
- **Auto-reconnect.** While a host's remote screen is open, the app keeps that
  host connected:
  - **Switching apps** (multitasking) leaves the connection open, so after a quick
    switch the remote just keeps working with no reconnect.
  - **Coming back to the app**, it sends a no-op command (`true`) to each open
    remote's host. If there's no answer within 3 seconds, because iOS suspended the
    app long enough for the socket to die, the connection is replaced at once.
  - **The connection closing** at any other time (server restart, Wi-Fi drop)
    triggers a reconnect straight away.
  - **Network changes** (Wi-Fi ↔ cellular, VPN up/down, signal back) are watched
    with `NWPathMonitor`, and each open host's connection is re-checked the same
    way.
  - **Failed attempts** are retried after 1, 2, 4, 8 and 16 seconds, then every 30
    seconds. The status line shows the error and the next retry time.
  - It **stops** when you leave the remote screen, and **doesn't retry** failures a
    retry can't fix: a rejected host key or bad credentials. Tap **Connect** after
    fixing them.
  - Separately, a command that hits a dead connection reconnects and retries once.
- Authentication tries the device's Ed25519 key first, then the password.
  Host keys are checked against the host's trusted keys (trust on first use, with
  a warning on change).

### Input

- Buttons are real SwiftUI buttons with a custom style that reports press and
  release. That's what gives tap, long-press, repeat and press/release behaviour
  while still letting a swipe scroll the page.
- **Live keyboard:** an invisible view becomes the first responder (`UIKeyInput`).
  Keystrokes go into a **serial queue**, so they're sent strictly in order;
  anything typed while a command is in flight is merged into the next *Type text*
  command.
- **Touchpad:** the touches are handled by a gesture recognizer that claims the
  touch as soon as a finger lands. Inside a scrolling page, the page's own scroll
  gesture waits for it, so dragging on the pad moves the pointer rather than the
  page. Moves are merged while a mouse-move command is in flight.

### Files

No agent: everything is a shell command.

| Action | Command (simplified) |
|---|---|
| List a folder | `cd -- DIR; pwd; find -L . -mindepth 1 -maxdepth 1 -printf '%y\t%s\t%T@\t%f\0'`. NUL-separated, so any filename survives. |
| Play on PC | `setsid -f xdg-open FILE`, after rebuilding the desktop environment variables (below) |
| Stream a range | `dd if=FILE bs=1M iflag=skip_bytes,count_bytes skip=OFFSET count=LENGTH status=none` |
| Thumbnails | `ffmpegthumbnailer -o -`, `pdftoppm -jpeg`, `magick … jpg:-`, all writing to stdout |
| Drives | `lsblk -Pno PATH,LABEL,SIZE,FSTYPE,MOUNTPOINTS,RM,HOTPLUG` |
| Mount | `udisksctl mount --no-user-interaction -b DEVICE` |

- **Play on PC and the desktop session:** an SSH login doesn't know about the
  graphical session, so a bare `xdg-open` couldn't reach the screen. Before
  opening, the app sets `XDG_RUNTIME_DIR` (`/run/user/<uid>`), finds the Wayland
  socket there (`wayland-N`), and sets `DISPLAY=:0` and the session D-Bus
  address. It then starts the opener detached with `setsid -f`, so the player keeps
  running after the SSH command ends.
- **Streaming:** the player is given a made-up `sshfile://` URL. iOS can't fetch
  that itself, so it asks the app's **resource loader** for byte ranges, and the app
  answers each range with a `dd` over SSH: 1 MiB per command, two in flight.
  Seeking just asks for a different range. Nothing is written to the phone.
- **Downloads** (Quick Look, Open with…) go to the app's Caches folder in 4 MiB
  pieces, so large files never sit in memory.
- **Concurrency:** OpenSSH allows 10 channels per connection by default
  (`MaxSessions`). File operations are capped at 6 at a time, so a grid of
  thumbnails or a playing video never starves the remote's buttons.

**Why not SFTP?** SFTP would work on more systems (macOS and Windows OpenSSH
ship it). But swift-nio-ssh has no SFTP client, and plain commands needed no
extra protocol code. The listing and reading code is kept in one place
(`FilesModel.load` and `FilesModel.read` in `Files.swift`), so an SFTP back end
can replace it later.

### Storage

| What | Where |
|---|---|
| Hosts, commands, buttons, pages, tab order, trusted host keys | `hosts.json` in the app's Application Support folder, with iOS file protection |
| Passwords (one per host) and the device private key | iOS Keychain, *this device only*, available after first unlock; not synced or backed up |
| Small preferences (mouse speed, Files view mode, last folder per host) | `UserDefaults` |
| Downloaded files | The app's Caches folder (iOS may clear it) |

New fields (`tabOrder`, `hiddenTabs`, `action`, `padHeight`) are optional, so
settings stay compatible with the Android app's export format.

---

## Security notes

- **Buttons run commands as your user** on the computer, and anyone holding the
  unlocked phone can press them. Use a dedicated account if that matters to you.
- The `%s` escaping exists to keep typed text intact inside single quotes. It is
  **not a sandbox**; don't point buttons at commands you wouldn't run by hand.
- Prefer **key authentication** and remove the password once the key is
  installed.
- **Verify the host-key fingerprint** on first connect, and take the changed-key
  warning seriously.
- Keep SSH off the open internet: use your LAN or a VPN (e.g. WireGuard or
  Tailscale) to reach the computer from elsewhere.
- The polkit rule above grants **only** mount/unmount, **only** to the user you
  name.

---

## Troubleshooting

**Build fails with `swift-autolink-extract` not found, or plugin/host-tool errors.**
The Swift toolchain's own `bin` directory must come first on `PATH`.
`install.sh` does this automatically. If you run `xtool dev` by hand, prepend
it yourself, e.g. `export PATH="$(dirname "$(readlink -f "$(command -v swift)")"):$PATH"`.

**Build fails with "requires a package name" / `package` access-level errors.**
Some newer versions of swift-nio and swift-collections use Swift's `package`
access level, which xtool's build doesn't support yet. `Package.swift` pins
**swift-nio 2.83.0** and **swift-collections 1.2.1** for this reason. Don't bump
them until the build supports it.

**Build fails in the SDK's `arm_neon.h` (`bit_cast` errors) on Linux.**
A known xtool issue (#273): the SDK can end up with your system clang's headers
instead of the toolchain's. Copy your Swift toolchain's
`lib/clang/<version>/include` over the SDK's
`…/XcodeDefault.xctoolchain/usr/lib/clang/<version>/include`, or update xtool to
a release that includes the fix.

**Install fails with 409 "no current iOS devices on this team".**
Device registration takes a moment to propagate. Just run `./install.sh` again.

**App won't open ("Untrusted Developer").**
Settings → General → VPN & Device Management → trust your Apple ID.

**App stopped opening after a week.** Free-account builds expire after 7 days;
reinstall with `./install.sh`.

**Status says "… — retrying in 30s".** Auto-reconnect is waiting between
attempts. Tap **Connect** to try immediately, or check that the computer is
reachable (same network or VPN, SSH server running).

**Status says "Authentication failed" and nothing retries.** Bad credentials aren't
retried automatically. Fix the key or password under **⋯ → Edit host & commands**,
then tap **Connect**.

**Can't connect on the local network.** Allow **Local Network** for SSH Remote
in iOS Settings → Privacy & Security → Local Network.

**Buttons do nothing.** Open the Commands tab and run the same command with
output shown. For ydotool, check that `ydotoold` is running and can open
`/dev/uinput`. For xdotool, check `DISPLAY`. wtype only works on Wayland.

**"Set a Type text / Key press command for this host."** The Keyboard features
use the host's *Type text* and *Key press* commands. Set them under **⋯ → Edit
host & commands**, or apply a preset.

**Files: "Play on PC" does nothing.** Someone must be logged in to a graphical
session on the computer, and `xdg-open` must be installed. The app finds a Wayland
socket in `/run/user/<uid>` or falls back to X11 `:0`.

**Windows: commands succeed but nothing happens on screen.** They're running in
the SSH session's hidden desktop. Route them through the scheduled task
([Windows step 4](#4-route-commands-to-your-desktop)). Check that the `SSHRemote`
task exists (`schtasks /query /tn SSHRemote`) and that someone is logged in at the
PC.

**Windows: "Permission denied (publickey)" with the key installed.** On an
administrator account the key must be in
`C:\ProgramData\ssh\administrators_authorized_keys`, with the `icacls`
permissions from [Windows step 2](#2-log-in-with-the-apps-key-optional-recommended).

**Mac: cliclick runs but nothing moves or types.** Accessibility isn't granted to
`/usr/libexec/sshd-keygen-wrapper` ([Mac step 3](#3-allow-ssh-to-control-the-mac-accessibility)).
Reconnect after granting it. "command not found" means the full Homebrew path is
missing.

**Files: the listing fails on macOS / BusyBox / Windows.** The Files tab uses GNU
`find -printf` and `dd iflag=skip_bytes,count_bytes`. On macOS you can install
GNU tools (`brew install findutils coreutils`), but they're named `gfind`/`gdd`,
so the commands in `Files.swift` would need adjusting. Windows isn't supported.

**Files: a video shows a black screen or offers "Play on PC".** The container
isn't one iOS can play (MKV, WebM, AVI…). Play it on the PC, or use
**Open with…** to download it into a player like VLC.

**Files: no thumbnails.** Install `ffmpegthumbnailer`, poppler (`pdftoppm`) and/or
ImageMagick on the computer; small JPEG/PNG/HEIC images show without them.

**Files: "Not allowed to mount … over SSH (polkit)".** Add the
[polkit rule](#mounting-drives-over-ssh-polkit-rule).

**Commands fail when many things happen at once.** Your server may allow fewer
than the default 10 sessions per connection. Check `MaxSessions` in
`/etc/ssh/sshd_config`.

---

## Project layout

```
.
├── Package.swift          Swift package; dependency pins explained inline
├── Package.resolved       Exact dependency versions
├── xtool.yml              xtool config: bundle ID, Info.plist, icon
├── Info.plist             Display name, orientations, local-network prompt
├── install.sh             Build + sign + install via xtool
├── Resources/             App icon (PNG + SVG source)
└── Sources/SSHRemote/
    ├── SSH.swift          swift-nio-ssh wrapper: connect, auth, host keys, exec channels
    ├── AppModel.swift     Connections, command running, mouse/keyboard queues
    ├── Store.swift        hosts.json, Keychain (passwords + device key)
    ├── Models.swift       Host, Command, pages, tabs, presets, Android import
    ├── HostListView.swift Host list, import, device key, app entry point, theme
    ├── HostEditView.swift Host editor (auth, remote commands, tabs) + button editor
    ├── RemoteView.swift   Remote screen: tabs, fullscreen, button grid, touchpad, keyboard
    └── Files.swift        Files tab: browser, drives, viewers, SSH streaming
```

---

## License and credits

- Licensed under the **GNU General Public License v3.0**; see `LICENSE`.
- Based on **SSH Remote** for Android by **Stefan Sundin**
  ([github.com/stefansundin/SSHRemote](https://github.com/stefansundin/SSHRemote)):
  the concept, button model, presets, export format and icon.
- SSH is provided by [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh),
  built on [swift-nio](https://github.com/apple/swift-nio) and
  [swift-crypto](https://github.com/apple/swift-crypto).
- Built and signed with [xtool](https://github.com/xtool-org/xtool).
