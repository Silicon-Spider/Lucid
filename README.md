# Lucid

Hold a key, speak, let go. Clean text appears where your cursor is, in any app, on a Mac
or a Windows PC.

Lucid removes the "um"s, the false starts and the "no wait, I meant…" before the text
lands, so what you get reads as if you had typed it. Everything runs on your own computer.
No audio and no text is sent anywhere.

| You say | Lucid writes |
|---|---|
| "Um, so I was thinking we could, uh, meet at two, actually no, make that three, at the usual place." | So I was thinking we could meet at 3 at the usual place. |
| "What is the capital of France, and, um, what is its population?" | What is the capital of France, and what is its population? |

The second row matters: Lucid cleans a dictated question. It never answers it.

## Status

This is a first version. The speech and cleanup pipeline is tested and measured, with
results in [`docs/benchmarks.md`](docs/benchmarks.md). The parts that need a person at
the keyboard (the dictation key, the microphone, pasting) were built carefully but have
only been checked by hand-run steps, listed under [Check it works](#check-it-works).

The Windows app is newer than the Mac app. Its parts are tested by programs on Windows: the
dictation key, typing into another program's window, the clipboard, the pill and the tray
icon. Nobody has yet used it for a day's work on a real PC with a real microphone, so
expect rough edges, and see [what differs on Windows](#windows).

## Requirements

These are for the Mac. For a PC, see [Windows](#windows). On Linux the command-line tool
works: see [Linux](#linux).

- A Mac with Apple Silicon, running macOS 14 or later.
- [Homebrew](https://brew.sh).
- The Swift compiler. `xcode-select --install` provides it. Xcode is not needed.
- About 1.1 GB of disk for the models, and about 2.5 GB of memory while Lucid runs.

## Install

```bash
git clone https://github.com/Silicon-Spider/Lucid.git
cd Lucid
scripts/setup.sh        # installs the engines, downloads the models (about 1 GB)
scripts/build-app.sh    # builds dist/Lucid.app
open dist/Lucid.app
```

A waveform icon appears in the menu bar, and Lucid's window opens at Home. Its Setup list
walks you through four things:

1. **Microphone.** Allow it when asked.
2. **Accessibility.** Switch Lucid on in System Settings, Privacy & Security,
   Accessibility. Lucid needs this to see the dictation key and to type for you. If the
   list then offers Restart Lucid, press it.
3. **Speech engines and models.** Ticked once `scripts/setup.sh` has run. If only the models
   are missing, the list can download them.
4. **The dictation key.** On a MacBook this is Fn. macOS also uses Fn for its own
   shortcut, so set "Press 🌐 key to" to "Do Nothing" in Keyboard settings, or choose
   Right Option in the list.

To keep Lucid, move `dist/Lucid.app` to your Applications folder.

**After rebuilding.** The app is signed locally, and macOS ties the Accessibility grant
to the exact build. After running `scripts/build-app.sh` again, switch Lucid off and on
in the Accessibility list.

## Use

| Do this | To |
|---|---|
| Hold the dictation key, speak, let go | Dictate |
| Tap the key twice | Keep recording hands-free. Press the key once to finish. |
| Press Escape while recording | Cancel |
| Say "new line" or "new paragraph" as its own phrase | Start a new line or paragraph |

A small pill at the bottom of the screen shows bars while it listens and dots while it
works. If there is nowhere to type, the text is left on the clipboard and the pill says so.

While you speak, the pill also shows the last few words Lucid has heard, about once a
second. This is a rough first hearing. The text that is inserted is worked out from the
whole recording once you stop, and then cleaned up. It can add a moment to the wait after
you let go, so you can switch it off under Settings.

### Lucid's window

Everything else is in one window. Choose Open Lucid from the menu-bar icon. Its parts are
listed down the left:

| Part | What it is for |
|---|---|
| Home | Whether Lucid is ready, the Setup list, what is in use, and your latest dictation. |
| Models | Choose, download, add, rename and delete the speech and cleanup models. |
| Dictionary | Words to spell exactly, and corrections. |
| History | Past dictations, each with its original wording. |
| Settings | The dictation key, the cleanup level, recordings, and opening at login. |
| About | The version, and what Lucid is built with. |

### Cleanup levels

Choose one from the menu, or under Settings in Lucid's window.

| Level | What it does |
|---|---|
| Off | Inserts exactly what you said. |
| Light (default) | Removes fillers, false starts and corrections. Fixes punctuation. Formats spoken lists. Keeps every other word. |
| Medium | Also tightens wordy phrasing. Slower. Needs an extra 2.6 GB model: download Qwen 3.5 4B under Models, or use [one of your own](#your-own-models). |

Lucid also adapts to where you are typing. In chat apps a short message loses its closing
full stop. In terminals, editors and AI chat apps it does not format lists.

### Your words

Under Dictionary:

- **Words to spell exactly**: names, products and jargon, such as GitHub.
- **Corrections**: when Lucid keeps mishearing something, say what to write instead.

### Your own models

Lucid comes with its own models, and you can add others. Under Models:

- **Download from Hugging Face** lists Lucid's own models and a few others worth trying,
  each with a Download button. **Download Another Model…** takes the name of any public
  model on Hugging Face, such as `ggerganov/whisper.cpp`, or a link to it, and lists the
  files Lucid can use.
- **Add Speech Model…** takes a Whisper model for whisper.cpp, such as `ggml-small.en.bin`
  from [huggingface.co/ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp).
  A smaller model is faster but mishears more.
- **Add Cleanup Model…** takes an instruction-following model as a single `.gguf` file, the
  kind llama.cpp runs.
- Then choose the speech model, and the cleanup model for Light and for Medium. Medium needs
  a model that takes Lucid's own prompt.

To rename a model, press its pencil button and type a name of your own, such as "Quick and
rough". This changes the name Lucid shows, not the file. An empty name puts the original
back.

To delete a model, Lucid's own included, press its trash button. If Lucid was using it, the
confirmation says what takes its place, and an unfinished download can be discarded the
same way.

Lucid checks each file before adding it, and keeps its own copy in its models folder. It
refuses a file that is not a model, a vision add-on (`mmproj`), an adapter, or a model split
into several files. Each cleanup model you add has a prompt format: Lucid's prompt, for any
instruction model, or the S1-mini format, for another copy of S1-mini.

Downloads come straight from huggingface.co, and Lucid sends nothing else. It only
downloads public models: for a gated one, accept its licence on huggingface.co, download
the file in your browser, and add it. A download that stops continues where it left off,
including one that `scripts/setup.sh` started.

A model you add goes through the same guardrails as Lucid's own. If its reply adds words,
answers a question or drops part of what you said, the rules output is used instead.

### History

History lists your dictations. Each one keeps its original wording, so you can always get
back what you actually said. A dictation that failed can be retried from its recording. The
last 20 recordings are kept for 7 days. You can switch that off under Settings.

## How it works

```
hold key ─▶ record ─▶ Whisper (speech to text) ─▶ rules ─▶ S1-mini (cleanup)
                                                              │
                         paste at cursor ◀─ your dictionary ◀─ guardrails
```

1. **Speech to text.** Whisper large-v3-turbo, run by whisper.cpp.
2. **Rules.** Instant, exact edits: plain fillers, stutters, spoken line breaks.
3. **Cleanup.** S1-mini by Superwhisper, a small model trained for exactly this job, run
   by llama.cpp.
4. **Guardrails.** Lucid checks the model's work. If it added words, answered a question,
   or dropped part of what you said, its reply is thrown away and the rules output is
   used instead. A dictation is never lost.

Measured on an M4 MacBook Air: about 0.6 s for a short phrase and about 1 s for a
14-second dictation, from letting go of the key to seeing the text. Dictations longer
than about 30 seconds take over 3 s.

The design draws on how Wispr Flow and Google's Rambler work. The research is in
[`docs/research.md`](docs/research.md) and the full design in
[`docs/superpowers/specs`](docs/superpowers/specs).

## Command line

`lucid-cli` runs the same pipeline without the app:

```bash
swift run lucid-cli doctor                         # are the engines and models installed?
swift run lucid-cli clean "um, so, like, hello"    # clean up some text
swift run lucid-cli dictate recording.wav          # audio to clean text, with timings
swift run lucid-cli eval                           # run the cleanup test set
swift run lucid-cli models                         # list the models Lucid has
swift run lucid-cli add-model ggml-small.en.bin    # add a model of your own
swift run lucid-cli download ggerganov/whisper.cpp # list a Hugging Face model's files
swift run lucid-cli download ggerganov/whisper.cpp ggml-base.en.bin
swift run lucid-cli remove-model ggml-base.en.bin  # delete a model
swift run lucid-cli rename-model ggml-base.en.bin "Quick and rough"
swift run lucid-cli folder models                  # where Lucid keeps its models
swift run lucid-cli dictate --speech-model ggml-small.en.bin recording.wav
swift run lucid-cli eval --model my-model.gguf     # try a cleanup model on the test set
```

Audio files must be 16 kHz mono 16-bit WAV.

## Windows

Lucid for Windows sits beside the clock. Hold **Right Ctrl** and speak, then let go: the
text is pasted into the app you are in. Tap the key twice to keep recording hands-free, and
press Escape to cancel. The pill at the bottom of the screen shows the microphone level and
the last words heard.

It needs Windows 10 or 11 on a 64-bit PC, about 1.1 GB of disk for the models, and
[Swift](https://www.swift.org/install/windows) 6.2 or later to build it. In PowerShell:

```powershell
git clone https://github.com/Silicon-Spider/Lucid.git
cd Lucid
scripts\setup.ps1    # the engines, the models (about 1 GB), the app, and a Start menu entry
```

Then open Lucid from the Start menu. The first time, its window opens, and Home lists
anything that is still missing. After that it stays out of the way: right-click its icon
beside the clock for the cleanup level, the dictation key, recent dictations, and
**Open Lucid…**. If the icon is not there, it is behind the **^** arrow.

The window has the same parts as on the Mac: Home, Models, Dictionary, History, Settings
and About. Models can be downloaded from Hugging Face, added from a file, renamed and
deleted there.

What differs from the Mac:

- The dictation key is Right Ctrl, Right Alt or Right Shift.
- The window is a page that Lucid serves to this PC only, shown by Microsoft Edge in a
  window of its own. Every request from the page needs a key that only that window was
  given, and Edge keeps the window in a profile apart from your own browsing. To use another
  browser built on Chromium, set `LUCID_BROWSER` to its path.
- Windows does not tell Lucid what is before the cursor, so Lucid cannot add the space
  between your last word and the dictation. Type it yourself.
- Lucid recognises the password boxes of ordinary Windows programs and does not paste
  there. It cannot recognise one drawn by a browser, so do not dictate with the cursor in a
  web page's password box.
- While a program that runs as administrator is in front, Windows keeps the keyboard from
  Lucid: the key does nothing there, and Lucid cannot paste into it.

`scripts\setup.ps1` puts whisper.cpp and llama.cpp in folders of their own inside Lucid's
engines folder, which `lucid-cli folder engines` prints. `lucid-cli` works on Windows too,
on recordings: `scripts\integration.ps1` runs the whole pipeline on synthesised speech.

## Linux

There is no app for Linux. Everything underneath the apps runs there through `lucid-cli`:
speech to text, cleanup with its guardrails, your dictionary, and downloading, renaming
and deleting models. You give it a recording and it gives you clean text.

Put `whisper-server` and `llama-server` on the PATH, or in folders of their own inside the
engines folder, and download the models with `lucid-cli download`. `lucid-cli doctor` says
what is missing and where it is expected. `lucid-cli window` opens Lucid's window as a page
in your browser, for the models, dictionary, history and settings.

## Check it works

```bash
scripts/test.sh           # unit tests
scripts/integration.sh    # the whole pipeline on synthesised speech
```

**CI.** On every pull request, and on every push to `main`, GitHub Actions
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)):

- builds Lucid on a Mac, runs the unit tests, and draws the app's windows with
  `Lucid --render-ui`. The drawings are PNG files in the `ui` download under Artifacts, on
  the run's page.
- builds `lucid-cli` and runs the unit tests on Linux.
- builds the Windows app and runs the unit tests on Windows. Then it runs the tests of the
  part that talks to Windows (`Tests/CLucidWinTests`): pressing the dictation key, typing
  into another program's window, the clipboard, the tray menu and the pill. Last, it starts
  the app with `--self-test`. Pictures of the pill and the tray icon as Windows drew them
  are in the `windows` download under Artifacts.
- on Windows, runs `scripts\setup.ps1` and `scripts\integration.ps1`: the real engines and
  models, turning synthesised speech into clean text.

`scripts/test-windows-layer.sh` runs the same tests of the Windows part on Linux, under
Wine, with a made-up microphone that plays a tone.

The Mac's own end-to-end check, `scripts/integration.sh`, is not part of CI. Run it by hand.

Then by hand, with Lucid running:

1. Open Notes. Hold the key and say "Um, so let's meet at two, actually three". Let go.
   "So let's meet at 3." appears.
2. Type a word with no space after it, then dictate. A space is added first.
3. Hold the key and press Escape. Nothing is inserted.
4. Tap the key twice, speak, then press it once. The text appears.
5. Hold the key and say nothing. The pill says "Didn't catch that".
6. Click the Desktop, then dictate. The pill says "Copied. Press ⌘V".
7. Open Lucid from the menu. Under Models, download Whisper base.en and choose it. The
   progress bar fills, the page says the engines are running with these models, and
   dictation still works.
8. Press the pencil beside it, name it "Quick and rough", and save. The new name shows in the
   list and in the speech model picker. Then delete it with its trash button.
9. Quit Lucid. `pgrep -f "whisper-server|llama-server"` prints nothing.

On Windows the steps are the same, with these differences: use Notepad for step 1, skip
step 2, the pill in step 6 says "Copied. Press Ctrl+V", Lucid is opened and quit from its
icon beside the clock, and in step 9 Task Manager shows no `whisper-server` or
`llama-server`.

## Troubleshooting

| Problem | Try |
|---|---|
| The key does nothing | Open Lucid from the menu. Home shows what is missing. Accessibility is the usual cause, especially after a rebuild. |
| Holding Fn opens the emoji picker or changes keyboard | Set "Press 🌐 key to" to "Do Nothing" in Keyboard settings, or switch to Right Option. |
| The menu says "Setup needed" | Open Lucid from the menu. Home says what is missing. Download the models there, or run `scripts/setup.sh` if the engines are missing, then quit and reopen Lucid. |
| The first word is cut off | The microphone takes a moment to start. Pause briefly after pressing the key. |
| Text goes to the clipboard instead of being typed | The focused control is not a text field, or it is a password field. Press ⌘V where you want it. |
| A download stops or fails | Press Download again. It continues where it stopped. For a gated model, download it in your browser and add the file. |
| A model you added does not start | Models, in Lucid's window, says why. Choose Lucid's own model to go back. The engine logs say more. |
| On Windows, the key does nothing | Look for Lucid's icon beside the clock, behind the **^** arrow if need be. If it is missing, open Lucid from the Start menu. If a program that runs as administrator is in front, Windows keeps the key from Lucid. |
| On Windows, the window does not open | Lucid's window needs Microsoft Edge, or another browser built on Chromium: set `LUCID_BROWSER` to its path. |
| On Windows, nothing is heard | Home, in Lucid's window, says whether Windows has a microphone and lets apps use it, with a button to the right page of Settings. |
| Something else | Engine logs are in `~/Library/Logs/Lucid/` on a Mac and in `%LOCALAPPDATA%\Lucid\logs` on Windows. They never contain what you said. |

## Limits

- English only.
- There are apps for the Mac and for Windows. On Linux only `lucid-cli` works, on recordings.
- The Windows app has to be built from source, and has had far less use than the Mac app.
  See [what differs on Windows](#windows).
- Lucid uses the computer's default microphone. Change it in System Settings, Sound, or in
  Windows' Sound settings.
- Pasting uses ⌘V, or Ctrl+V on Windows, so it assumes a keyboard layout where that works.
- Speech recognition was measured with synthesised speech, not a range of real voices and
  rooms. See [`docs/benchmarks.md`](docs/benchmarks.md) for what was and was not tested.

## Credits and licence

Lucid is free software under the [GNU General Public License, version 3](LICENSE).

It is built on:

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and OpenAI's Whisper large-v3-turbo, for speech recognition.
- [llama.cpp](https://github.com/ggml-org/llama.cpp), for running the cleanup models.
- [S1-mini by Superwhisper](https://huggingface.co/superwhisper/s1-mini-GGUF), the cleanup model.
- [Qwen 3.5 4B](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF), the optional model for the Medium level.

The models are downloaded by `scripts/setup.sh` and are not part of this repository. Each
has its own licence.
