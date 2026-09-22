# /// script
# requires-python = ">=3.12"
# ///
"""Phase 0, speech part: which speech engine hears your commands best, and does Bolo then do the
right thing? Needs recordings from `uv run eval/record.py`.

Engines on the same recordings:
  apple         Apple SpeechAnalyzer, English (India): what Bolo ships today
  whisper-en    WhisperKit large-v3 turbo, told the language is English (Hinglish comes out romanised)
  whisper-auto  WhisperKit, language auto-detected (Hinglish may come out in Devanagari)

For each: word error rate against the prompt text, speed, and end-to-end accuracy (transcript →
Bolo's parser + Apple model → right action?).

  uv run eval/stt_eval.py        # downloads the Whisper model (~0.6 GB) once
"""

import json
import statistics
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from text_eval import NAMES, PROMPTS, ROOT, norm, score  # noqa: E402

REC = ROOT / "eval/recordings"
TOOL_DIR = ROOT / "eval/SpeechEval"
TOOL = TOOL_DIR / ".build/release/speech-eval"


def wer(ref, hyp):
    r, h = norm(ref).split(), norm(hyp).split()
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)] / max(1, len(r))


def transcribe(engine, *extra):
    if not TOOL.exists():
        subprocess.run(["swift", "build", "-c", "release"], cwd=TOOL_DIR, check=True)
    out = subprocess.run([str(TOOL), engine, str(REC), *extra], capture_output=True, text=True, check=True).stdout
    rows = [json.loads(l) for l in out.splitlines() if l.startswith("{")]
    load = next((r["ms"] for r in rows if r["id"] == "_load"), 0)
    return {r["id"]: (r.get("text", ""), r["ms"]) for r in rows if r["id"] != "_load"}, load


def understand(transcripts):
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        for i, (text, _) in transcripts.items():
            f.write(json.dumps({"id": i, "say": text}) + "\n")
    binary = ROOT / ".build/debug/Bolo"
    out = subprocess.run([str(binary), "--batch", f.name, "--names", NAMES], capture_output=True, text=True, check=True).stdout
    return {r["id"]: r["steps"] for r in map(json.loads, out.splitlines())}


def main():
    have = {p.stem for p in REC.glob("*.wav")}
    prompts = [p for p in PROMPTS if p["id"] in have]
    if not prompts:
        sys.exit("No recordings yet. Run: uv run eval/record.py")
    say = {p["id"]: p["say"] for p in prompts}
    exp = {p["id"]: p["expect"] for p in prompts}

    engines = {
        "apple (en_IN)": ("apple", "--locale", "en_IN"),
        "whisper-en": ("whisper", "--lang", "en"),
        "whisper-auto": ("whisper", "--lang", "auto"),
    }
    lines = [f"# Phase 0 speech eval — {date.today()}", "", f"{len(prompts)} recorded prompts.", "",
             "| Engine | Word error rate | Hinglish WER | End-to-end fully right | Unsafe sends | Median time | Model load |",
             "|---|---|---|---|---|---|---|"]
    detail = []
    hinglish = {p["id"] for p in prompts if any(w in p["say"].lower().split() for w in ("ko", "kholo", "karo", "mujhe", "aur"))}
    for name, argv in engines.items():
        print(f"{name} …", file=sys.stderr)
        tr, load = transcribe(*argv)
        steps = understand(tr)
        w = [wer(say[i], tr[i][0]) for i in tr]
        wh = [wer(say[i], tr[i][0]) for i in tr if i in hinglish]
        full = unsafe = 0
        for i in tr:
            _, f, u = score(steps.get(i, []), exp[i])
            full += f
            unsafe += u
        n = len(tr)
        lines.append(f"| {name} | {100*statistics.mean(w):.0f}% | {100*statistics.mean(wh):.0f}% | {full}/{n} ({100*full//n}%) | {unsafe} | "
                     f"{statistics.median(ms for _, ms in tr.values()):.0f} ms | {load/1000:.1f} s |")
        detail += [f"## {name}", ""] + [f"- `{i}` said \"{say[i]}\" → heard \"{tr[i][0]}\"" for i in sorted(tr)] + [""]
    report = "\n".join(lines + [""] + detail)
    out = ROOT / f"eval/results/speech-{date.today()}.md"
    out.parent.mkdir(exist_ok=True)
    out.write_text(report)
    print(report)


if __name__ == "__main__":
    main()
