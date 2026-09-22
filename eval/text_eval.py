# /// script
# requires-python = ">=3.11"
# dependencies = ["mlx>=0.32.2,<0.33", "mlx-lm>=0.31", "laya-mlx>=0.2"]
# ///
"""Phase 0, text part: how well each engine turns a sentence into the right action.

Engines, all on the same labelled prompts (eval/prompts.jsonl):
  rules        Bolo's phrase parser only
  rules+apple  what Bolo ships today: parser, then Apple's on-device model, grounded
  laya         Laya multilingual picks the intent (no slots), ~ms per question
  qwen         Qwen3.5-4B (4-bit, MLX) writes the whole plan
  qwen+guard   the same, filtered by the grounding rule Bolo applies to model output

"Unsafe" = the engine would send a message or start a call the user didn't ask for, or to the
wrong person, or with different words. Bolo acts without asking, so this is the number that matters.

  uv run eval/text_eval.py            # from the repo root; downloads Laya (0.7 GB) and Qwen (3.1 GB) once
"""

import json
import re
import statistics
import subprocess
import sys
import time
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROMPTS = [json.loads(l) for l in (ROOT / "eval/prompts.jsonl").read_text().splitlines() if l.strip()]
NAMES = "bhai,mom,priya,myself,papa,rahul"
SENDS = {"sendMessage", "call"}


# ---------- scoring ----------

def norm(s):
    s = (s or "").lower().replace("’", "'")
    s = re.sub(r"[^\w' ]", " ", s)
    return re.sub(r"\s+", " ", s).strip()


APP_ALIASES = {
    "teams": "Microsoft Teams", "ms teams": "Microsoft Teams", "outlook": "Microsoft Outlook", "word": "Microsoft Word",
    "excel": "Microsoft Excel", "chrome": "Google Chrome", "vs code": "Visual Studio Code", "vscode": "Visual Studio Code",
    "intellij": "IntelliJ IDEA", "intellij idea": "IntelliJ IDEA", "settings": "System Settings", "whats app": "WhatsApp",
}


def canon(app):
    return norm(APP_ALIASES.get(norm(app), app))


def contact(s):
    return re.sub(r"^(my|to) ", "", norm(s))


def step_ok(p, e):
    if p.get("action") != e["action"]:
        if not ({p.get("action"), e["action"]} <= {"mute", "unmute"}):
            return False
    for k, v in e.items():
        if k == "action":
            continue
        got = p.get(k)
        if k == "contact" and contact(got) != contact(v):
            return False
        if k == "text" and norm(got) != norm(v):
            return False
        if k == "app" and canon(got) != canon(v):
            return False
        if k in ("channel", "engine") and (got or "").lower() != v:
            return False
        if k == "number" and got != v:
            return False
    return True


def score(pred, exp, intent_only=False):
    """intent_only: the engine gives an action but no contact/text (Laya), so a send is unsafe
    only when the user didn't ask for a send at all."""
    intent = [p.get("action") for p in pred] == [e["action"] for e in exp]
    full = len(pred) == len(exp) and all(step_ok(p, e) for p, e in zip(pred, exp))
    unsafe = False
    for p in pred:
        a = p.get("action")
        if a == "sendMessage" and not (p.get("text") or intent_only):
            continue  # a send with no text only opens the chat
        if a in SENDS:
            if intent_only:
                unsafe |= not any(e["action"] == a for e in exp)
                continue
            match = [e for e in exp if e["action"] == a and contact(e.get("contact")) == contact(p.get("contact"))
                     and (a == "call" or norm(e.get("text")) == norm(p.get("text")))]
            unsafe |= not match
    return intent, full, unsafe


# ---------- grounding (same rule as Sources/BoloCore/Grounding.swift) ----------

FILLERS = set("a an the to and or of on in at for is it i me my please saying that ko ki karo".split())


def share(phrase, utterance):
    said = set(norm(utterance).split())
    want = [w for w in norm(phrase).split() if w not in FILLERS]
    return 1.0 if not want else sum(w in said for w in want) / len(want)


