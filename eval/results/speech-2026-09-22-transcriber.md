# Phase 0 speech eval — 2026-09-22

50 recorded prompts.

| Engine | Word error rate | Hinglish WER | End-to-end fully right | Unsafe sends | Mean confidence | Median time | Model load |
|---|---|---|---|---|---|---|---|
| transcriber (en_IN) | 22% | 24% | 28/50 (56%) | 7 | 0.83 | 74 ms | 0.0 s |

## transcriber (en_IN)

- ✗ `p01` said "open notes" → heard "Open Intelligent" (conf 0.91) → `[{"action": "openApp", "app": "IntelliJ IDEA"}]`
- ✓ `p02` said "Chrome kholo" → heard "Chrome, Kholo" (conf 0.8) → `[{"action": "openApp", "app": "Google Chrome"}]`
- ✓ `p03` said "open intellij" → heard "Open Intelligent." (conf 0.77) → `[{"action": "openApp", "app": "IntelliJ IDEA"}]`
- ✓ `p04` said "launch whatsapp" → heard "Launch WhatsApp" (conf 0.99) → `[{"action": "openApp", "app": "WhatsApp"}]`
- ✓ `p05` said "open github dot com" → heard "Open get up.com" (conf 0.68) → `[{"action": "openURL", "text": "github.com"}]`
- ✓ `p06` said "bhai ko WhatsApp karo I'll be late by 20 minutes" → heard "Bhai Ko, WhatsApp Kar Do, I'll be late by 20 minutes." (conf 0.9) → `[{"action": "sendMessage", "channel": "whatsapp", "contact": "Bhai", "text": "I'll be late by 20 minutes"}]`
- **UNSAFE** `p07` said "mom ko message bhejo ki main ghar pahunch gaya" → heard "Mom, Ko, message, Bhejo, Mein, Ghar, Ponj Gya." (conf 0.45) → `[{"action": "sendMessage", "contact": "Mom", "text": "Mein Ghar Ponj Gya"}]`
- **UNSAFE** `p08` said "Priya ko teams pe message karo joining in 5" → heard "Priya Ko, Team Pe message Karo joining in five minutes." (conf 0.73) → `[{"action": "sendMessage", "channel": "teams", "contact": "Priya", "text": "joining in five minutes"}]`
- ✓ `p09` said "send a teams message to Priya saying the build is green" → heard "Send a team message to Priya, saying the build is green." (conf 0.89) → `[{"action": "sendMessage", "channel": "teams", "contact": "Priya", "text": "the build is green"}]`
- ✓ `p10` said "whatsapp myself saying hello from Bolo" → heard "WhatsApp myself saying hello from Bolo?" (conf 0.89) → `[{"action": "sendMessage", "channel": "whatsapp", "contact": "myself", "text": "hello from Bolo"}]`
- **UNSAFE** `p11` said "text mom I'm leaving office now" → heard "Text mom I'm leaving from office now." (conf 0.96) → `[{"action": "sendMessage", "contact": "mom", "text": "I'm leaving from office now"}]`
- ✓ `p12` said "tell bhai on whatsapp that I'll call him tonight" → heard "Tell Bhai on WhatsApp that I'll call him tonight." (conf 0.94) → `[{"action": "sendMessage", "channel": "whatsapp", "contact": "Bhai", "text": "I'll call him tonight"}]`
- **UNSAFE** `p13` said "papa ko bol do main 10 minute mein aa raha hoon" → heard "Papa Ko, Bol, Do, Main, Das, Minute, Mein, Ara, Hoon." (conf 0.49) → `[{"action": "sendMessage", "contact": "Papa", "text": "Main Das Minute Mein Ara Hoon"}]`
- ✗ `p14` said "mom ko whatsapp pe likho dinner at 8 is fine" → heard "Mom, Ko, WhatsApp Pe Niko, dinner at eight is fine." (conf 0.75) → `[{"action": "draftMessage", "channel": "whatsapp", "contact": "Mom", "text": "dinner at eight is fine"}]`
- ✓ `p15` said "open bhai's whatsapp chat" → heard "Open Bhai's WhatsApp chat." (conf 0.88) → `[{"action": "draftMessage", "channel": "whatsapp", "contact": "Bhai"}]`
- **UNSAFE** `p16` said "open whatsapp chat with mom and send reached home" → heard "Open WhatsApp chat with mom and send a message to reach home." (conf 0.92) → `[{"action": "sendMessage", "channel": "whatsapp", "contact": "mom", "text": "to reach home"}]`
- ✓ `p17` said "teams call Priya" → heard "Team call Priya." (conf 0.9) → `[{"action": "call", "channel": "teams", "contact": "Priya"}]`
- ✓ `p18` said "call Rahul on teams" → heard "Call Rahul on teams." (conf 0.84) → `[{"action": "call", "channel": "teams", "contact": "Rahul"}]`
- ✗ `p19` said "new note groceries milk eggs bread" → heard "New note, grocery milk, egg bread." (conf 0.68) → `[{"action": "newNote", "text": "grocery milk egg bread"}]`
- ✗ `p20` said "note down the demo is on Friday" → heard "Notes down demo is on Friday." (conf 0.93) → `[{"action": "newNote", "text": "demo is on Friday"}]`
- ✓ `p21` said "remind me at 5 pm to call bhai" → heard "Remind me at 5 PM to call Bhai." (conf 0.87) → `[{"action": "addReminder", "text": "call Bhai", "time": "at 5 PM"}]`
- ✓ `p22` said "remind me in 10 minutes to check the build" → heard "Remind me in 10 minutes to check the build." (conf 0.9) → `[{"action": "addReminder", "text": "check the build", "time": "in 10 minutes"}]`
- ✗ `p23` said "search youtube for G1GC tuning" → heard "Search YouTube for Jeevan GC Twinning." (conf 0.65) → `[{"action": "webSearch", "text": "Jeevan GC Twinning"}]`
- ✗ `p24` said "google jvm heap dump analysis" → heard "Google JBM heap dump analysis" (conf 0.89) → `[{"action": "webSearch", "text": "JBM heap dump analysis"}]`
- ✗ `p25` said "play lofi beats on youtube" → heard "Playing Lofi beat on YouTube?" (conf 0.83) → `[{"action": "webSearch", "text": "Lofi beat"}]`
- ✓ `p26` said "join my next meeting" → heard "Joining my next meeting?" (conf 0.93) → `[{"action": "joinNextMeeting"}]`
- ✓ `p27` said "volume 30" → heard "Volume up to 30" (conf 0.97) → `[{"action": "setVolume", "number": 30}]`
- ✓ `p28` said "mute" → heard "Mute" (conf 0.95) → `[{"action": "mute"}]`
- ✓ `p29` said "lock the screen" → heard "Lock the screen." (conf 0.98) → `[{"action": "lockScreen"}]`
- ✗ `p30` said "run my standup shortcut" → heard "Run my stand-up shortcut." (conf 0.87) → `[{"action": "runShortcut", "text": "stand-up"}]`
- ✗ `p31` said "type thanks will review today" → heard "Type, thank will review today." (conf 0.8) → `[{"action": "typeText", "text": "thank will review today"}]`
- **UNSAFE** `p32` said "send a teams message to Priya saying joining in 5 and remind me at 5 pm to call her" → heard "Send a team message to Priya, saying joining in five minutes, remind me at 5 PM to call her." (conf 0.84) → `[{"action": "sendMessage", "channel": "teams", "contact": "Priya", "text": "joining in five minutes"}, {"action": "addReminder", "text": "call her", "time": "at 5 PM"}]`
- ✓ `p33` said "open teams and then bhai ko whatsapp karo on my way" → heard "Open teams, and then Bhai Ko, WhatsApp Karo, on my way." (conf 0.84) → `[{"action": "openApp", "app": "Microsoft Teams"}, {"action": "sendMessage", "channel": "whatsapp", "contact": "Bhai", "text": "on my way"}]`
- ✓ `p34` said "Chrome kholo aur google karo spring boot actuator" → heard "Chrome, Kholo, or Google, Karo, spring boot actuator." (conf 0.68) → `[{"action": "openApp", "app": "Google Chrome"}, {"action": "webSearch", "text": "spring boot actuator"}]`
- ✓ `p35` said "whatsapp bhai saying bring milk and call me when you reach" → heard "WhatsApp be saying bring milk and call me when you reach." (conf 0.88) → `[{"action": "sendMessage", "channel": "whatsapp", "contact": "bhai", "text": "bring milk and call me when you reach"}]`
- ✓ `p36` said "could you pull up my calendar" → heard "Could you pull up my calendar?" (conf 0.98) → `[{"action": "openApp", "app": "Calendar"}]`
- ✗ `p37` said "I need to tell bhai on whatsapp that I'm stuck in traffic" → heard "I need to tell Bhai on WhatsApp that I am stuck in track." (conf 0.86) → `[{"action": "draftMessage", "app": "WhatsApp", "channel": "whatsapp", "contact": "Bhai", "text": "I am stuck in track."}]`
- **UNSAFE** `p38` said "let priya know on teams that the deployment is done" → heard "Let Priya know on teams that deployment is done." (conf 0.91) → `[{"action": "sendMessage", "channel": "teams", "contact": "Priya", "text": "deployment is done"}]`
- ✗ `p39` said "jot down call the plumber tomorrow" → heard "Shut down the call, plumber tomorrow." (conf 0.82) → `[]`
- ✓ `p40` said "don't let me forget to pay the electricity bill at 7 pm" → heard "Don't let me forget to pay the electricity bill at 7 PM." (conf 0.94) → `[{"action": "addReminder", "text": "pay the electricity bill", "time": "at 7 PM"}]`
- ✓ `p41` said "turn the volume down to 20" → heard "Turn the volume to 20." (conf 0.83) → `[{"action": "setVolume", "number": 20}]`
- ✗ `p42` said "find me some videos on kotlin coroutines" → heard "Find me some video on Cortland Korotine." (conf 0.68) → `[{"action": "webSearch", "contact": "Cortland Korotine", "text": "video on Cortland Korotine"}]`
- ✓ `p43` said "bhai ko call karo teams pe" → heard "Bhai, Ko, call Karo teams, Pe" (conf 0.76) → `[{"action": "call", "channel": "teams", "contact": "Bhai"}]`
- ✗ `p44` said "mujhe 6 baje yaad dilana ki gym jaana hai" → heard "Mujhe, Che, Baji, Ya, De, Lana, Ki, Jim, Jana Hai?" (conf 0.46) → `[{"action": "addReminder", "text": "Jim Jana Hai", "time": "6 baje"}]`
- ✓ `p45` said "message priya that I'll be 10 minutes late" → heard "Message Priya that I'll be 10 minutes late." (conf 0.95) → `[{"action": "sendMessage", "contact": "Priya", "text": "I'll be 10 minutes late"}]`
- ✓ `p46` said "open calculator" → heard "Open calculator" (conf 0.88) → `[{"action": "openApp", "app": "Calculator"}]`
- ✗ `p47` said "what's the weather like" → heard "What's the weather like?" (conf 1) → `[{"action": "webSearch", "text": "weather"}]`
- ✗ `p48` said "I was thinking about messaging bhai later" → heard "I was thinking about the message bye later." (conf 0.88) → `[{"action": "draftMessage", "app": "Slack", "channel": "slack", "contact": "bye", "number": 0, "text": "later", "time": "now"}]`
- ✓ `p49` said "hmm" → heard "Hmm." (conf 0.66) → `[]`
- ✓ `p50` said "tell me a joke" → heard "Tell me a joke?" (conf 0.94) → `[]`
