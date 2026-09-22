# Bolo

Hold a key, say what you want in English or Hinglish, and your Mac does it. No buttons, no
confirmations, no cloud: Bolo shows what you said in a panel under the notch and acts on it.

```
hold right ⌥   "bhai ko WhatsApp karo, I'll be late by 20 minutes"   release
               → WhatsApp opens Rahul's chat, types the message, sends it
```

Everything runs on the Mac: Apple's on-device speech recognition, a phrase parser, and Apple's
on-device language model as a fallback. The app is under 1 MB and uses about 50 MB of memory.

## What you can say

| You say | Bolo does |
|---|---|
| `open notes` · `Chrome kholo` · `open github dot com` | Opens the app or site |
| `bhai ko WhatsApp karo, I'll be late` | Sends it on WhatsApp |
| `send a teams message to Priya saying joining in 5` | Sends it on Teams |
| `Priya ko teams pe message karo build is green` | Sends it on Teams |
| `text mom I'm home` · `tell bhai on imessage reached` | Sends to the person's default app, or iMessage |
| `mom ko whatsapp pe likho dinner at 8` | Types the draft, doesn't send (*likho/write/type* = draft) |
| `open bhai's whatsapp chat` | Opens the chat |
| `teams call Priya` | Starts a Teams call |
| `new note groceries milk eggs` | Adds an Apple Note |
| `remind me at 5 pm to call bhai` · `…in 10 minutes` | Adds a reminder with an alert |
| `join my next meeting` | Opens the Teams/Zoom/Meet link from your calendar |
| `search youtube for G1GC tuning` · `google heap dump` | Searches |
| `type thanks, will review today` | Types into whatever is focused |
| `volume 30` · `mute` · `lock the screen` | System controls |
| `run my standup shortcut` | Runs one of your Shortcuts |
| `… and remind me at 5 to call her` | Chains steps with *and / then / aur* |
| `click Send` · `Save pe click karo` · `submit dabao` | Presses that button, row, tab or link in the app in front |
| `File menu export as PDF` · `choose Make Plain Text from the Format menu` | Any menu item in any app |
| `press command shift t` · `select all` · `copy` · `save karo` · `new tab` | Keys and shortcuts |
| `type hello in the search box` | Types into that field |
| `scroll down 3 times` · `neeche scroll karo` · `go back` | Scrolls or goes back |
| `open the family group on whatsapp` · `whatsapp design team saying …` | Finds a chat by name (groups, or people without a saved number); only on one exact match |

Sentences that don't match a pattern go to Apple's on-device model. Its output is only used if
every contact and message word appears in what you said (see "Safety").

## Install

Step-by-step for a new Mac, with a test checklist: **[docs/SETUP.md](docs/SETUP.md)**.

Requires macOS 26 on Apple silicon and Xcode or the Xcode Command Line Tools.

```bash
scripts/build-app.sh --install
```

This builds `build/Bolo.app`, signs it with your Apple Development certificate (so permissions
survive rebuilds), copies it to `~/Applications` and launches it. A microphone icon appears in the
menu bar.

On first launch, allow:

- **Accessibility**: to hear the key from any app and press Return in chat apps
- **Microphone**: only used while the key is held
- **Contacts**: to find "bhai" or "Priya"
- **Automation** (asked per app): Messages, Notes, Mail
- **Reminders / Calendar**: asked the first time you use them

## Nicknames

Bolo finds people by the **Nickname** field in Contacts, or by first or full name. For anyone else,
or to set a default app per person, edit **Nicknames…** from the menu bar:

```json
{
  "bhai": { "name": "Rahul", "phone": "+91 XXXXX XXXXX", "channel": "whatsapp" },
  "priya": { "name": "Priya Sharma", "email": "priya@company.com", "channel": "teams" }
}
```

WhatsApp needs a phone number, Teams needs an email. Then choose **Reload contacts and apps**.

## Safety

Bolo acts without asking, so it's built not to act on things you didn't say:

- The phrase parser never guesses. Anything it can't read goes to the model, and the model's
  output is dropped unless the contact and message words all come from your sentence. (In testing,
  Apple's model turned "new note groceries…" into a note plus an invented WhatsApp message to
  Priya. The guard rejects that.)
- Before pressing send in WhatsApp or Teams, Bolo checks the chat's text box holds exactly your
  message. If the app doesn't show it, Bolo leaves the draft and tells you.
- Two people matching the same name is an error, never a guess.
- `Esc` stops a running command. There's a 0.8 s pause before sending (`sendDelaySeconds` in
  Settings); set it to `0` for none.
- There are no skills for payments, passwords or system security settings.

## Development

```bash
scripts/update.sh                                 # on the Mac that runs Bolo: pull, test, rebuild, relaunch
scripts/test.sh                                   # parser, grounding and time tests
.build/debug/Bolo --doctor                        # what this Mac still needs
~/Applications/Bolo.app/Contents/MacOS/Bolo --listen 5          # speak; see the live transcript and what Bolo would do
~/Applications/Bolo.app/Contents/MacOS/Bolo --remote "open calculator" [--dry-run]   # run a sentence inside Bolo.app
swift build && .build/debug/Bolo --say "open notes" --dry-run    # see how a sentence is understood
.build/debug/Bolo --say "volume 30"               # run a command without speaking
```

Layout:

- `Sources/BoloCore`: command model, phrase parser, model fallback, grounding guard. No UI,
  fully tested.
- `Sources/Bolo`: the menu-bar app: notch panel, push-to-talk, speech, skills.
- `docs/DESIGN.md`: architecture, decisions and the phase plan.

History of every command is kept in `~/Library/Application Support/Bolo/history.jsonl`.
