# BO1 PS4 ↔ PS5 Cross-Version LAN Patch

Lets a console on **Black Ops 1 version 1.09** (retail PS5 or PS4) join and stay in a LAN match hosted by a **jailbroken PS4 on BO1 01.08** (CUSA57547).

## Download

**[⬇ Download the latest release (ZIP)](https://github.com/red0161/bo1-ps4-ps5-lan-patch/releases/latest/download/BO1-PS4-PS5-LAN-Patch.zip)**

Extract it, then follow [Usage](#usage) below. All releases: [Releases page](https://github.com/red0161/bo1-ps4-ps5-lan-patch/releases).

## Why it's needed

Every copy of BO1 reports a network version (protocol) when it advertises or joins a match:

| Game version | Protocol |
|---|---|
| 01.08 | 2120 (`0x848`) |
| 1.09 | 2121 (`0x849`) |

When they differ, the lobby is hidden and joins fail with *"Server is a different version"*. This patch makes the jailbroken PS4's running BO1 use 2121 on both its host side and its own local player side (10 code sites plus the `protocol` dvar), over [ps4debug](https://github.com/jogolden/ps4debug). Nothing is installed or changed on the guest console.

## Requirements

- Jailbroken PS4 with BO1 **01.08** (host) and the ps4debug payload loaded
- A second console with BO1 **1.09** (guest, retail is fine)
- A Windows PC on the same network. **Nothing to install:** the patch is a plain PowerShell script, and PowerShell is built into Windows.
- Both consoles on the same home network. Wired is best. No guest/IoT network.

## Usage

1. PS4: load ps4debug, start BO1 and go to the Multiplayer menu.
2. PC: keep any RTM / LAN Fix tool **closed** for now.
3. PC: double-click **`Start Patch.cmd`**, enter the PS4's IP, and choose **1. Apply patch**. Every line should show `0x849`.
4. PS4: LAN → Create Game → **start the match** and wait until you can move.
5. Guest: LAN → Join Game → join → pick team and class.
6. Only now open your RTM / LAN Fix tool, if you use one.

The menu also has **Check status** and **Restore original**.

`Start Patch.cmd` just runs `Patch-BO1.ps1`. Open either one in Notepad to see exactly what it does: no downloads, no installs, it only talks to ps4debug on your PS4.

Command line equivalent:

```
powershell -ExecutionPolicy Bypass -File Patch-BO1.ps1 <ps4_ip> apply
powershell -ExecutionPolicy Bypass -File Patch-BO1.ps1 <ps4_ip> status
powershell -ExecutionPolicy Bypass -File Patch-BO1.ps1 <ps4_ip> restore
```

A Python version with the same logic is in [`python/`](python/) if you prefer it (`python protocol_patch.py <ps4_ip> apply 0x849`).

## Notes

- **Memory only.** Restarting BO1 on the PS4 removes the patch, so re-apply after every restart.
- **Safe-guarded.** Every site is checked against the exact 01.08 bytes before writing and read back afterwards. On any other build it refuses and writes nothing.
- **Version-specific.** If the guest's BO1 updates past 1.09, its protocol will likely change.
- **Order matters.** An RTM / LAN Fix tool running before the guest joins can block LAN discovery.

## Troubleshooting

| Problem | Fix |
|---|---|
| Window flashes and closes, or "running scripts is disabled" | Use `Start Patch.cmd`, not the `.ps1` directly. It bypasses the policy for this one script only |
| `codmp.elf is not running` | Start BO1 on the PS4 first |
| `Can't reach ps4debug` | Load the payload, check the PS4's IP |
| Guest can't see the match | Make sure the PS4 **started** the match, status shows `0x849` everywhere, and no RTM tool was open yet |
| "Server is a different version" on the PS4 | BO1 restarted. Re-apply the patch |

## Disclaimer

Use at your own risk. Tested on one setup only (01.08 jailbroken PS4 host, 1.09 PS5 guest). Cross-version stat edits aren't fully proven, so test small changes first. Modified stats on an online account can get it flagged.