def ground(steps, utterance):
    kept = []
    for s in steps:
        a, text = s.get("action"), s.get("text")
        text_ok = text is None or share(text, utterance) >= 0.8
        if a in ("sendMessage", "draftMessage", "call"):
            if not (s.get("contact") and share(s["contact"], utterance) == 1 and text_ok):
                return []
            kept.append(s)
        elif a in ("newNote", "typeText", "addReminder", "runShortcut"):
            if text and text_ok:
                kept.append(s)
        elif a == "webSearch":
            if text and share(text, utterance) >= 0.6:
                kept.append(s)
        elif a in ("openApp", "openURL"):
            if share(s.get("app") or text or "", utterance) > 0:
                kept.append(s)
        elif a:
            kept.append(s)
    out = []
    for s in kept:
        if s not in out:
            out.append(s)
    return out


# ---------- engines ----------

def bolo(no_model):
    binary = ROOT / ".build/debug/Bolo"
    if not binary.exists():
        subprocess.run(["swift", "build"], cwd=ROOT, check=True)
    cmd = [str(binary), "--batch", str(ROOT / "eval/prompts.jsonl"), "--names", NAMES] + (["--no-model"] if no_model else [])
    rows = [json.loads(l) for l in subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.splitlines()]
    return {r["id"]: (r["steps"], r["ms"]) for r in rows}


LAYA_LABELS = {
    "open an app": ("openApp", "launch or switch to an application"),
    "open a website": ("openURL", "open a web address"),
    "send a message": ("sendMessage", "send a chat, text or email to a person"),
    "draft a message": ("draftMessage", "open someone's chat or type a message without sending it"),
    "call someone": ("call", "start a voice or video call"),
    "make a note": ("newNote", "write something down in notes"),
    "set a reminder": ("addReminder", "remind the user about something later"),
    "search the web": ("webSearch", "search Google or YouTube"),
    "join a meeting": ("joinNextMeeting", "join the next calendar meeting"),
    "type text": ("typeText", "type words into the current app"),
    "change volume": ("setVolume", "set the sound volume"),
    "mute or unmute": ("mute", "mute or unmute the sound"),
    "lock the screen": ("lockScreen", "lock the computer"),
    "run a shortcut": ("runShortcut", "run a Shortcuts automation"),
    "not a command": (None, "chatting, a question, or anything that isn't asking the Mac to do something"),
}


def laya():
    import laya_mlx
    import mlx.core as mx

    agent = laya_mlx.load("aac6fef/laya-multilingual-mlx", dtype="float16")
    q = {"intent": {"type": "choice", "instructions": "What does the user want the Mac to do?",
                    "criteria": {k: v[1] for k, v in LAYA_LABELS.items()}}}
    agent.predict("warm up", q)
    out = {}
    for p in PROMPTS:
        t = time.perf_counter()
        ans = agent.predict(p["say"], q)["answers"]["intent"]
        ms = (time.perf_counter() - t) * 1000
        label = ans.get("choice") or ans.get("label") or ans.get("answer")
        conf = ans.get("confidence")
        action = LAYA_LABELS.get(label, (None,))[0]
        out[p["id"]] = ([{"action": action}] if action else [], ms, conf)
    peak = mx.get_peak_memory() / 1e9
    return out, peak


QWEN_SYSTEM = """You turn one spoken command for a Mac into JSON. The user speaks English or Hinglish.
Reply with only: {"steps": [ ... ]}. Each step has "action" and only the fields it needs:
- openApp: app | openURL: text (the address) | webSearch: text, engine ("google" or "youtube")
- sendMessage / draftMessage: contact, text, channel (whatsapp, teams, imessage, mail) only if the user named the app
- call: contact, channel | newNote: text | addReminder: text, time | typeText: text
- setVolume: number | mute | unmute | lockScreen | joinNextMeeting | runShortcut: text
Rules:
- Copy the contact and the message text exactly from the user's words. Never invent or rephrase them.
- Hinglish: "X ko ... karo / bhejo / bolo / bol do" = sendMessage to X; "likho" = draftMessage; "yaad dilana" = addReminder; "kholo" = openApp.
- One step per thing asked. If the user isn't asking the Mac to do anything, reply {"steps": []}.
Examples:
"bhai ko WhatsApp karo I'll be late" -> {"steps":[{"action":"sendMessage","contact":"bhai","channel":"whatsapp","text":"I'll be late"}]}
"open slack and remind me at 4 to review the PR" -> {"steps":[{"action":"openApp","app":"Slack"},{"action":"addReminder","text":"review the PR","time":"at 4"}]}
"how are you" -> {"steps":[]}"""


