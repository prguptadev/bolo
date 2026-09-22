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
