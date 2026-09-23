# Bolo design

Full proposal with the use-case catalog, limits and memory budget:
https://claude.ai/artifact/4A9A7BgazkVgwU6uEhFRg6

## Pipeline

```
right ⌥ held ──► mic + Apple voice processing (noise suppression, echo cancel, AGC)
                   │
                   ▼
            Apple SpeechTranscriber (en_IN; alternatives + word confidence; names/apps as context)
            → live transcript in the notch   [dictation + custom vocabulary available, measured worse]
                   │ (Qwen starts loading in parallel)
right ⌥ released ──┤ +350 ms tail
                   ▼
            clean → HearingFixes (known Hinglish mishearings) → CommandParser, best guess first,
            then each alternative                                   (~2 ms, can't invent)
                   │ no match
                   ▼
            Qwen (MLX, in-app) one-shot plan for plain requests  (fallback: Apple's model, no sends)
                   │ screen work, a follow-up, or a failed step
                   ▼
            Agent loop (AgentLoop): Observer snapshot ─► model picks ONE action (JSON) ─► risk →
            permission level (allow / say "yes" / countdown / deny) ─► Tools ─► look again … ≤ 14 steps
              Observer: web pages via the browser's own JS (numbered links/buttons/fields, like
              browser-use); every other app via Accessibility (numbered controls + some text);
              stops on a macOS permission prompt. Context: Conversation (last 8 turns, 10 min),
              memory.md, skills/<App>.md.
              Tools: open_app/url/file, click, fill, type, key, menu, scroll, shell (zsh, cwd carried),
              list/read/write_file, message/call (grounded), note, reminder, system ops, remember, lookup.
                   │
                   ▼
            Grounding (drop anything not in the utterance) → low confidence? sends become drafts
                                  │
                                  ▼
                         Executor → skills: deep links, AppleScript, EventKit, keystrokes, AX
                                  │ each step's result → notch → history.jsonl
```

Ideas borrowed: numbered screen elements (browser-use, Peekaboo), direct actions over UI clicking
(Microsoft UFO), per-tool allow/ask/deny by risk (opencode, OpenWork). Everything is local: the
brain is an MLX model inside the app (`brainModel`), or an Ollama/LM Studio endpoint on this Mac.

## Decisions

| Decision | Why |
|---|---|
| Fully autonomous, no buttons on the notch | The user asked for it. Safety comes from not acting on unsaid things (parser + grounding + send verification), not from confirmation prompts. |
| Phrase parser first, model second | Measured 2026-09-22 on this Mac: Apple's on-device model took 1.6–3.6 s per command, padded plans with extra steps, and invented a WhatsApp message for "new note groceries milk eggs bread". The parser takes ~2 ms and can't invent anything. |
| `write / type / likho` = draft, `send / bhejo / karo / bolo` = send | One clear rule for when a message leaves the Mac. |
| Verify the text box before pressing Return | Deep links pre-fill WhatsApp/Teams; Bolo reads the focused field via Accessibility and only sends if it holds exactly the message. |
| Ambiguous contact = error | Never guess between two people. |
| Hand-built `DynamicGenerationSchema`, not `@Generable` | The `FoundationModelsMacros` plugin ships only with Xcode; this machine has only the Command Line Tools. |
| `scripts/test.sh` adds framework paths | CLT include Swift Testing but SwiftPM doesn't find it without `-F`/rpath flags. |
| Sign with the Apple Development certificate | Keeps Accessibility/Microphone grants across rebuilds (ad-hoc signatures change every build). |
| No Docker, no Python, no server | One app; ~50 MB RSS idle, +3.2 GB only while Qwen is loaded. |
| Drop Laya | Zero-shot 53% intent on our prompts ("Chrome kholo" → lock screen). Qwen covers understanding; exact text matching covers step checks. |
| Qwen3.5-4B replaces Apple's model as the fallback | Text eval: rules then Qwen+guard 96% fully right, 0 unsafe; rules then Apple 88%, 1 unsafe (turned "jot down call the plumber" into a call). Apple's model stays only as a no-send fallback. |
| Apple SpeechTranscriber, not dictation or Whisper | Speech eval on 50 recordings: transcriber 22% word error / 24% Hinglish, 78 ms; dictation 26% / 31% (custom vocabulary made no difference); Whisper 31% / 67%, 812 ms. |
| Alternatives tried, but their sends become drafts | A runner-up transcript that parses is useful, but acting on a second guess shouldn't send. |
| Hearing fixes anchored to command words | Real transcripts of the 50 recordings: "Team Pe", "Open Intelligent", "Che Baji Ya De Lana". Fixes only touch the command skeleton, never message text. |
| Low-confidence sends become drafts | Clear English scored 0.73–0.96 confidence, garbled Hinglish bodies 0.45–0.49; `minSendConfidence` is 0.6. |
| xcodebuild for the app | MLX Metal kernels only compile under Xcode; the metallib is copied next to the executable. |

## Machines

- **M5 Mac** runs Bolo day to day (disk space, Xcode). Setup: `docs/SETUP.md`; updates: `scripts/update.sh`.
- **M4 Air** is for code, builds and tests only (Command Line Tools, little disk).

## Constraints on the M4 Air (2026-09-22)

- No Xcode: MLX Swift (local Qwen, vision model) can't be built until Xcode is installed.
- 4.3 GB free disk: model downloads (Whisper for Hinglish 0.65 GB, Laya 0.93 GB, Qwen3.5-4B 3.06 GB) wait until space is freed.
- Apple's on-device model and speech recognition don't support Hindi; Hinglish works today only
  through the phrase patterns (romanised Hindi as recognised by the en_IN speech model).

## Phases

| Phase | Scope | Status |
|---|---|---|
| 1 | App shell: notch panel, push-to-talk, live transcript, settings | Done |
| 2 | Everyday skills: apps, WhatsApp/Teams/iMessage/Mail, notes, reminders, meetings, search, system | Done (first cut) |
| 0 | Measure: text eval (done), speech eval on 50 recordings | Done |
| 3 | Qwen3.5-4B in the app via MLX; noise suppression; recording-driven hearing fixes; send policy | Done |
| 4 | Drive any app's screen through Accessibility (click by label, menus, keys, fields, scroll); chats by name in WhatsApp/Teams/Slack | Done; live-tested on Calculator pending an unlocked Mac |
| 5 | Screen text recognition, click by visible text, vision model | Later |
| 6 | Routines, Laya fine-tuned on history, allow-listed terminal commands | Later |
