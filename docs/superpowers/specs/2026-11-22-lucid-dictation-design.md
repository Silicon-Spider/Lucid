# Lucid: design spec

Date: 22 November 2026. Status: design approved, awaiting spec review.
Background research: [`docs/research.md`](../../research.md).

## 1. Goal

A macOS menu-bar app that turns speech into clean written text in any app. Hold a key,
speak, release, and the text appears at the cursor with filler words, false starts and
self-corrections already removed. Everything runs on the Mac. No audio or text leaves it.

## 2. Scope

**In the first version**

- Global hold-to-talk hotkey, plus a hands-free mode.
- On-device speech recognition.
- Two-stage cleanup: instant rules, then a local LLM, with a safety check.
- Three cleanup levels: Off, Light (default), Medium.
- Text inserted at the cursor in any app.
- A small on-screen pill showing recording and processing.
- Personal dictionary: custom words and "misheard → correct" replacements.
- History that keeps the original transcript of every dictation.
- Tone chosen by the app being dictated into.
- A settings window and first-run permissions onboarding.

**Not in the first version**

- Voice editing of selected text ("make this more formal").
- Spoken snippets that expand to saved text.
- Automatic learning from the user's manual corrections.
- Streaming text while speaking. Lucid writes once, after the utterance, by design.
- Languages other than English. The speech model is multilingual, but the cleanup prompt
  and test set are English only.
- Bundling the engines inside the app, notarisation, or an installer.
- Windows, Linux, iOS.

## 3. Constraints

- Build machine: Apple M4, 16 GB RAM, macOS 15.6.1.
- No Xcode. Command Line Tools only: Swift 5.9.2, macOS 14.2 SDK, no XCTest.
- The app must therefore build with `swift build`, use only system frameworks, and take
  no Swift package dependencies.
- Fully local. The only network use is the one-time model download.
- Licence: GPLv3, already in the repository. whisper.cpp and llama.cpp are MIT licensed
  and run as separate processes.

## 4. Architecture

```
            ┌──────────────────────────── Lucid.app ────────────────────────────┐
 hotkey ──▶ │ HotkeyMonitor ─▶ DictationController ─▶ PillWindow                │
            │                        │                                           │
   mic ───▶ │ AudioRecorder ─────────┤                                           │
            │                        ▼                                           │
            │                  Pipeline (LucidCore)                              │
            │   Transcriber ─▶ RulesCleaner ─▶ LLMCleaner ─▶ Guardrails          │
            │                                   ─▶ Dictionary ─▶ StyleRules      │
            │                        │                                           │
            │                        ▼                                           │
            │   TextInserter ─▶ focused app          HistoryStore                │
            └───────┬───────────────────────────────────────────────────────────┘
                    │ HTTP on 127.0.0.1
        ┌───────────┴───────────┐
        ▼                       ▼
  whisper-server           llama-server
  (speech → text)          (text cleanup)
```

The app is a Swift package with five targets:

| Target | Kind | Contents | Depends on |
|---|---|---|---|
| `LucidCore` | library | Pure text logic: rules cleaner, guardrails, dictionary, prompt builder, style rules, WAV encoding, history model. Foundation only. | nothing |
| `LucidEngines` | library | Engine supervisor and the two HTTP clients. | `LucidCore` |
| `Lucid` | executable | The menu-bar app: hotkey, audio, pill, insertion, settings. AppKit and SwiftUI. | both libraries |
| `lucid-cli` | executable | Command-line access to the pipeline, for testing and benchmarking. | both libraries |
| `LucidCoreTests` | executable | Unit tests with a small built-in harness, because XCTest is unavailable. | `LucidCore` |

Engines sit behind two protocols, `Transcriber` and `TextCleaner`. Replacing the helper
processes with in-process libraries later means writing new conformances and nothing else.

## 5. Components

### HotkeyMonitor
Watches the dictation key with a `CGEventTap` and reports `down`, `up`, `otherKeyDown`
and `escape`. Default key is Fn. Right Option and Right Command are selectable. Needs
Accessibility permission.

