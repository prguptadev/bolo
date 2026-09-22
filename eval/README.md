# Phase 0: measure before building more

Answers three questions with numbers instead of guesses:

1. Which speech engine hears your commands best, especially Hinglish: Apple's built-in one or Whisper?
2. Which engine turns a sentence into the right action: the phrase rules, Apple's model, Laya or Qwen?
3. How often would each one send a message you didn't ask for? (Bolo acts without asking.)

## Text (no microphone needed)

```bash
uv run eval/text_eval.py
```

Runs 50 labelled prompts (`prompts.jsonl`, English and Hinglish, including non-commands) through
every engine. Downloads Laya (0.7 GB) and Qwen3.5-4B (3.1 GB) once. Report: `results/text-<date>.md`.

## Speech

```bash
uv run eval/record.py      # read each prompt aloud; ~10 minutes; saves recordings/<id>.wav
uv run eval/stt_eval.py    # Apple vs Whisper on your recordings; downloads Whisper (0.6 GB) once
```

Report: `results/speech-<date>.md`, with word error rate, Hinglish error rate, end-to-end accuracy
and unsafe sends per engine. Recordings stay on your Mac (git-ignored).

`SpeechEval/` is a small Swift tool that runs Apple's SpeechAnalyzer and WhisperKit on the
recordings. It also checks that WhisperKit builds before it goes into Bolo.

## Results (2026-09-22, M4 Air)

**Text** (`results/text-2026-09-22.md`): rules first, then Qwen3.5-4B + guard: 96% fully right, 0 unsafe.
Inside Bolo (Swift/MLX) after the recording-driven fixes: 50/50 right intent, 49/50 fully right,
0 unsafe; Qwen needed for 3 of 50 sentences, median 2.4 s.

**Speech** (`results/speech-2026-09-22.md`, 50 recordings):

| Engine | Word error | Hinglish error | Time |
|---|---|---|---|
| Apple SpeechTranscriber en_IN (chosen) | 22% | 24% | 78 ms |
| Apple Dictation short-form (± custom vocabulary) | 26% | 31% | 92 ms |
| Apple Hindi dictation | 89% | 71% | — |
| WhisperKit large-v3 turbo (en / auto) | 31% / 48% | 67% / 112% | 812 ms |

End to end with the chosen setup (`results/speech-2026-09-22-rescore-transcriber-qwen.md`): 60% fully
right. Garbled Hinglish messages (confidence 0.45–0.49) become drafts. Remaining errors are mostly
speech mishearings (G1GC → "Jeevan GC", traffic → "track"), not understanding.

Decisions: keep Apple's transcriber; drop Whisper, Laya and the custom vocabulary default; Qwen
replaces Apple's model as the fallback brain.
