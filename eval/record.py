# /// script
# requires-python = ">=3.12"
# dependencies = ["sounddevice", "soundfile", "numpy"]
# ///
"""Phase 0: record yourself saying each test prompt, for the speech comparison.

  uv run eval/record.py                 # every prompt without a recording yet
  uv run eval/record.py --only p06,p13  # just these (re-records them)

For each prompt: press Enter, say it naturally (Hinglish as you'd really say it), press Enter.
Recordings go to eval/recordings/<id>.wav (16 kHz mono) and aren't committed.
The first run asks for microphone access for your terminal app.
"""

import json
import sys
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf

ROOT = Path(__file__).resolve().parent
RATE = 16000
OUT = ROOT / "recordings"
OUT.mkdir(exist_ok=True)

prompts = [json.loads(l) for l in (ROOT / "prompts.jsonl").read_text().splitlines() if l.strip()]
only = None
if "--only" in sys.argv:
    only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
todo = [p for p in prompts if (p["id"] in only if only else not (OUT / f"{p['id']}.wav").exists())]
print(f"{len(todo)} to record. Enter = start/stop, s = skip, q = quit.\n")

for n, p in enumerate(todo, 1):
    print(f"[{n}/{len(todo)}] {p['id']}:  {p['say']}")
    cmd = input("  Enter to start › ").strip().lower()
    if cmd == "q":
        break
    if cmd == "s":
        continue
    chunks = []
    stream = sd.InputStream(samplerate=RATE, channels=1, dtype="float32", callback=lambda d, *_: chunks.append(d.copy()))
    with stream:
        input("  ● recording… Enter to stop › ")
    audio = np.concatenate(chunks) if chunks else np.zeros((0, 1), dtype="float32")
    sf.write(OUT / f"{p['id']}.wav", audio, RATE)
    print(f"  saved {len(audio) / RATE:.1f} s\n")

done = len(list(OUT.glob("*.wav")))
print(f"{done}/{len(prompts)} prompts recorded in {OUT}")
