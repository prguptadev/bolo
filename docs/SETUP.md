# Set up Bolo on a new Mac

About 20 minutes, most of it installing Xcode. Every step runs on the Mac that will use Bolo.

## 1. Check the Mac

- macOS 26 or later on Apple silicon: Apple menu › About This Mac.
- Apple Intelligence on: System Settings › Apple Intelligence & Siri. Optional; it powers the
  fallback for unusual sentences. Everyday commands work without it.
- Signed in to **WhatsApp** (Mac App Store version) and **Microsoft Teams** (the new Teams), if you
  want to message through them.

## 2. Install Xcode and a signing certificate

1. Install **Xcode** from the App Store, open it once, and let it finish installing components.
2. In Terminal:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app
   ```
3. Install Xcode's Metal Toolchain (MLX needs it to compile Qwen's GPU code; the build script
   also does this for you if it's missing):
   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```
4. Xcode › Settings › Accounts › **+** › Apple ID. Sign in with your developer Apple ID, then
   **Manage Certificates… › + › Apple Development**.
5. Check it's there:
   ```bash
   security find-identity -v -p codesigning
   ```
   You should see an `Apple Development: …` line. Without it Bolo still builds, but macOS asks
   for Accessibility and Microphone again after every rebuild.

Full Xcode is required: Qwen runs on MLX, whose GPU kernels only compile under Xcode.

## 3. Get the code, test, install

```bash
git clone https://github.com/prguptadev/bolo.git ~/Developer/Bolo
cd ~/Developer/Bolo
scripts/test.sh                  # expect: all tests passed
scripts/build-app.sh --install   # builds, signs, copies to ~/Applications, launches
```

A microphone icon appears in the menu bar.

## 4. Grant permissions

1. **Accessibility**: macOS shows a prompt. Open System Settings › Privacy & Security ›
   Accessibility and switch **Bolo** on.
2. **Quit Bolo and open it again** (menu bar icon › Quit Bolo, then `open ~/Applications/Bolo.app`).
   The global key only starts working after a relaunch with Accessibility on.
3. **Microphone** and **Contacts**: allow when asked.
4. Menu bar icon › **Check setup…**: everything except Reminders and Calendar should be ✓.
   Those two, and **Automation** (for Messages, Notes, Mail), are asked the first time you use them.

## 5. Download the Qwen brain (once, 3.1 GB)

The phrase rules handle everyday commands instantly. For anything phrased differently (and for
trickier Hinglish), Bolo uses Qwen3.5-4B on the GPU. Download it once:

```bash
~/Applications/Bolo.app/Contents/MacOS/Bolo --download-brain
```

It prints a test sentence and how Qwen understood it. Bolo loads Qwen while you're talking and
unloads it after 5 idle minutes, so its ~3.2 GB of memory is only used while you use Bolo.

## 6. Best hearing

- Speak close to the Mac's microphones or use AirPods; Bolo already turns on Apple's noise
  suppression and echo cancellation.
- While holding the key once, open **Control Center › Mic Mode** and choose **Voice Isolation**.
  macOS remembers it for Bolo.
- Bolo builds a custom speech vocabulary from your contacts, nicknames and apps (a few seconds
  after launch, and again after **Reload contacts and apps**). To build it by hand and see if it
  worked: `~/Applications/Bolo.app/Contents/MacOS/Bolo --vocabulary`.

## 7. Add nicknames

Menu bar icon › **Nicknames…** opens the file. Add yourself first, for safe testing:

```json
{
  "myself": { "name": "Your Name", "phone": "+91 XXXXX XXXXX", "email": "you@company.com", "channel": "whatsapp" },
  "bhai":   { "name": "Rahul", "phone": "+91 XXXXX XXXXX", "channel": "whatsapp" },
  "priya":  { "name": "Priya Sharma", "email": "priya@company.com", "channel": "teams" }
}
```

WhatsApp needs a phone number (with +country code), Teams needs the person's work email. Save,
then menu bar icon › **Reload contacts and apps**. The Nickname field in the Contacts app works too.

## 8. Test, safest first

Hold the **right ⌥** key, speak, release. Stop anything with **Esc**.

| # | Say | Expect |
|---|---|---|
| 1 | "open notes" | Notes opens; notch shows ✓ Opened Notes |
| 2 | "volume 30" | Volume changes |
| 3 | "search youtube for lofi beats" | Browser opens YouTube results |
| 4 | "remind me in 2 minutes to test Bolo" | Reminders permission prompt, then a reminder that alerts in 2 min |
| 5 | "new note testing Bolo from my M5" | Automation prompt for Notes, then a new note |
| 6 | "myself ko whatsapp pe likho hello from Bolo" | Your own WhatsApp chat opens with the draft typed, **not sent** |
| 7 | "whatsapp myself saying hello from Bolo" | Same, and this time it **sends** |
| 8 | "Chrome kholo and search google for heap dump analysis" | Two steps, two ✓ |
| 9 | "teams myself saying test from Bolo" | Teams chat with yourself, sent |
| 10 | "join my next meeting" | Calendar prompt, then opens the meeting link (if one is in the next 3 h) |

Check how a sentence is understood without acting on it:

```bash
~/Applications/Bolo.app/Contents/MacOS/Bolo --say "bhai ko whatsapp karo on my way" --dry-run
```

## 9. Updating

After new code is pushed:

```bash
cd ~/Developer/Bolo && scripts/update.sh
```

It pulls, runs the tests, rebuilds, reinstalls and relaunches. Permissions carry over because the
signature stays the same.

## 10. When something goes wrong

Collect these and share them:

```bash
log show --last 10m --predicate 'subsystem == "dev.prgupta.bolo"' --info --style compact
tail -5 ~/Library/Application\ Support/Bolo/history.jsonl
```

Plus a screenshot of menu bar icon › **Check setup…**.

| Symptom | Likely cause |
|---|---|
| Holding right ⌥ does nothing | Accessibility is off, or Bolo wasn't relaunched after turning it on |
| The notch stays on "Listening…" or shows no words | Run `~/Applications/Bolo.app/Contents/MacOS/Bolo --listen 5` in Terminal and speak: it shows the live transcript, mic level and what Bolo would do |
| Notch says "Listening…" but no words appear | Microphone denied, or the speech model is still downloading (first use needs internet) |
| "I don't know who …" | Add the nickname, then Reload contacts and apps |
| WhatsApp opens but doesn't send | The log line `text box readable=… matched=…` shows why; Bolo won't send if the box doesn't hold your exact message |
| Permissions asked again after every update | No Apple Development certificate: see step 2 |
| A message was typed but not sent, notch says "heard it unclearly" | Speech confidence was below `minSendConfidence` (settings); speak closer, or lower it |
| Unusual sentences aren't understood | Qwen not downloaded (Check setup… shows it): step 5 |
