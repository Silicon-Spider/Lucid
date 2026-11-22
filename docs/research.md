# Research: how Wispr Flow and Google Rambler work

Research for Lucid, gathered 22 November 2026. Wispr Flow findings come from Wispr's own
research posts and help centre. Rambler findings come from launch coverage and a beta
teardown, because Google has published little detail. Gaps are listed at the end.

## Wispr Flow

### Pipeline

1. Hold a global hotkey (Fn on Mac) and speak. Release to finish.
2. Audio goes to a cloud speech-recognition model. Recognition is conditioned on context:
   the speaker, surrounding text, and the personal dictionary.
3. The raw transcript goes to a cloud LLM (fine-tuned Llama, per the Baseten case study)
   that cleans and formats it.
4. The finished text is pasted into whatever text field has focus.

Flow is deliberately **not streaming**. Words do not appear as you speak. The whole
utterance is transcribed, understood, then written once, so the model can "wait,
understand, and then write what you meant".

### Latency

Wispr's stated budget is **700 ms from end of speech to text on screen**: under 200 ms for
speech recognition, under 200 ms for the LLM, and up to 200 ms of network. They optimise
tail latency (p99), not the average, and track the share of dictations that take over one
second. Their reasoning: "every edit after the fact adds more time than anything else", so
a slower, more accurate result beats a fast one that needs fixing.

### Cleanup behaviours

| Behaviour | Detail |
|---|---|
| Filler removal | Removes "um", "uh" and similar pauses. |
| Backtrack (self-correction) | Triggered by "actually", "scratch that", "never mind", or just restating. Removes the whole abandoned attempt. "Let's do coffee at 2 actually 3" becomes "Let's do coffee at 3." |
| Conservative by design | "I actually enjoyed the movie" is left alone. Ambiguous corrections are kept, not guessed. |
| Punctuation | Inferred from pauses and tone. Spoken punctuation ("comma", "new paragraph") wins over inferred. |
| Lists | "One… two…" or "first… second…" becomes a formatted list. |
| Paragraphs | Long dictations are split at topic shifts. |
| Cleanup level | None (verbatim), Light (fillers and grammar, the default), Medium (clarity and concision). |
| Tone per app | Formal, casual or excited, chosen by app category: email, work chat, personal messages, other. Casual styles drop the trailing full stop on short messages. |
| Code and AI tools | Dictation into coding terminals and AI chat apps skips formatting. |

### Context it reads

- The focused app, to pick a style.
- Selected text and the text around the cursor, to fix spacing, capitalisation and
  trailing punctuation when continuing mid-sentence.
- Surrounding text, to spell uncommon names correctly.

### Interaction design

- **Hold-to-talk** on one key is the primary interaction. A hands-free mode also exists.
- **The Flow Bar**: a small floating pill at the screen edge with three states: resting,
  recording, processing. It follows the display the cursor is on.
- **Recovery**: the original transcript is always kept. History offers "Undo AI edit" and
  "Retry transcript" (audio is kept for 14 days).
- **Graceful failure**: if formatting fails, the raw transcript is pasted instead.
- **Command Mode**: select text, hold a second hotkey, speak an instruction such as "make
  this more formal".

### Personalisation

- **Dictionary**: custom words and "misheard → correct" mappings. Whole-word matches,
  longest phrase wins, saved capitalisation is preserved. Learns automatically when you
  correct a spelling.
- **Snippets**: a spoken trigger ("my email signature") expands to saved text.

### Stated design principles

- Voice is invisible. Signal availability without noise.
- Understanding over streaming. Write what was meant, not what was said.
- Works anywhere, at the OS layer. No new app to switch to.
- Designed to be forgotten. Responsiveness matters more than visible feedback.
- Drive corrections toward zero, and never make the same mistake twice.

## Google Rambler

Rambler is the Gemini-powered dictation mode in Gboard, announced 12 May 2026 and shipped
on Pixel. It is the same idea as Flow, built into the keyboard.

