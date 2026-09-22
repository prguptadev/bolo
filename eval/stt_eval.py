# /// script
# requires-python = ">=3.12"
# ///
"""Phase 0, speech part: which speech engine hears your commands best, and does Bolo then do the
right thing? Needs recordings from `uv run eval/record.py`.

Engines on the same recordings:
  transcriber          Apple SpeechTranscriber, English (India)
  dictation            Apple DictationTranscriber, English (India), short-command mode
  dictation+vocab      the same plus Bolo's custom vocabulary (what Bolo ships now)
  dictation-hi         Apple dictation in Hindi, transliterated to Latin letters
  whisper-en           WhisperKit large-v3 turbo, told the language is English
  whisper-auto         WhisperKit, language auto-detected

Recordings are raw microphone audio. The app also runs Apple's noise suppression, which can't be
applied to files, so real use in a noisy room should do at least as well as these numbers.

For each: word error rate against the prompt text, speed, and end-to-end accuracy (transcript →
Bolo's parser + Apple model → right action?).

  uv run eval/stt_eval.py                       # all engines; downloads Whisper (~0.6 GB) once
  uv run eval/stt_eval.py --only transcriber    # engines whose name contains this
  uv run eval/stt_eval.py --rescore             # reuse saved transcripts; re-run only the parser
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

REC = ROOT / "eval/recordings"  # only p*.wav at the top level are used
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


SAVED = ROOT / "eval/results/transcripts"


def slug(name):
    return "".join(c if c.isalnum() else "-" for c in name.lower()).strip("-")


def transcribe_cached(name, argv, rescore):
    path = SAVED / f"{slug(name)}.json"
    if rescore and path.exists():
        data = json.loads(path.read_text())
        return {k: tuple(v) for k, v in data["transcripts"].items()}, data["load"]
    tr, load = transcribe(*argv)
    SAVED.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"load": load, "transcripts": tr}, ensure_ascii=False, indent=1))
    return tr, load


def transcribe(engine, *extra):
    if not TOOL.exists():
        subprocess.run(["swift", "build", "-c", "release"], cwd=TOOL_DIR, check=True)
    out = subprocess.run([str(TOOL), engine, str(REC), *extra], capture_output=True, text=True, check=True).stdout
    rows = [json.loads(l) for l in out.splitlines() if l.startswith("{")]
    load = next((r["ms"] for r in rows if r["id"] == "_load"), 0)
    return {r["id"]: (r.get("text", ""), r["ms"], r.get("alts", []), r.get("conf")) for r in rows if r["id"] != "_load"}, load


def understand(transcripts):
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        for i, (text, _, alts, conf) in transcripts.items():
            f.write(json.dumps({"id": i, "say": text, "alts": alts, "conf": conf}) + "\n")
    binary = ROOT / ".build/debug/Bolo"
    brain = sys.argv[sys.argv.index("--brain") + 1] if "--brain" in sys.argv else "apple"
    if brain == "qwen":
        binary = ROOT / "build/Bolo.app/Contents/MacOS/Bolo"  # Qwen needs the Xcode build (GPU kernels)
    out = subprocess.run([str(binary), "--batch", f.name, "--names", NAMES, "--brain", brain], capture_output=True, text=True, check=True).stdout
    return {r["id"]: r["steps"] for r in map(json.loads, out.splitlines())}


def main():
    have = {p.stem for p in REC.glob("*.wav")}
    prompts = [p for p in PROMPTS if p["id"] in have]
    if not prompts:
        sys.exit("No recordings yet. Run: uv run eval/record.py")
    say = {p["id"]: p["say"] for p in prompts}
    exp = {p["id"]: p["expect"] for p in prompts}

    engines = {
        "transcriber (en_IN)": ("apple", "--locale", "en_IN"),
        "dictation (en_IN, short-form)": ("dictation", "--locale", "en_IN"),
    }
    vocab_dir = Path.home() / "Library/Application Support/Bolo/vocabulary"
    lms = sorted(vocab_dir.glob("lm-*.bin"), key=lambda p: p.stat().st_mtime)
    if lms:
        lm = lms[-1]
        engines["dictation + Bolo vocabulary"] = ("dictation", "--locale", "en_IN", "--lm", str(lm), "--vocab", str(lm).replace("/lm-", "/vocab-"))
    else:
        print("(no custom vocabulary yet: run .build/debug/Bolo --vocabulary to include it)", file=sys.stderr)
    engines["dictation (hi_IN → Latin)"] = ("dictation", "--locale", "hi_IN")
    engines["whisper-en"] = ("whisper", "--lang", "en")
    engines["whisper-auto"] = ("whisper", "--lang", "auto")
    lines = [f"# Phase 0 speech eval — {date.today()}", "", f"{len(prompts)} recorded prompts.", "",
             "| Engine | Word error rate | Hinglish WER | End-to-end fully right | Unsafe sends | Mean confidence | Median time | Model load |",
             "|---|---|---|---|---|---|---|---|"]
    detail = []
    hinglish = {p["id"] for p in prompts if any(w in p["say"].lower().split() for w in ("ko", "kholo", "karo", "mujhe", "aur"))}
    only = sys.argv[sys.argv.index("--only") + 1].lower() if "--only" in sys.argv else None
    rescore = "--rescore" in sys.argv
    for name, argv in engines.items():
        if only and only not in name.lower():
            continue
        if rescore and not (SAVED / f"{slug(name)}.json").exists():
            continue
        print(f"{name} …", file=sys.stderr)
        tr, load = transcribe_cached(name, argv, rescore)
        steps = understand(tr)
        w = [wer(say[i], tr[i][0]) for i in tr]
        wh = [wer(say[i], tr[i][0]) for i in tr if i in hinglish]
        full = unsafe = 0
        verdict = {}
        for i in tr:
            _, f, u = score(steps.get(i, []), exp[i])
            full += f
            unsafe += u
            verdict[i] = "**UNSAFE**" if u else ("✓" if f else "✗")
        n = len(tr)
        confs = [c for *_, c in tr.values() if c is not None]
        conf = f"{statistics.mean(confs):.2f}" if confs else "n/a"
        wh_s = f"{100*statistics.mean(wh):.0f}%" if wh else "n/a"
        lines.append(f"| {name} | {100*statistics.mean(w):.0f}% | {wh_s} | {full}/{n} ({100*full//n}%) | {unsafe} | {conf} | "
                     f"{statistics.median(v[1] for v in tr.values()):.0f} ms | {load/1000:.1f} s |")
        detail += [f"## {name}", ""] + [
            f"- {verdict[i]} `{i}` said \"{say[i]}\" → heard \"{tr[i][0]}\"" + (f" (conf {tr[i][3]})" if tr[i][3] is not None else "")
            + f" → `{json.dumps([{k: v for k, v in st.items() if k in ('action', 'app', 'contact', 'channel', 'text', 'time', 'number')} for st in steps.get(i, [])], ensure_ascii=False)}`"
            for i in sorted(tr)] + [""]
    report = "\n".join(lines + [""] + detail)
    suffix = ("-rescore" if "--rescore" in sys.argv else "") + (f"-{slug(only)}" if only else "")
    if "--brain" in sys.argv:
        suffix += "-" + sys.argv[sys.argv.index("--brain") + 1]
    out = ROOT / f"eval/results/speech-{date.today()}{suffix}.md"
    out.parent.mkdir(exist_ok=True)
    out.write_text(report)
    print(report)


if __name__ == "__main__":
    main()
