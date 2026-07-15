# AudioMIDIBridge

A macOS tool (Monterey 12+) that listens to audio input, analyses tempo and energy in real time, and emits MIDI notes/CCs on a virtual CoreMIDI port. Designed to drive DMX lighting software via MIDI without needing a dedicated DJ controller. Ships as both a command-line dashboard (`AudioMIDIBridge`) and a native GUI (`AudioMIDIBridgeGUI`) — both run the identical audio/MIDI engine, packaged as the `AudioMIDIBridgeCore` library.

---

## What it does

```
Microphone / Line-In
  → FFT analysis (configurable window)
    ├── RMS + spectral flux onset detection
    │     ├── TempoDetector  → beat tap note-on (Ch 1, Note 60)
    │     ├── EnergyTracker  → scene change notes + crossfade CC (Ch 2)
    │     └── BandTriggers   → kick/snare/hihat/bass notes (Ch 3)
    └── Silence detector     → reset note when music stops (Ch 2, Note 127)
```

All output appears on a virtual MIDI source named **"AudioMIDIBridge"** — connect to it from any MIDI-capable app.

---

## Build

```bash
cd AudioMIDIBridge
swift build -c release
# Binaries at:
.build/release/AudioMIDIBridge       # CLI + terminal dashboard
.build/release/AudioMIDIBridgeGUI    # native GUI
```

Or open in Xcode:
```bash
open Package.swift
```

---

## Microphone permission

On first run macOS will prompt for microphone access. If it doesn't, grant it manually:

**System Preferences → Security & Privacy → Privacy → Microphone → Terminal (or your app)**

---

## Run

```bash
# Default config (./config.toml)
.build/release/AudioMIDIBridge

# Custom config
.build/release/AudioMIDIBridge --config /path/to/my.toml

# List audio inputs (to find your interface name or unique ID)
.build/release/AudioMIDIBridge --list-audio

# Select an audio input by unique ID
.build/release/AudioMIDIBridge --device-id <audio-device-uid>

# List MIDI destinations (to verify routing)
.build/release/AudioMIDIBridge --list-midi

# Run headless (no terminal dashboard, plain log output)
.build/release/AudioMIDIBridge --no-display
```

---

## GUI

```bash
# Default config (./config.toml)
.build/release/AudioMIDIBridgeGUI

# Custom config (positional argument, no flag)
.build/release/AudioMIDIBridgeGUI /path/to/my.toml
```

The GUI runs the same engine as the CLI (starts listening immediately) and adds:

- **Analog meters** for realtime and buffered energy, with green/yellow/red zones driven by the live `baseline_threshold`/`peak_threshold`.
- **Threshold sliders** — `silence_threshold`, `baseline_threshold`, `peak_threshold`, and each energy level's `min_rms`/`max_rms` — take effect immediately on the running engine, no restart.
- **Save** writes only the changed value tokens back into `config.toml` in place, preserving all comments and formatting. **Revert** reloads those same values from whatever is currently on disk, discarding unsaved slider changes.
- **History** of the last 5 energy-level transitions with duration and MIDI note sent.
- **Frequency bands**, **status/play time/silence time/tempo**, and the resolved **audio input** / **MIDI output** are all displayed read-only.
- **Calibrate…** runs the same analysis as `--calibrate` against `calibration.audio_file`, after a confirmation dialog (shown the configured file path) warning that applying the recommendations will overwrite current, unsaved threshold adjustments. Applying is still a live-only change until you press Save.

<img width="1664" height="1013" alt="image" src="https://github.com/user-attachments/assets/b178578f-a043-4191-a07a-6bbfc8e58ac4" />

Note: audio input device selection and MIDI note/channel assignments are fixed at launch (from config.toml) and aren't editable from the GUI — only the threshold values above are live-adjustable.

---

## Terminal Dashboard

```
AudioMIDIBridge  uptime 00:02:14
────────────────────────────────────────────────────────────
Status  : ● ACTIVE
Tempo   : 128.0 BPM ♩
Energy  : ████████████░░░░░░░░░░░░░░░░░░  62%  high

Frequency Bands:
  kick     ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪·····  82%
  snare    ▪▪▪▪▪▪▪▪▪▪··········  54%
  hihat    ▪▪▪▪·················  20%
  bass     ▪▪▪▪▪▪▪▪▪▪▪▪·········  63%

MIDI (virtual source: AudioMIDIBridge):
  Tap    ch1 note60
  Energy ch2 notes 0/36/37/38/39
  Silence ch2 note127

Press Ctrl-C to quit
```

The beat marker (`♩`) flashes on every detected beat. Event log appears in stderr (visible in a second terminal pane or redirected to a file).

---

## MIDI Mapping (defaults)

| Event | Channel | Note/CC | Velocity | Notes |
|---|---|---|---|---|
| Beat tap | 1 | Note 60 | 100 | 20ms pulse per beat |
| Energy: silent | 2 | Note 0 | 0 | |
| Energy: low | 2 | Note 36 | 40 | |
| Energy: medium | 2 | Note 37 | 80 | |
| Energy: high | 2 | Note 38 | 110 | |
| Energy: very high | 2 | Note 39 | 127 | |
| Crossfade hint | 2 | CC 20 | 0–127 | Value = duration 0–8s |
| Silence begin | 2 | Note 127 | 0 | Fires after holdoff |
| Music resume | 2 | Note 126 | 64 | |
| Kick trigger | 3 | Note 48 | dynamic | |
| Snare trigger | 3 | Note 49 | dynamic | |
| Hi-hat trigger | 3 | Note 50 | dynamic | |
| Bass trigger | 3 | Note 51 | dynamic | |

