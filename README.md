# WinFirewalk

WinFirewalk is a single-file Windows GUI tool for blocking or unblocking all `.exe` and `.dll` files inside a selected folder and its subfolders using Windows Firewall.

It is designed for situations where you want a quick, reversible way to keep everything inside a folder tree from calling out over the network, especially suspicious software or large folders with many executables.

<img width="2415" height="1833" alt="image" src="https://github.com/user-attachments/assets/d784aad0-15b1-401a-ad0a-71238109b781" />

## Why Use It?

Manually creating Windows Firewall rules for every executable in a game or app folder is tedious. WinFirewalk scans the folder for you, creates inbound and outbound block rules, and keeps enough state to make cleanup easier later.

## Features

- Blocks `.exe` and `.dll` files recursively
- Creates inbound and outbound Windows Firewall block rules
- Uses rule names based on the selected folder
- Refreshes existing WinFirewalk rules if you block the same folder again
- Supports pasted paths, Browse, drag-and-drop folders, `.exe` files, and `.lnk` shortcuts
- Shows folder firewall status and missing rules
- Generates an unblock helper script inside blocked folders
- Includes a Delete All WinFirewalk Rules cleanup option
- Single `.cmd` file, no installer required

## Requirements

- Windows 11
- Windows Defender Firewall enabled
- PowerShell
- Administrator approval for blocking, unblocking, and cleanup operations

## Usage

1. Run `WinFirewalk-GUI.cmd`.
2. Choose a target folder by typing a path, clicking Browse, or dragging a folder, shortcut, or `.exe` into the window.
3. Click `Block` to create firewall block rules for all supported files in that folder tree.
4. Click `View Folder Status` to check coverage.
5. Click `Unblock` to remove WinFirewalk rules for the selected folder.

## What It Creates

Inside blocked folders, WinFirewalk may create:

- `WinFirewalk.rules.json`
- `WinFirewalk-Unblock.cmd`

These files help identify and remove rules later. They are generated per target folder.

Firewall rules use names like:

```text
WinFirewalk - ExampleFolder
```

If another folder has the same name, WinFirewalk may append a short hash to keep the rule name unique.

## Notes and Limitations

WinFirewalk only manages rules it creates. It avoids touching unrelated Windows Firewall rules.

Steam .url shortcuts and other launcher/protocol shortcuts do not reveal the actual game install folder, so choose the game folder or .EXE manually in those cases.

Running Block again on an already-blocked folder refreshes the rules instead of stacking duplicates.
