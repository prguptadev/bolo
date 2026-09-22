# Bolo design

Full proposal with the use-case catalog, limits and memory budget:
https://claude.ai/artifact/4A9A7BgazkVgwU6uEhFRg6

## Pipeline

```
right ⌥ held ──► mic ──► SpeechAnalyzer (en_IN, on-device, contact names as context)
                                  │ live transcript → notch
right ⌥ released ────────────────►│
                                  ▼
                         CommandParser (phrase rules, EN + Hinglish, ~2 ms)
                                  │ no match
                                  ▼
                         ModelPlanner (Apple on-device model, fixed schema, ~2-3 s)
                                  │
                                  ▼
                         Grounding (drop anything not in the utterance)
                                  │
                                  ▼
                         Executor → skills: deep links, AppleScript, EventKit, keystrokes, AX
                                  │ each step's result → notch → history.jsonl
```

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
| No Docker, no Python, no server | One ~1 MB app, ~50 MB RSS idle. |

## Constraints on this Mac (2026-09-22)

- No Xcode: MLX Swift (local Qwen, vision model) can't be built until Xcode is installed.
- 4.3 GB free disk: model downloads (Whisper for Hinglish 0.65 GB, Laya 0.93 GB, Qwen3.5-4B 3.06 GB) wait until space is freed.
- Apple's on-device model and speech recognition don't support Hindi; Hinglish works today only
  through the phrase patterns (romanised Hindi as recognised by the en_IN speech model).

## Phases

| Phase | Scope | Status |
|---|---|---|
| 0 | Measure speech and intent accuracy on recorded commands | Waiting on disk space |
| 1 | App shell: notch panel, push-to-talk, live transcript, settings | Done |
| 2 | Everyday skills: apps, WhatsApp/Teams/iMessage/Mail, notes, reminders, meetings, search, system | Done (first cut) |
| 3 | Planner for multi-step + Hinglish: Qwen3.5-4B via MLX, Whisper for Hindi speech | Needs Xcode + disk |
| 4 | Drive any app's screen through Accessibility; chat search by name | Next |
| 5 | Screen text recognition, click by visible text, vision model | Later |
| 6 | Routines, Laya fine-tuned on history, allow-listed terminal commands | Later |