### DictationController
The state machine in section 6. Owns the recorder, runs the pipeline, drives the pill,
and calls the inserter. It is the only component that knows the order of events.

### AudioRecorder
Captures the default input with `AVAudioEngine`, converts to 16 kHz mono 16-bit PCM, and
holds it in memory. Starts on key down. Reports a live level for the pill. Returns the
samples and the peak level on stop.

### EngineSupervisor
Starts `whisper-server` and `llama-server` as child processes at launch, each bound to
`127.0.0.1` on a free port, with the models loaded and kept warm. Waits for each to
report healthy. Restarts a crashed engine up to three times with backoff. Stops both on
quit, and kills leftovers from a previous crashed run using a PID file.

### Transcriber (`WhisperClient`)
Sends a WAV to `whisper-server` and returns the transcript. Passes dictionary terms as
the recognition prompt so unusual words are spelled correctly.

### Pipeline (in `LucidCore`)
Takes a raw transcript plus context (cleanup level, app category, dictionary, whether
the cursor is mid-sentence) and returns the final text along with a record of what each
stage did. Detailed in section 7.

### TextInserter
1. Reads the focused element through the Accessibility API, best effort.
2. Adds a leading space if the character before the cursor is not whitespace or an
   opening bracket.
3. Saves the clipboard, writes the text marked as transient so clipboard managers ignore
   it, sends Cmd+V, and restores the clipboard 400 ms later.

It does not paste when a secure field is active or when the focused element is clearly
not a text field. In both cases the text stays on the clipboard and the pill says so.
When the Accessibility API cannot tell, it pastes.

### PillWindow
A borderless panel that never takes focus and ignores clicks. Bottom centre of the screen
holding the cursor. Hidden when idle. Shows live level bars while recording, an animation
while processing, and short messages such as "Copied. Press ⌘V".

### HistoryStore
Keeps the last 200 dictations: time, app, raw transcript, final text, which stages ran,
any fallback reason, and per-stage timings. Keeps the audio of the last 20 dictations for
7 days so a failed one can be retried. Audio retention can be switched off.

### Menu and Settings
The menu-bar menu shows engine status, the ten most recent dictations (click to copy),
"Paste last original", Settings and Quit. The settings window has four tabs: General
(hotkey, cleanup level, microphone, launch at login), Dictionary, History, and About.

## 6. Dictation flow

States: `Idle`, `Recording`, `HandsFree`, `Processing`.

| State | Event | Result |
|---|---|---|
| Idle | hotkey down | Start recording. Go to Recording. |
| Recording | hotkey up, held 300 ms or longer | Stop. Go to Processing. |
| Recording | hotkey up, held under 300 ms | Keep recording for 400 ms. A second hotkey down in that window goes to HandsFree. Otherwise discard and go to Idle. |
| Recording | another key pressed while hotkey held | The user is using the key as a modifier. Discard silently. Go to Idle. |
| HandsFree | hotkey down | Stop. Go to Processing. |
| Recording, HandsFree | Escape | Discard. Go to Idle. Escape is swallowed only in these states. |
| Recording, HandsFree | 10 minutes elapsed | Stop. Go to Processing. |
| Processing | hotkey down | Ignored. The pill pulses. |
| Processing | pipeline finished | Insert text, save history. Go to Idle. |

Recording starts on the first key down in every case, so no speech is lost while Lucid
works out whether the press is a hold or a double-tap.

Before transcription, a recording shorter than 0.3 s or with no audio above the noise
floor is dropped with the message "Didn't catch that". This also stops Whisper inventing
text from silence.

## 7. Cleanup pipeline

### Stage 1: rules (instant, deterministic)

- Remove non-speech tags such as `[BLANK_AUDIO]` and `(silence)`.
- Remove unambiguous fillers when they stand alone: um, umm, uh, uhh, uhm, er, erm, hmm.
- Collapse an immediately repeated function word ("the the", "I I I think"). Genuine
  doubles such as "had had" and "that that" are kept.
- Turn "new line" and "new paragraph" into line breaks when spoken as their own clause.
- Repair the punctuation, spacing and capitalisation left behind by removals.

### Stage 2: local LLM

