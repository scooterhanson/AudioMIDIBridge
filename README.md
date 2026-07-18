# AudioMIDIBridge

**Version 1.0**

A macOS tool (Monterey 12+) that listens to audio input, analyses tempo and energy in real time, and emits MIDI notes/CCs on a virtual CoreMIDI port. Designed to drive DMX lighting software via MIDI without needing a dedicated DJ controller. Ships as both a command-line dashboard (`AudioMIDIBridge`) and a native GUI (`AudioMIDIBridgeGUI`) — both run the identical audio/MIDI engine, packaged as the `AudioMIDIBridgeCore` library. Built for live use: the audio/MIDI pipeline degrades gracefully (see [Reliability & Failsafe Design](#reliability--failsafe-design)) rather than silently dying mid-show.

---

## What it does

```
Microphone / Line-In
  → FFT analysis (configurable window)
    ├── RMS + spectral flux onset detection
    │     ├── TempoDetector  → beat tap note-on (Ch 1)
    │     ├── EnergyTracker  → scene change notes + crossfade CC (Ch 2)
    │     │     ├── modulated by a tempo-based ceiling (slow tempo caps the level)
    │     │     └── modulated by a band-activity boost (busy bands elevate the level)
    │     └── BandTriggers   → kick/snare/hihat/bass notes (Ch 3)
    └── Silence detector     → reset note when music stops (Ch 2)

Every MIDI note-on is also logged to a per-session CSV, and can be
rendered to a timeline chart (PNG) on demand — see Session Recording & Charts.
```

All output appears on a virtual MIDI source named **"AudioMIDIBridge"** — connect to it from any MIDI-capable app. Every note-on currently uses a fixed velocity of 100 — there's no per-note velocity configuration.

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

# Manual input gain override
.build/release/AudioMIDIBridge --gain 2.5

# Run calibration against calibration.audio_file, write calibration_summary.txt, exit
.build/release/AudioMIDIBridge --calibrate

# Run headless (no terminal dashboard, plain log output)
.build/release/AudioMIDIBridge --no-display

# Print the version and exit
.build/release/AudioMIDIBridge --version
```

Quitting with **Ctrl-C** (`SIGINT`) or a plain `kill`/process-supervisor stop (`SIGTERM`) both run the same graceful shutdown: the silence note-off fires, the session's event log is closed, and — if any MIDI events were sent this session — a timeline chart PNG is generated automatically (see below).

---

## GUI

```bash
# Default config (./config.toml)
.build/release/AudioMIDIBridgeGUI

# Custom config (positional argument, no flag)
.build/release/AudioMIDIBridgeGUI /path/to/my.toml
```

The GUI runs the same engine as the CLI (starts listening immediately) and adds:

- **Analog meters** for realtime and buffered energy, spanning the top of the window, with green/yellow/red zones driven by the live `baseline_threshold`/`peak_threshold`.
- **Status panel** — current state (ACTIVE/SILENT/PAUSED/**AUDIO STALLED**, see [Reliability](#reliability--failsafe-design)), tempo, beats remaining until the next auto-cycle note, play/silence time, last MIDI event sent, app version, and the resolved config.toml path. Also surfaces transient notices (e.g. a MIDI reconnect after a system reset) and a dismissible warning banner if config.toml had a value that had to be auto-corrected at load.
- **History** of the last 5 energy-level transitions with duration and MIDI note sent.
- **Tuning recommendations** — a dismissible banner appears if the buffered energy level has been switching too fast for your configured hysteresis/levels to keep up with, listing concrete tips.
- **Levels tab** — sliders for every numeric threshold: core thresholds (silence/baseline/peak), each energy level's `min_rms` (the active level's slider pulses red on the beat), energy smoothing (hysteresis/attack/release/buffer duration), tempo (hit history, onset sensitivity, the tempo-cap thresholds and their hysteresis margin), crossfade beats, and band triggers (enabled toggle, per-band threshold, and the band-activity boost's band count/level count). All take effect immediately on the running engine, no restart.
- **Advanced tab** — dropdowns for every MIDI note/channel assignment: energy levels (including Silent), tempo tap, peak/trough (with a "Disabled" option), band triggers, and the crossfade CC number/channel. Deliberately dropdowns, not text fields — every value here is a small bounded range (0–127, 1–16), so there's nothing to mistype. **Switching to this tab pauses audio capture and processing** (so edits never race a live audio callback); switching back to Levels resumes it automatically.
- **Save** writes only the changed value tokens back into `config.toml` in place, preserving all comments and formatting. **Revert** reloads those same values from whatever is currently on disk, discarding unsaved changes.
- **Generate Chart…** renders a timeline PNG of every MIDI event sent this session and shows it in a preview sheet (with a "Reveal in Finder" shortcut) — see [Session Recording & Charts](#session-recording--charts). Entirely manual and on-demand; nothing here ever redraws continuously.
- **Calibrate…** runs the same analysis as `--calibrate` against `calibration.audio_file`, after a confirmation dialog (shown the configured file path) warning that applying the recommendations will overwrite current, unsaved threshold adjustments. Applying is still a live-only change until you press Save.

<<<<<<< HEAD
<img width="1664" height="1013" alt="image" src="https://github.com/user-attachments/assets/b178578f-a043-4191-a07a-6bbfc8e58ac4" />

Note: audio input device selection and MIDI note/channel assignments are fixed at launch (from config.toml) and aren't editable from the GUI — only the threshold values above are live-adjustable.
=======
Note: audio input device selection and a handful of startup-only values (`sample_rate`, `fft_size`, `hop_size`, silence begin/resume note & channel) are fixed at launch from config.toml and aren't editable from the GUI.
>>>>>>> a09b516 (v1.0 adding timeline charting, tempo and energy level stability enhancements, band frequency trigger influence on energy level changes, and failsafe controls)

---

## Terminal Dashboard

```
AudioMIDIBridge 1.0  uptime 00:02:14
────────────────────────────────────────────────────────────
Status  : ● ACTIVE
Play    : 00:02:01
Silence : 00:00:13
Tempo   : 128.0 BPM ♩
Cycle   : 32 beats
Energy  : ████████████░░░░░░░░░░░░░░░░░░  62%  high
Buffered: ███████████░░░░░░░░░░░░░░░░░░░  58%

Frequency Bands:
  kick     ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪·····  82%
  snare    ▪▪▪▪▪▪▪▪▪▪··········  54%
  hihat    ▪▪▪▪·················  20%
  bass     ▪▪▪▪▪▪▪▪▪▪▪▪·········  63%

MIDI (virtual source: AudioMIDIBridge):
  Tap    ch1 note60
  Energy ch2 notes 0/36/37/38/39
  Silence ch2 note127
  Last note: ch2 note38

Press Ctrl-C to quit
```

The beat marker (`♩`) flashes on every detected beat. Event log (`[BEAT]`, `[ENERGY]`, `[CYCLE]`, `[PEAK]`/`[TROUGH]`, `[SILENCE]`/`[RESUME]`, `[CONFIG WARNING]`, `[WATCHDOG]`, `[MIDI]`) appears on stderr, separate from the dashboard on stdout — visible in a second terminal pane or redirected to a file.

---

## MIDI Mapping (defaults)

Every note-on uses a fixed velocity of 100 — see [What it does](#what-it-does).

| Event | Channel | Note/CC | Notes |
|---|---|---|---|
| Beat tap | 1 | Note 60 | 20ms pulse per beat |
| Energy: silent | 2 | Note 0 | |
| Energy: low | 2 | Note 36 | |
| Energy: medium | 2 | Note 37 | |
| Energy: high | 2 | Note 38 | |
| Energy: very high | 2 | Note 39 | |
| Crossfade hint | 2 | CC 20 | Value = duration 0–8s |
| Silence begin | 2 | Note 127 | Fires after holdoff |
| Music resume | 2 | Note 126 | |
| Kick trigger | 3 | Note 48 | |
| Snare trigger | 3 | Note 49 | |
| Hi-hat trigger | 3 | Note 50 | |
| Bass trigger | 3 | Note 51 | |

All of these are configurable in `config.toml`. The tempo-based energy cap and the band-activity boost (see below) don't send their own MIDI — they modulate *which* energy-level note fires, not add new ones.

---

## Configuration

`config.toml` is heavily commented. Key sections:

### `[audio]`
```toml
input_device = ""               # substring match; empty = system default
sample_rate = 44100              # 44100 or 48000 — fixed at launch
fft_size = 2048                  # must be a power of two; larger = better freq resolution, more latency
hop_size = 512                   # samples between analysis frames
silence_threshold = 0.01         # tune to your noise floor
silence_holdoff_frames = 200     # ~2.2s before silence is declared
input_gain = 1.0                 # manual multiplier; combines with auto-gain
auto_gain_enabled = true
auto_gain_calibration_ms = 1500
auto_gain_max = 25.0
```
`sample_rate`, `fft_size`, and `hop_size` are validated at load — an invalid value (zero/negative, or a non-power-of-two `fft_size`) is replaced with a safe default and surfaced as a warning (GUI banner / CLI `[CONFIG WARNING]`) rather than crashing the app. You can also select a specific device by unique ID with `--device-id`.

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
onset_sensitivity = 0.5          # 0=conservative, 1=very sensitive
bpm_smoothing_beats = 16         # how many recent kick hits the estimate is built from
tap_note = 60
tap_channel = 1
tap_note_duration_ms = 20
```
Onset/beat detection tracks the **kick** frequency band specifically (falls back to the full spectrum if no band named `kick` is configured), since it's a far more reliable tempo reference than broadband onset. Tempo induction identifies kick hits and forms/refines a BPM estimate from the pattern of hit intervals — it doesn't assume the kick lands on every beat, so syncopation is handled.

### `[energy]`
```toml
cycle_beats = 16                 # beats between auto-cycle notes on a stable level
baseline_threshold = 0.05
peak_threshold = 0.25
peak_note = -1                   # -1 = disabled
peak_channel = 2
trough_note = -1                 # -1 = disabled
trough_channel = 2

# Tempo-based energy ceiling — see "Tempo cap" below.
low_bpm_cap_threshold = 95.0
medium_bpm_cap_threshold = 115.0
bpm_cap_hysteresis = 3.0

# Band-activity level boost — see "Band-activity energy boost" below.
band_activity_boost_band_count = 0   # 0 = disabled
band_activity_boost_levels = 1
```

Realtime peak/trough notes can fire sooner than a full cycle when the raw envelope crosses `baseline_threshold`/`peak_threshold`, independent of the long-term cycle timing.

#### Tempo cap
While the detected BPM stays below `low_bpm_cap_threshold`, the energy level is never allowed above the level named `low`; below `medium_bpm_cap_threshold`, never above `medium`. No cap applies once tempo clears `medium_bpm_cap_threshold`, or while no tempo estimate exists yet (BPM 0 is treated as "unknown," not "slow"). `bpm_cap_hysteresis` is the margin (in BPM) the tempo must clear a threshold by, in the direction that *relaxes* the cap, before it takes effect — tightening is always immediate. Without this margin, ordinary BPM jitter right at a threshold would flicker the cap (and the cycle-beat countdown along with it) on and off every frame.

#### Band-activity energy boost
The bands configured under `[[band_triggers.bands]]` can also *elevate* the overall energy level when several are simultaneously active — reusing the triggers you've already tuned rather than any separate spectral analysis. While at least `band_activity_boost_band_count` bands are simultaneously within their post-trigger holdoff window, the level is bumped up by `band_activity_boost_levels` steps — applied *before* the tempo cap above, which always wins as the final ceiling.

**Example**: a four-piece band is playing a moderate groove — overall RMS alone would put you at `medium`. If the kick and snare triggers both happen to be active at the same moment (busy hi-hat/cymbal work, a syncopated snare fill), that's 2 simultaneously-active bands, meeting `band_activity_boost_band_count = 2`, so the level is bumped to `high` for as long as that activity holds. When the drummer drops back to a sparser pattern, the boost stops applying and the level settles back to whatever the overall RMS alone indicates — it never gets "stuck" elevated.

Set `band_activity_boost_band_count = 0` to disable this entirely (the default). It only has any effect while `[band_triggers] enabled = true`.

### `[[energy.levels]]`
Each level has only a **lower** boundary (`min_rms`); a level's effective upper bound is always the *next* level's `min_rms`, so levels can never gap or overlap. Levels are checked in ascending `min_rms` order. The first level (`silent` by convention) catches everything below the second level's `min_rms` — its own `min_rms` is unused. The last level has no upper bound.

```toml
[[energy.levels]]
name       = "silent"
min_rms    = 0.0
midi_notes = [0]
channel    = 16

[[energy.levels]]
name       = "low"
min_rms    = 0.165456
midi_notes = [36, 38, 40]
channel    = 16

[[energy.levels]]
name       = "medium"
min_rms    = 0.365152
midi_notes = [37, 38, 41]
channel    = 16
```

`midi_notes` is a list, not a single note: the app cycles to the next note in that list every `cycle_beats` while the level remains stable, and remembers where it left off if you re-enter a level later in the same session (so re-entering `medium` continues its sequence rather than restarting at the first note). A level with a single note is just a one-element list.

The tempo cap and band-activity boost above match levels **by name** — `low`/`medium` specifically — so keep those two names if you use either feature.

### `[energy.smoothing]`
```toml
attack_frames  = 3      # fast attack (snappy response)
release_frames = 30     # slow release (avoids rapid switching)
hysteresis     = 0.02   # prevents jitter at level boundaries
buffer_duration_ms = 500  # averaging window on top of attack/release, for the level decision itself
```

### `[silence]`
```toml
midi_note  = 127        # sent when no music is detected (after silence_holdoff_frames)
channel    = 2
resume_note     = 126   # sent when music resumes
resume_channel  = 2
```

### `[[band_triggers.bands]]`
```toml
[band_triggers]
enabled = true               # master switch — false disables every band trigger below
trigger_duration_ms = 30

[[band_triggers.bands]]
name      = "kick"
threshold = 0.15    # band RMS must exceed this to trigger
midi_note = 48
channel   = 3
```

### `[crossfade]`
When energy changes, a CC is sent whose value encodes the suggested crossfade time (in seconds, scaled 0–8s → 0–127). Your DMX app reads this CC to set the blend duration between scenes.

```toml
cc_number     = 20
channel       = 2
default_beats = 4   # bars to crossfade when BPM unknown
```

### `[calibration]`
```toml
audio_file = "calibration_test.wav"

[[calibration.sections]]
name = "silence"
start_time = 0.0
```
Used by `--calibrate` / the GUI's Calibrate button — see [Calibration Tips](#calibration-tips).

---

## Session Recording & Charts

Every MIDI note-on sent during a session is recorded — never for live/continuous display, purely for after-the-fact review:

- **Continuous CSV log**: written incrementally throughout the session to `midi_events_<timestamp>.csv` next to `config.toml` (columns: `timestamp_sec, note, channel, velocity, source`). This is the crash-safe record — it exists as the session runs, not only after a clean export.
- **Timeline chart (PNG)**: a scatter chart, time on the X axis and MIDI note number on the Y axis, color-coded by trigger type — **blue** = tempo tap, **purple** = silence, **green/yellow/orange/red** = low/medium/high/very-high energy levels, with peak/trough/resume/band triggers each getting their own distinct color. Generated **manually only**:
  - **GUI**: the "Generate Chart…" button (Levels tab footer) renders on a background queue and shows the result in a preview sheet.
  - **CLI**: generated automatically once, on graceful shutdown (Ctrl-C or `kill`) — i.e. only after the session has already ended, never during it — saved to `midi_timeline_<timestamp>.png` next to `config.toml`.

Recording itself is fire-and-forget from the audio thread's perspective and structurally can't affect MIDI delivery — see [Reliability & Failsafe Design](#reliability--failsafe-design).

---

## Reliability & Failsafe Design

Built for live use — the following are all deliberate design choices, not incidental behavior:

- **Config validation at load.** `sample_rate`, `fft_size`, and `hop_size` are checked at load time; an invalid value falls back to a safe default with a warning (GUI: dismissible banner; CLI: `[CONFIG WARNING]` on stderr) instead of crashing at launch.
- **MIDI reset detection.** The virtual MIDI port automatically recreates itself if CoreMIDI's `midiserver` daemon restarts (a real, if rare, macOS occurrence) — the app watches for `kMIDIMsgSetupChanged` and only recreates the endpoint if it's actually gone stale (an unrelated MIDI device being plugged in doesn't trigger a needless reconnect). Surfaces a transient "MIDI reconnected" notice.
- **Audio pipeline watchdog.** If the audio pipeline stops delivering frames for more than a few seconds — an interface disconnecting, a route change the engine didn't recover from — the app detects it (`onFrame` fires continuously regardless of musical silence, so this only ever fires on a genuine failure), shows a clear **AUDIO STALLED** status, and attempts an automatic recovery cycle.
- **Event logging can't affect MIDI delivery.** Recording a MIDI event to the session CSV happens on its own background queue, never the audio thread, and a write failure (disk full, permissions) silently disables further file writes rather than throwing — logging degrades, live MIDI output doesn't.
- **Chart generation is fully isolated from the live path.** It's manual/on-demand only (see above), runs on a background queue, and a failure is reported as a normal error, never a crash.
- **Graceful shutdown on both `SIGINT` and `SIGTERM`** (CLI) — a plain `kill`, not just Ctrl-C, still runs the silence note-off, closes the event log cleanly, and generates the session chart.
- **NaN/Infinity guards** throughout the audio→MIDI pipeline (`Safety.swift`) — a bad sample can't propagate into a trapping `Int(Double)` conversion (MIDI velocities/CCs, display percentages).

---

## Calibration Tips

1. **Noise floor**: Run with `--no-display` and pipe stderr to a file while in silence, check the logged RMS values. Set `silence_threshold` just above the idle noise.

2. **Energy levels**: Play representative songs at your venue level. Watch the energy bar in the dashboard. Adjust each level's `min_rms` to match the desired scene boundaries.

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

---

## Version History

Versioning follows MAJOR.MINOR: MINOR increments on each release build unless a MAJOR bump is explicitly called for (which resets MINOR to 0).

| Version | Highlights |
|---|---|
| **1.0** | Initial versioned release. Includes: real-time tempo detection with kick-band-restricted onset and syncopation-aware BPM induction; energy-level scene detection with configurable levels, hysteresis, and a tempo-based cap + band-activity boost that both modulate the active level; per-band frequency triggers; silence detection with automatic MIDI reset; crossfade CC hints; a full native GUI (Levels/Advanced tabs, live meters, calibration, session chart generation) alongside the terminal dashboard; per-session MIDI event logging (CSV) and on-demand timeline chart rendering (PNG); config validation with safe fallbacks; CoreMIDI reset detection; an audio pipeline watchdog with automatic recovery; graceful shutdown on `SIGINT`/`SIGTERM`. Also folds in fixes made during development: NaN/Infinity crash guards throughout the audio pipeline, a calibration crash from an unsafe C string format, energy-level boundary/hysteresis bugs, tempo-estimate "blips" on syncopated hits, a bug where tempo kept reporting beats for a while after the music actually stopped, GUI responsiveness issues on the Advanced tab (excess re-rendering), and a MIDI event log write path that could have crashed the app on a disk-full condition. |

---
