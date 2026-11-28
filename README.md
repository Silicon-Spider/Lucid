# Lucid

Hold a key, speak, let go. Clean text appears where your cursor is, in any app, on a Mac,
a Windows PC or a Linux desktop.

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

The Linux app is the newest. A program runs the whole of it, with the real engines, on a
desktop that exists only in memory: it holds the key, speaks a sentence in a synthesised
voice, and checks that the cleaned sentence is typed into an editor. Nobody has yet used it
on a real desktop with a real microphone, and what it does in a Wayland session has only
been tried with stand-ins for the keyboard. See [what differs on Linux](#linux).

## Get Lucid

Download the one for your computer from the
[latest release](https://github.com/Silicon-Spider/Lucid/releases/latest). Each has the
speech and cleanup engines inside it, so there is nothing to build and no terminal to open.
Lucid needs about 1.1 GB of disk for its models, and about 2.5 GB of memory while it runs.

**Windows 10 or 11**: `Lucid-…-windows-x64.zip`

1. Right-click the download and choose **Extract All**. Put the Lucid folder somewhere it
   can stay, such as Documents.
2. Open the folder and open **Lucid**. Windows says it protected your PC, because Lucid is
   not signed: choose **More info**, then **Run anyway**.
3. Lucid appears beside the clock, and adds itself to the Start menu for next time.

**A Mac with Apple Silicon, macOS 14 or later**: `Lucid-…-mac-arm64.zip`

1. Open the download to unpack it, and drag **Lucid** to Applications.
2. Open it. macOS says it could not check Lucid, because it is not signed with a
   certificate from Apple: open System Settings, Privacy & Security, scroll down, and press
   **Open Anyway**.
3. Lucid appears in the menu bar. Its window asks for the microphone and for Accessibility:
   see [the Setup list](#the-setup-list-on-a-mac).

**Ubuntu, Debian and their relatives**: `lucid_…_amd64.deb`

1. Open the download and press **Install**.
2. Open **Lucid** from your applications menu. It appears in the panel.

**Any other Linux**: `Lucid-…-linux-x64.tar.gz`

1. Unpack it, and put the Lucid folder somewhere it can stay.
2. Open **Lucid** in that folder. In some file managers that is a double click, in others a
   right click and **Run as a Program**. It adds itself to your applications menu.

**Then, on any of them**, Lucid's window opens at Home. Press **Download Models** there. That
is about 1 GB, once. When every item under Setup is ticked, hold the dictation key and speak.

In a Wayland session on Linux, which is what Ubuntu and Fedora start by default, Home has
one more button: **Allow Lucid to Use the Keyboard…**. Press it and give your password.
[Linux](#linux) says what that allows, and why it is needed.

The downloads are made by GitHub Actions from this repository, and each is tried there
before it is published: unpacked or installed on a computer that has never had Swift or the
engines, and started. None is signed, which is why Windows and macOS ask you to confirm.

## Build it yourself

Lucid can also be built from its source, which is what the rest of this section and the
sections on [Windows](#windows) and [Linux](#linux) describe. On a Mac that needs:

- A Mac with Apple Silicon, running macOS 14 or later.
- [Homebrew](https://brew.sh).
- The Swift compiler. `xcode-select --install` provides it. Xcode is not needed.

```bash
git clone https://github.com/Silicon-Spider/Lucid.git
cd Lucid
scripts/setup.sh        # installs the engines, downloads the models (about 1 GB)
scripts/build-app.sh    # builds dist/Lucid.app
open dist/Lucid.app
```

After that, Lucid opens like any other app: double-click `dist/Lucid.app` in the Finder, or
drag it to Applications first. On [Windows](#windows) and [Linux](#linux), the setup script
adds it to the Start menu or the applications menu.

### The Setup list on a Mac

A waveform icon appears in the menu bar, and Lucid's window opens at Home. Its Setup list
walks you through four things:

1. **Microphone.** Allow it when asked.
2. **Accessibility.** Switch Lucid on in System Settings, Privacy & Security,
   Accessibility. Lucid needs this to see the dictation key and to type for you. If the
   list then offers Restart Lucid, press it.
3. **Speech engines and models.** A downloaded Lucid has its engines inside, and one you
   built gets them from `scripts/setup.sh`. The list can download the models.
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

[Get Lucid](#get-lucid) has the download, which needs Windows 10 or 11 on a 64-bit PC. To
build it yourself instead, install [Swift](https://www.swift.org/install/windows) 6.2 or
later, then in PowerShell:

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
- Speech recognition runs on the processor alone, not the graphics card, so Lucid's usual
  speech model is slow on a PC: about 14 seconds for a short sentence on the four-core
  machine that tests it. A smaller model is much faster and still good for clear
  speech. Download **Whisper base.en** or **Whisper small.en** under Models and choose it
  there, or set up with `scripts\setup.ps1 -SpeechModel ggml-base.en.bin`.

`scripts\setup.ps1` puts whisper.cpp and llama.cpp in folders of their own inside Lucid's
engines folder, which `lucid-cli folder engines` prints. `lucid-cli` works on Windows too,
on recordings: `scripts\integration.ps1` runs the whole pipeline on synthesised speech.

## Linux

Lucid for Linux sits in the panel. Hold **Right Ctrl** and speak, then let go: the text is
pasted into the app you are in, terminals included. Tap the key twice to keep recording
hands-free, and press Escape to cancel. The pill at the bottom of the screen shows the
microphone level and the last words heard.

[Get Lucid](#get-lucid) has the downloads, which need a 64-bit Linux desktop as recent as
Ubuntu 22.04. To build it yourself instead, you need
[Swift](https://www.swift.org/install/linux), and git, curl, cmake and a C++ compiler to
build the speech engine. The app is built on GTK. On Ubuntu or Debian:

```bash
sudo apt-get install libgtk-3-dev libxi-dev libxtst-dev libayatana-appindicator3-1 cmake g++ git curl
```

```bash
git clone https://github.com/Silicon-Spider/Lucid.git
cd Lucid
scripts/setup-linux.sh    # the engines, the models (about 1 GB), the app, and a menu entry
```

On another kind of Linux, `scripts/setup-linux.sh` names the packages it is missing.

Then open **Lucid** from your applications menu, as you would any other app: no terminal is
needed again. The first time, its window opens, and Home lists anything that is still
missing. After that it stays out of the way. Click its icon in the panel for the cleanup
level, the dictation key, recent dictations, and **Open Lucid…**. Settings has a switch to
open it when you sign in.

The window has the same parts as on the Mac. What differs:

- **Wayland.** A Wayland session does not show an app the keys you press in other apps, and
  does not let one app press keys in another. So there, out of the box, the dictation key
  does nothing, and Home says so. There are two ways round it. Sign in with an X11 session
  (“Ubuntu on Xorg”, “Plasma (X11)”), where everything works as described. Or press
  **Allow Lucid to Use the Keyboard…** on Home and give your password. That lets the
  programs you run read the keyboards and make one of their own: Lucid then sees the key and
  can paste. It is the same access every program has in an X11 session. It is one file,
  `/etc/udev/rules.d/70-lucid.rules`, and deleting that file undoes it.
  `scripts/setup-linux.sh --allow-keys` does the same from a terminal.
- **The icon.** Lucid's icon needs a panel that shows app indicators, and the library that
  talks to it. Ubuntu, KDE, XFCE and Cinnamon have both. GNOME elsewhere needs the
  “AppIndicator and KStatusNotifierItem Support” extension. Without an icon Lucid still
  works: open it again from the applications menu and its window comes up.
- The dictation key is Right Ctrl, Right Alt or Right Shift.
- Lucid pastes with Shift+Insert, which works in terminals where Ctrl+V does not. For that
  it also puts the text where a terminal pastes from, the selection.
- If text was on the clipboard, it is put back after the paste. A copied picture or file is
  not: it is gone from the clipboard after a dictation.
- Escape cancels a recording, but Lucid cannot keep it from the app in front, which gets it
  too.
- Lucid cannot tell a password box from any other, so do not dictate into one.
- Linux does not say what is before the cursor, so Lucid cannot add the space between your
  last word and the dictation. Type it yourself.
- The window is a page that Lucid serves to this computer only. With Chromium, Chrome, Edge,
  Brave or Vivaldi installed, it opens in a window of its own, in a profile apart from your
  browsing. Otherwise it opens as a tab in your usual browser. Set `LUCID_BROWSER` to choose.
- Recording is done by `parec`, `pw-record` or `arecord`, whichever is installed, from the
  microphone chosen in your sound settings.
- Speech recognition runs on the processor alone, so Lucid's usual speech model is slow.
  Choose **Whisper base.en** or **Whisper small.en** under Models, or set up with
  `scripts/setup-linux.sh --speech-model ggml-base.en.bin`.
- Building prints a warning about “prohibited flags: -pthread”. It comes from the way GTK
  describes itself and does no harm.

Without GTK installed, as on a server, `swift build` leaves the app out and builds
`lucid-cli` and the tests. `scripts/setup-linux.sh --no-app` sets that up, and
`lucid-cli window` opens Lucid's window as a page in a browser, for the models, dictionary,
history and settings.

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
- builds the Linux app and runs the unit tests on Linux. Then, on a desktop that exists
  only in memory, it runs the tests of the part that talks to the desktop
  (`Tests/CLucidDeskTests/linux.c`): the dictation key, typing into another program's window
  and into a terminal, the clipboard, the tray menu, the pill, recording from a made-up
  microphone, and what Lucid does instead in a Wayland session. Last, it starts the app with
  `--self-test`. The pictures are in the `linux` download.
- on Linux, runs `scripts/setup-linux.sh` and `scripts/integration-linux.sh`: the whole app
  with the real engines. It holds the dictation key, says a sentence into the made-up
  microphone in a synthesised voice, and checks that the cleaned sentence is typed into an
  editor. Pictures of the screen while it speaks are in the `linux-app` download.
- builds the Windows app and runs the unit tests on Windows. Then it runs the tests of the
  part that talks to Windows (`Tests/CLucidDeskTests/windows.c`): pressing the dictation key, typing
  into another program's window, the clipboard, the tray menu and the pill. Last, it starts
  the app with `--self-test`. Pictures of the pill and the tray icon as Windows drew them
  are in the `windows` download under Artifacts.
- on Windows, runs `scripts\setup.ps1` and `scripts\integration.ps1`: the real engines and
  models, turning synthesised speech into clean text.

A second workflow, [`.github/workflows/packages.yml`](.github/workflows/packages.yml), makes
the [downloads](#get-lucid) with `scripts/package-linux.sh`, `scripts\package-windows.ps1`
and `scripts/package-mac.sh`, and tries each one where neither Swift nor the engines have
ever been. On Linux it installs the package on Ubuntu 22.04 and 24.04 and dictates with what
was installed. On Windows it starts the unpacked app with only Windows' own folders to look
in. On a Mac it checks that the app finds the engines inside itself and that they start. For
a tag such as `v0.1.0` it attaches the downloads to the release of that name, so publishing
a release on GitHub, with a new tag, is all it takes to put out a version.

On a Linux computer, `scripts/test-linux-layer.sh` and `scripts/integration-linux.sh` run
those checks of the Linux app, and `scripts/test-windows-layer.sh` runs the tests of the
Windows part under Wine. None of them touches your desktop: each makes one of its own.

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

On Linux, in an X11 session: use any text editor for step 1, skip step 2, the pill in step
6 says "Copied. Press Ctrl+V", Lucid is opened from the applications menu and quit from its
icon in the panel, and step 9 is the same command. Also dictate into a terminal: the text
appears at the prompt.

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
| On Linux, the key does nothing | Open Lucid from the applications menu: Home says why. In a Wayland session it is expected, and Home says what to do. |
| On Linux, there is no icon in the panel | The panel does not show app indicators. Open Lucid again from the applications menu to get its window, or add the extension named under [Linux](#linux). |
| On Linux, the text is copied but not typed | In a Wayland session Lucid may not press keys until you allow it: see [Linux](#linux). Press Ctrl+V, or Ctrl+Shift+V in a terminal. |
| Something else | Engine logs are in `~/Library/Logs/Lucid/` on a Mac, in `%LOCALAPPDATA%\Lucid\logs` on Windows, and in `~/.local/share/Lucid/logs` on Linux. They never contain what you said. |

## Limits

- English only.
- The Windows and Linux apps have had far less use than the Mac app. See what differs on
  [Windows](#windows) and on [Linux](#linux).
- The downloads are not signed, so Windows and macOS ask you to confirm before they open
  Lucid the first time. On a Mac, each new version needs Accessibility switched off and on
  again for Lucid in System Settings, because macOS ties that permission to the exact build.
- On Linux in a Wayland session, the dictation key and pasting only work once you allow
  them, as [Linux](#linux) explains.
- Lucid uses the computer's default microphone. Change it in the system's sound settings.
- Pasting uses ⌘V, or Ctrl+V on Windows, so it assumes a keyboard layout where that works.
  On Linux it uses Shift+Insert, which is the same on every layout.
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
