# /// script
# requires-python = ">=3.12"
# dependencies = ["sounddevice", "soundfile", "numpy"]
# ///
"""Phase 0: record yourself reading each test sentence, for the speech comparison.

  uv run eval/record.py                 # every sentence without a recording yet
  uv run eval/record.py --only p06,p13  # just these (re-records them)

This ONLY records. Nothing happens on your Mac: Bolo isn't running here, notes won't open.
Read each sentence exactly as shown, the way you'd naturally say it (Hinglish accent and all).
After each one it tells you what it heard, so you can redo it if it went wrong.

Recordings go to eval/recordings/<id>.wav (16 kHz mono) and aren't committed.
"""

import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf

ROOT = Path(__file__).resolve().parent
RATE = 16000
OUT = ROOT / "recordings"
OUT.mkdir(exist_ok=True)
CHECKER = ROOT / "SpeechEval/.build/release/speech-eval"  # optional: repeats back what it heard

BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"

prompts = [json.loads(l) for l in (ROOT / "prompts.jsonl").read_text().splitlines() if l.strip()]
only = set(sys.argv[sys.argv.index("--only") + 1].split(",")) if "--only" in sys.argv else None
todo = [p for p in prompts if (p["id"] in only if only else not (OUT / f"{p['id']}.wav").exists())]


def record():
    chunks = []
    with sd.InputStream(samplerate=RATE, channels=1, dtype="float32", callback=lambda d, *_: chunks.append(d.copy())):
        input(f"  {BOLD}● recording{RESET} — read the sentence, then press Enter ")
    return np.concatenate(chunks) if chunks else np.zeros((0, 1), dtype="float32")


def voiced_seconds(audio):
    a = audio[: len(audio) // 320 * 320, 0].reshape(-1, 320)
    return float((np.sqrt((a**2).mean(1)) > 0.02).sum() * 0.02) if len(a) else 0.0


def heard(path):
    if not CHECKER.exists():
        return None
    try:
        out = subprocess.run([str(CHECKER), "apple", str(path)], capture_output=True, text=True, timeout=20).stdout
        rows = [json.loads(l) for l in out.splitlines() if l.startswith('{"id":"p')]
        return rows[0].get("text", "") if rows else ""
    except Exception:
        return None


print(f"""
{BOLD}Recording {len(todo)} sentences.{RESET} This only records — nothing opens or happens on your Mac.
For each one: press Enter, {BOLD}read the sentence exactly as shown{RESET}, press Enter.
Type s to skip, q to quit (you can resume later; finished ones are kept).
""")

n = 0
while n < len(todo):
    p = todo[n]
    print(f"{DIM}[{n + 1}/{len(todo)}] {p['id']}{RESET}")
    print(f"  Read aloud:  {BOLD}» {p['say']} «{RESET}")
    cmd = input("  Enter to start › ").strip().lower()
    if cmd == "q":
        break
    if cmd == "s":
        n += 1
        continue
    audio = record()
    if voiced_seconds(audio) < 0.3:
        print("  Didn't catch any speech. Let's try that one again.\n")
        continue
    path = OUT / f"{p['id']}.wav"
    sf.write(path, audio, RATE)
    text = heard(path)
    if text is not None:
        print(f"  Heard:       {text or '(nothing)'}")
    again = input("  Enter = keep, r = redo › ").strip().lower()
    if again == "r":
        continue
    print()
    n += 1

done = len(list(OUT.glob("p*.wav")))
print(f"{done}/{len(prompts)} sentences recorded in {OUT}")
if done == len(prompts):
    print("All done. Run: uv run eval/stt_eval.py")