All of these are configurable in `config.toml`.

---

## Configuration

`config.toml` is heavily commented. Key sections:

### `[audio]`
```toml
input_device = "Focusrite"      # substring match; empty = system default
# You can also select a specific device by unique ID with --device-id
fft_size = 2048                 # larger = better freq resolution, more latency
silence_threshold = 0.01        # tune to your noise floor
silence_holdoff_frames = 200    # ~2.2s before silence is declared
```

### `[frequency_bands]`
```toml
kick  = [40, 120]     # Hz range to monitor
snare = [150, 400]
```
Bands defined here are both displayed in the dashboard and available for `[[band_triggers.bands]]`.

### `[tempo]`
```toml
bpm_min = 60
bpm_max = 180
onset_sensitivity = 0.5   # 0=conservative, 1=very sensitive
tap_note = 60
```

### `[energy]`
```toml
cycle_beats = 16
cycle_notes = [60, 62, 64, 65, 67, 69, 71, 72]  # notes cycled after the configured number of beats
baseline_threshold = 0.05
peak_threshold = 0.25
peak_note = -1
peak_channel = 2
peak_velocity = 100
trough_note = -1
trough_channel = 2
trough_velocity = 100
```

Example:
```toml
[energy]
cycle_beats = 16
cycle_notes = [60, 64, 67, 72]  # C major arpeggio on stable sections
baseline_threshold = 0.05
peak_threshold = 0.25
peak_note = 61
peak_channel = 2
peak_velocity = 120
trough_note = 59
trough_channel = 2
trough_velocity = 100
```

The app waits for the configured number of beats before cycling to the next stable energy note. Realtime peak/trough notes can still fire sooner when the envelope crosses the configured thresholds, so immediate transitions remain possible without breaking the long-term cycle timing.

### `[[energy.levels]]`
Add/remove/tune levels freely. `min_rms` and `max_rms` are linear RMS values (0.0–1.0). Start with a sound level meter or the dashboard to calibrate.

```toml
[[energy.levels]]
name      = "high"
min_rms   = 0.20
max_rms   = 0.50
midi_notes = [38, 40, 42]
channel   = 2
velocity  = 110
```

Example level set:
```toml
[[energy.levels]]
name      = "silent"
min_rms   = 0.00
max_rms   = 0.01
midi_note = 0
channel   = 2
velocity  = 0

[[energy.levels]]
name      = "low"
min_rms   = 0.01
max_rms   = 0.08
midi_notes = [36, 38, 40]
channel   = 2
velocity  = 40

[[energy.levels]]
name      = "medium"
min_rms   = 0.08
max_rms   = 0.20
midi_notes = [37, 39, 41]
channel   = 2
velocity  = 80
```

Note: MIDI note numbers map directly to pitches, for example 60=C4, 62=D4, 64=E4, 65=F4, 67=G4, 69=A4, 71=B4, 72=C5. Use `midi_notes` to define a sequence for each energy level; the app will cycle to the next note in that list every `cycle_beats` while the level remains stable.

### `[energy.smoothing]`
```toml
attack_frames  = 3    # fast attack (snappy response)
release_frames = 30   # slow release (avoids rapid switching)
hysteresis     = 0.02 # prevents jitter at level boundaries
```

### `[[band_triggers.bands]]`
```toml
[[band_triggers.bands]]
name           = "kick"
threshold      = 0.15    # band RMS must exceed this to trigger
midi_note      = 48
channel        = 3
velocity_scale = 1.0     # scales detected energy to MIDI velocity
```

### `[crossfade]`
When energy changes, a CC is sent whose value encodes the suggested crossfade time (in seconds, scaled 0–8s → 0–127). Your DMX app reads this CC to set the blend duration between scenes.

```toml
cc_number     = 20
channel       = 2
default_beats = 4   # bars to crossfade when BPM unknown
```

---

## Calibration Tips

1. **Noise floor**: Run with `--no-display` and pipe stderr to a file while in silence, check the logged RMS values. Set `silence_threshold` just above the idle noise.

2. **Energy levels**: Play representative songs at your venue level. Watch the energy bar in the dashboard. Adjust `min_rms`/`max_rms` in `[[energy.levels]]` to match the desired scene boundaries.

3. **Tempo sensitivity**: If BPM jumps around, raise `bpm_smoothing_beats`. If it's slow to lock, lower `onset_sensitivity`.

4. **Band thresholds**: Watch the band bars in the dashboard. Set `threshold` in `[[band_triggers.bands]]` to just above the idle level for that band.

5. **Frequency bands**: If kick bleeds into snare, tighten the Hz ranges. For a typical club PA: kick `[40, 100]`, snare `[170, 350]`.

---

## Routing MIDI

On macOS, the virtual CoreMIDI port `AudioMIDIBridge` appears automatically in:
- **Ableton Live** — Preferences → MIDI → Input: AudioMIDIBridge
- **QLab** — Workspace Settings → MIDI → Input
- **TouchDesigner** — MIDI In DAT → device: AudioMIDIBridge
- **Resolume** — Preferences → MIDI → Input
- **Any app using CoreMIDI** — it will appear in the MIDI device list

You can also route it through **MIDI Monitor** (free, Snoize) to see raw output while tuning.

---

## Signing / Notarization

For distribution, sign with your Developer ID and notarize. For personal use on your own machine, no signing is needed — just grant microphone access when prompted.

To allow running without Gatekeeper prompt:
```bash
xattr -d com.apple.quarantine .build/release/AudioMIDIBridge
```