Handles what needs understanding: fillers that are sometimes real words ("like", "you
know", "I mean"), false starts, self-corrections ("at 2, actually 3" becomes "at 3"),
punctuation, and spoken lists.

Contract:

- The transcript is passed inside a delimited block and treated as data. A dictated
  question is cleaned, never answered.
- The model returns only the edited text.
- Edit, do not rewrite. Ambiguous corrections are left as spoken.
- When the cursor is mid-sentence, the prompt says so, and the model keeps the first
  word lower case unless it is a name.
- Temperature 0. Output length is capped relative to the input.
- The fixed part of the prompt (rules and worked examples) comes first so
  `llama-server` caches it. Level, style, dictionary terms and the transcript come last.

The LLM is skipped when the level is Off, or when the rules output has five words or
fewer and contains no correction marker or ambiguous filler.

### Stage 3: guardrails

The LLM result is rejected, and the rules output used instead, when any of these hold:

| Check | Initial threshold |
|---|---|
| Empty output | always |
| Timeout | 2.5 s plus 40 ms per input word |
| Grew | output has more than 1.2 × input words plus 5 |
| Invented or reordered words | more than 15% of output words cannot be lined up, in order, with the input (35% at Medium). One word is always allowed. |
| Over-deleted | output has under 30% of input words (Light only, not applied at Medium) |
| Dropped words | a stretch of meaningful words is missing, and no correction, restart or joined word explains it (Light only) |

Known wrappers such as quotation marks, code fences and "Here is the cleaned text:" are
stripped before the checks. Thresholds are constants tuned against the test set in build
step 3.

### Stage 4: dictionary

Whole-word, case-insensitive replacement of each "misheard → correct" pair. Longest match
wins. The saved capitalisation is used.

### Stage 5: style rules

The focused app's bundle identifier maps to one of four categories using a built-in
table. The category is resolved before the pipeline runs. It shapes the LLM prompt in
stage 2, and the deterministic effects below are applied last.

| Category | Examples | Effect |
|---|---|---|
| email | Mail, Outlook | Complete sentences and paragraphs. |
| chat | Slack, Teams, Messages, WhatsApp, Discord | Casual. A message of one or two sentences loses its closing full stop. |
| code | Terminal, iTerm, VS Code, Cursor, Claude, ChatGPT | Fillers and corrections removed. No list or paragraph formatting. Technical terms kept verbatim. |
| other | everything else | Default. |

### Cleanup levels

| Level | Rules | LLM | What changes |
|---|---|---|---|
| Off | tags and line-break commands only | no | Nothing else. Verbatim. |
| Light | yes | yes | Fillers, false starts, self-corrections, punctuation, lists. Every other word kept. |
| Medium | yes | yes | Light, plus tightening of wordy phrasing and grammar. Meaning and tone kept. Nothing added. Needs the optional general model. |

## 8. Storage

Everything is under `~/Library/Application Support/Lucid/`:

- `models/`: the speech and LLM model files.
- `dictionary.json`: custom terms and replacement pairs.
- `history.json`: the last 200 dictations.
- `recordings/`: audio for the last 20 dictations, deleted after 7 days.
- `engines.pid`: process IDs of the running helpers.

Settings are in `UserDefaults` under `com.siliconspider.lucid`. Logs go to
`~/Library/Logs/Lucid/lucid.log` and never contain transcript text.

## 9. Error handling

| Situation | Behaviour |
|---|---|
| Microphone permission missing | Pill explains. Menu item opens the right System Settings pane. |
| Accessibility permission missing | Hotkey cannot work. Onboarding window opens at launch until granted. |
| Engine binaries or models missing | Menu shows "Setup needed" with the command to run. |
| Engine not ready or crashed | Pill says "Starting up". Supervisor restarts it. The recording is kept for retry. |
| Transcript empty | "Didn't catch that". Nothing inserted. |
| LLM slow, failed or rejected | Rules output is inserted. The reason is recorded in history. |
| Secure field or no text field | Text left on the clipboard. Pill says "Copied. Press ⌘V". |
| Fn key bound to a system action | Onboarding detects the setting and shows how to set it to "Do Nothing", or offers another key. |

The principle throughout: a dictation is never lost. If a later stage fails, the output
of the last stage that worked is used, and the original is always in history.

## 10. Performance and model selection

Target, measured from end of speech to text inserted:

| Utterance | Median | 90th percentile |
|---|---|---|
| Five words or fewer | 1.0 s | 1.5 s |
| About 40 words (15 s of speech) | 1.5 s | 3.0 s |

Every dictation records per-stage timings in history, so real-world figures are visible.

The models were chosen by measurement. The numbers, the method and the weaknesses found
are in [`docs/benchmarks.md`](../../benchmarks.md).

- **Speech**: Whisper large-v3-turbo, quantised (547 MB). Clips up to 14 seconds use half
  of Whisper's audio window, which halves the time with the same text.
- **Cleanup at Light**: S1-mini by Superwhisper (462 MB), a small model trained to clean
  speech transcripts. It scored 50 of 51 on the test set with a median of 99 ms, and was
  the highest-scoring model that met the latency target. It takes its own input format
  and has no input for dictionary terms or the mid-sentence flag, so those are handled
  by the rules that run after it.
- **Cleanup at Medium**: Qwen 3.5 4B (2.6 GB) with Lucid's own prompt. S1-mini is not
  built to tighten wording. Qwen scored 51 of 51 but is about seven times slower, so it
  is an optional download and is used only for Medium.

Measured end to end with S1-mini: about 0.6 s for a five-word phrase and 1.0 to 1.2 s for
a 14-second dictation, against targets of 1.0 s and 1.5 s. Dictations over about 30
seconds exceed the 3.0 s ceiling: a 35-second one takes about 3.2 s.

Gemma 4 E4B and Phi-4 Mini were listed as candidates and were not tested. Gemma's file is
4.9 GB, larger than Qwen's, and Phi-4 Mini is older than the models that were tested.

## 11. Testing

- **Unit tests** for all of `LucidCore`, run by the `LucidCoreTests` executable. It exits
  non-zero on any failure. `scripts/test.sh` runs it.
- **Cleanup test set** in `evals/cases.json`. Each case has an input transcript, a level,
  an app category, and checks: text that must appear, text that must not, and optionally
  an exact expected output. Groups: fillers, self-corrections, false starts, text that
  must not change, dictated questions and instructions that must not be acted on, lists,
  punctuation, dictionary terms, long rambles. `lucid-cli eval` runs it and prints a
  score per group.
- **End-to-end** with synthesised speech: `say` produces audio containing fillers and
  corrections, and `lucid-cli dictate <file>` runs the whole pipeline on it.
- **Manual checklist** for what cannot be automated: live microphone, the hotkey, pasting
  into Mail, Slack, a browser and a terminal.

## 12. Build steps

Each step ends with a commit pushed to `main`. Steps 2 and 3 are built in the opposite
order: the cleanup core needs no downloads, so it goes first.

1. This spec.
2. Engines: setup script, model downloads, supervisor, HTTP clients, and the benchmark
   that picks the models.
3. Cleanup core: rules, prompt, guardrails, dictionary, style rules, unit tests, the test
   set, and `lucid-cli`.
4. The app: hotkey, recording, pill, insertion, menu. First usable dictation.
5. Dictionary editor, history, settings window.
6. Hands-free mode, onboarding, launch at login, README.

## 13. Risks

| Risk | Mitigation |
|---|---|
| Local cleanup is slower than the target. A comparable open-source app reports 1 to 7 s for this stage. | Measured in step 2 before the app is built. Prompt caching, the short-utterance skip and model choice are the levers. |
| A small model over-edits or answers the dictation. | Conservative prompt, guardrails, and a test group dedicated to it. The rules output is always available. |
| Ad-hoc code signing makes macOS forget permissions after each rebuild. | Step 4 sets up a stable local signing identity. Failing that, permissions are re-granted after a rebuild. |
| The Homebrew packages may not include the server binaries. | The setup script checks, and builds from source if needed. |
| Pasting fails in an unusual app. | Clipboard fallback with a visible message. |