- **Filler removal**: strips "um", "ah" and "you know".
- **Self-correction**: "Let's meet at 3 p.m… actually, make that 2 p.m." yields only the
  2 p.m. version.
- **Inline voice commands**: saying "add a smiling emoji at the end" performs the edit
  instead of typing the words.
- **Code-switching**: follows a speaker who changes language mid-sentence.
- **Personalisation** (beta teardown, not confirmed shipped): a "Contact names" toggle to
  spell names correctly, a "Remember corrected words" toggle, and an exportable "Voice
  correction list".
- **Processing**: "a combination of on-device and cloud-based processing". Google says it
  stores no voice recordings.
- **Main complaint**: at launch it did not learn. Users had to fix the same names and
  words every time. The correction-list features above are Google's response.

## What makes these apps good

The shared recipe, in order of importance:

1. **A second pass that understands the speech.** Speech recognition alone gives a
   stenographer's transcript. An LLM pass turns it into what you meant: no fillers, no
   false starts, self-corrections resolved, punctuation right.
2. **Conservative editing.** Both remove and tidy. Neither paraphrases. The speaker's
   words survive.
3. **Speed.** Text appears about a second after you stop. Slower than that and typing
   feels better.
4. **Works in every app.** One hotkey, text lands at the cursor.
5. **Nearly invisible UI.** A small indicator, nothing else.
6. **It learns your words.** The top complaint about Rambler was the lack of this.
7. **You can always get the original back.**

## Constraints found on this Mac

- Apple M4, 16 GB RAM, macOS 15.6.1, 50 GB free. Enough to run speech recognition and a
  small LLM on-device.
- Xcode is not installed. Only the Command Line Tools are, with Swift 5.9.2 and the
  macOS 14.2 SDK.
- That Swift version is too old for the common Swift speech libraries: WhisperKit needs
  Swift 5.10, FluidAudio needs 6.0, and mlx-swift needs 6.3.
- Homebrew provides prebuilt Apple Silicon builds of whisper.cpp 1.9.5 and llama.cpp 1.0.0,
  which need no Swift toolchain at all.

## Gaps

- TechRepublic's Rambler article returned 403 and was not read.
- A page said to contain a reusable "Rambler-style" cleanup prompt did not load. Lucid's
  cleanup prompt will be written and tested from scratch.
- No source describes how either app restores the clipboard after pasting, or Rambler's
  latency, or how far Rambler rewrites long rambling speech.
- Wispr's pricing and the experimental status of Command Mode were not checked.

## Sources

- [Technical challenges behind Flow](https://wisprflow.ai/research/technical-challenges)
- [Designing a natural and useful voice interface](https://wisprflow.ai/research/designing-a-natural-and-useful-voice-interface)
- [Wispr Flow features](https://wisprflow.ai/features)
- [What is Flow?](https://docs.wisprflow.ai/articles/2772472373-what-is-flow)
- [Smart Formatting and Backtrack](https://docs.wisprflow.ai/articles/5373093536-how-do-i-use-smart-formatting-and-backtrack)
- [Dictionary](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)
- [Snippets](https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets)
- [Command Mode](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode)
- [Flow Bar](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop)
- [Baseten case study: Wispr Flow](https://www.baseten.co/resources/customers/wispr-flow/)
- [TechCrunch: Google adds Gemini-powered dictation to Gboard](https://techcrunch.com/2026/05/12/google-adds-gemini-powered-dictation-to-gboard-which-could-be-bad-news-for-dictation-startups/)
- [Android Headlines: Google Rambler](https://www.androidheadlines.com/2026/05/google-gboard-rambler-ai-voice-dictation-features.html)
- [Android Police: Rambler contact names and corrected words](https://www.androidpolice.com/gboard-rambler-could-stop-butchering-your-favorite-contact-names-slang-words/)
