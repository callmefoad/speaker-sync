<p align="center">
  <img src="docs/icon.png" width="160" alt="Speaker Sync icon">
</p>

<h1 align="center">Speaker Sync</h1>

<p align="center">
  Play your Mac's audio on a Bluetooth speaker and a wired speaker at the same time, actually in sync.
</p>

<p align="center">
  <img src="docs/screenshot.png" width="460" alt="Speaker Sync window">
</p>

---

## Why I built this

I've got a Polk soundbar on Bluetooth and a pair of Edifier speakers plugged into the headphone jack. I wanted music coming out of all of them at once.

macOS can kind of do this already. Audio MIDI Setup has a "Multi-Output Device" that sends sound to two places. The problem is Bluetooth runs a couple hundred milliseconds behind a cable, so the speakers echo off each other and it sounds terrible. There's no setting to fix that.

So I made this. It holds the wired speakers back by exactly how far behind the Bluetooth one is, so everything lands at the same time. Hit **Calibrate** and the Mac's mic measures the gap for you. Or tune it by ear with the test tick.

On my setup (Polk DSB1 + Edifier on the headphone jack) it lands around **225 ms**. Yours will be different, which is why it measures.

## What it does

- **One switch** sends all your Mac's audio to both speakers
- **Auto-calibrate.** Plays a few chirps, listens with the mic, and sets the delay. It pauses your music, turns the speakers to 50% (75% if it can't hear them), then puts everything back how it was.
- **Speaker check.** Beeps the left wired speaker, then the right, then Bluetooth, each on its own note. If mic access is on, it listens and checks each one off. Easy way to tell if something's unplugged or if left and right are swapped.
- **Follows your Bluetooth speaker.** Turns itself on when the speaker connects and off when it's gone.
- **Master volume.** Your volume keys control both speakers together and keep them balanced.
- **Bass and treble per speaker**, so you can get two different speakers to sound closer to each other
- **Themes.** Classic with any accent color, or go full 70s Groove, 80s Rock, 90s Metal, Y2K, or 50s Diner.
- **Remembers each speaker.** Every wired + Bluetooth combo keeps its own delay.
- **Keeps Bluetooth speakers awake** with an 18 Hz tone you can't hear, so the soundbar doesn't fall asleep between songs
- **Shows up as "Speaker Sync"** in the Sound menu
- **Shortcut** ⌃⌥⌘S turns it on or off from anywhere
- **Picks the right outputs on its own.** Wired goes to the headphone jack when something's plugged in. Bluetooth grabs the first speaker that's connected.
- **Recovers on its own** if the Bluetooth speaker drops or macOS switches outputs
- **Pick your calibration mic**, including your iPhone when it's nearby
- **Menu bar controls**, open at login, and start on launch
- **Turning it off puts your Mac back** on whatever output you had before

## What it needs permission for

I wanted this to be obvious, so here's everything it asks for and why. It's all in the app too, under Settings > Privacy.

| Permission | Why |
|---|---|
| **Microphone** | macOS treats the Speaker Sync cable like a microphone. All your Mac's audio goes into that cable, and the app has to listen to it to send the sound to your speakers. No mic access, no sound. |
| **Your actual mic** | Only turns on when you hit Calibrate or Speaker check. It records about 10 seconds, measures it, and deletes the recording right away. It never listens in the background and nothing gets saved or sent anywhere. |
| **Your password** | Only once, when you install the driver. macOS asks for it, not the app, so Speaker Sync never sees it or stores it. It's used to copy the driver into `/Library/Audio/Plug-Ins/HAL` (where every Mac audio driver lives) and restart the Mac's audio so it shows up. |
| **Pausing your music** | Calibrate and Speaker check pause whatever's playing and start it back up after, same as the play/pause key on your keyboard. No permission needed. It can tell something's playing, not what. |
| **Internet** | None. It never goes online. No account, no tracking, no analytics. |
| **Keyboard shortcut** | ⌃⌥⌘S works without Accessibility access. It only watches for that one combo, nothing else you type. |

## How it works

```
Mac apps ──► Speaker Sync (virtual audio cable)
                 │
                 ▼
         Speaker Sync engine ──► delay 225 ms + EQ ──► Wired speaker (aux / headphone jack)
                 │
                 └──────────────► EQ + keep-awake ───► Bluetooth speaker
```

1. While it's on, your Mac's output gets set to a virtual audio cable. It's a renamed build of [BlackHole](https://github.com/ExistentialAudio/BlackHole) that shows up as "Speaker Sync". Stock BlackHole works too.
2. The app builds a hidden audio device that holds the cable plus both speakers. macOS keeps all their clocks lined up, so they don't drift apart even after hours.
3. One audio callback reads the cable and writes each speaker, with the delay, bass and treble, volume, and the keep-awake tone all done right there. No extra programs, nothing to install from Homebrew.
4. The rest is a small native SwiftUI app that watches for speakers coming and going and gives you the controls.

## Install

You need macOS 14 or newer. That's it.

**1. Get the app**

Grab `Speaker-Sync.zip` from the [latest release](../../releases/latest), unzip it, and drag **Speaker Sync** into Applications.

It's not notarized by Apple, so macOS will block it the first time. Right-click the app and pick **Open**, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/Speaker Sync.app"
```

**Or build it yourself** (needs Xcode command line tools):

```bash
git clone https://github.com/callmefoad/speaker-sync.git
cd speaker-sync
./build.sh
```

That builds it and drops it in `~/Applications`. If you want the Speaker Sync driver bundled in too (needs full Xcode), run `./driver/build-driver.sh` first, then `./build.sh`.

**2. Install the driver**

Open the app and click **Install Driver**. macOS asks for your password once. If you'd rather use stock BlackHole, `brew install --cask blackhole-2ch` works too.

## Using it

1. Connect your Bluetooth speaker and plug the wired one into the headphone jack.
2. Open Speaker Sync and flip the big switch on. Allow the mic when it asks (see above for why).
3. Hit **Check** under Speaker check to make sure every speaker beeps.
4. Hit **Calibrate** and keep the room quiet for about 10 seconds.
5. Play something. If it's still a hair off, nudge **Wired delay** with the test tick on.

Themes, EQ, the mic picker, and the auto on/off live behind the gear button.

## Known limits

- **Calibration needs a quiet room.** Talking or other noise during the chirps gets you a "too noisy" result. Just run it again.
- **Keep-awake depends on the speaker.** Some soundbars only count louder audio as "playing".
- **Recalibrate after updating from an older version.** The new engine has less lag than the old sox setup, so your old delay will be about 100 ms too long.
- **One wired + one Bluetooth** for now.

## What's next

- More than two speakers
- A way to fine-tune sync while music's playing, without the test tick

Pull requests welcome.

## Files

| File | What it is |
|---|---|
| `main.swift` | The whole app: Core Audio handling, the sync engine, speaker check, calibration, themes, and the interface |
| `make_icon.swift` | Draws the app icon in code |
| `build.sh` | Builds the icon and app, signs it, installs to `~/Applications` |
| `driver/build-driver.sh` | Builds the renamed BlackHole driver ("Speaker Sync") |

## License

MIT. Do whatever you want with it.

The bundled audio driver is built from [BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential Audio, which is GPL-3.0. Its license is in `driver/BlackHole-LICENSE`.