def qwen(repo="mlx-community/Qwen3.5-4B-MLX-4bit"):
    import mlx.core as mx
    from mlx_lm import generate, load

    model, tok = load(repo)
    out = {}

    def ask(say):
        msgs = [{"role": "system", "content": QWEN_SYSTEM}, {"role": "user", "content": say}]
        try:
            prompt = tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, enable_thinking=False)
        except TypeError:
            prompt = tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False)
        return generate(model, tok, prompt=prompt, max_tokens=220, verbose=False)

    ask("open notes")
    for p in PROMPTS:
        t = time.perf_counter()
        text = ask(p["say"])
        ms = (time.perf_counter() - t) * 1000
        m = re.search(r"\{.*\}", text, re.S)
        try:
            steps = json.loads(m.group(0)).get("steps", []) if m else []
        except json.JSONDecodeError:
            steps = []
        steps = [{k: v for k, v in s.items() if v not in (None, "", "none")} for s in steps if isinstance(s, dict)]
        out[p["id"]] = (steps, ms)
    peak = mx.get_peak_memory() / 1e9
    return out, peak


# ---------- report ----------

def summarize(name, results, only=None, intent_only=False):
    ids = [p["id"] for p in PROMPTS if only is None or only(p)]
    exp = {p["id"]: p["expect"] for p in PROMPTS}
    n = len(ids)
    intent = full = unsafe = 0
    lat = []
    misses = []
    for i in ids:
        steps, ms = results[i][0], results[i][1]
        a, f, u = score(steps, exp[i], intent_only)
        intent += a
        full += f
        unsafe += u
        lat.append(ms)
        if not f or u:
            misses.append((i, u, steps))
    med = statistics.median(lat) if lat else 0
    return (f"| {name} | {n} | {intent}/{n} ({100*intent//n}%) | {full}/{n} ({100*full//n}%) | {unsafe} | {med:.0f} ms |", misses)


def main():
    print("rules …", file=sys.stderr)
    rules = bolo(no_model=True)
    print("rules + Apple model …", file=sys.stderr)
    shipped = bolo(no_model=False)
    print("Laya …", file=sys.stderr)
    laya_res, laya_peak = laya()
    print("Qwen …", file=sys.stderr)
    qwen_res, qwen_peak = qwen()
    guarded = {i: (ground(s, next(p["say"] for p in PROMPTS if p["id"] == i)), ms) for i, (s, ms) in qwen_res.items()}

    single = lambda p: len(p["expect"]) <= 1
    # Proposed: phrase rules first (0 ms); Qwen + guard only when no rule matches.
    combined = {i: (rules[i] if rules[i][0] else guarded[i]) for i in rules}
    rows = [
        summarize("rules", rules),
        summarize("rules + Apple model (shipped)", shipped),
        summarize("Laya, intent only (single-step prompts)", laya_res, single, intent_only=True),
        summarize("Qwen3.5-4B", qwen_res),
        summarize("Qwen3.5-4B + guard", guarded),
        summarize("rules, then Qwen + guard (proposed)", combined),
    ]
    say = {p["id"]: p["say"] for p in PROMPTS}
    lines = [
        f"# Phase 0 text eval — {date.today()}",
        "",
        f"{len(PROMPTS)} labelled prompts (`eval/prompts.jsonl`), typed text (no speech). Machine: see below.",
        "",
        "| Engine | Prompts | Right intent | Fully right | Unsafe sends | Median time |",
        "|---|---|---|---|---|---|",
        *[r[0] for r in rows],
        "",
        f"Peak MLX memory: Laya {laya_peak:.2f} GB, Qwen {qwen_peak:.2f} GB.",
        "",
    ]
    for (row, misses), title in zip(rows, ["rules", "rules + Apple model", "Laya", "Qwen", "Qwen + guard", "rules, then Qwen + guard"]):
        lines += [f"## Misses: {title}", ""]
        for i, unsafe, steps in misses:
            flag = " **UNSAFE**" if unsafe else ""
            lines.append(f"- `{i}` \"{say[i]}\" → `{json.dumps(steps, ensure_ascii=False)}`{flag}")
        lines.append("")
    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    lines.append(f"Machine: {chip}.")
    report = "\n".join(lines)
    out = ROOT / f"eval/results/text-{date.today()}.md"
    out.parent.mkdir(exist_ok=True)
    out.write_text(report)
    print(report)
    print(f"\nwritten to {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
