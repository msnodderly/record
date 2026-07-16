# Record
I just wanted to take notes by talking to my iPhone. This is a super-simple 100% on-device iPhone transcription app. So simple it doesn't even have a name. 

Transcribes audio, cleans it up, lets you copy or share the text. That's it.

Connect your iPhone with iOS 26+ to your Mac running MacOS 15.7+, point your favorite AI agent at this README.md and tell it to figure out how to build and install it for you. 

Good luck! -Matt



## Features
The app stores only the text transcript, not the recording.

Audio is saved temporarily so work can be recovered after an interruption or unexpected termination, then deleted after the transcript is saved successfully.

- Record and transcribe microphone audio entirely on the iPhone.
- Continue recording while the screen is locked or the app is in the background.
- Allow pausing and resuming an active session.
- Show finalized and in-progress transcription while the app is visible.
- Save completed transcripts as plain text files.
- After each recording, clean up the transcript text, generate a title, and label speakers in multi-speaker recordings — all on-device.

## What is implemented

### Live, on-device transcription

`AVAudioEngine` captures microphone buffers and `SpeechAnalyzer` with `SpeechTranscriber` performs transcription. Audio is converted into the analyzer's preferred format before it is streamed into the analysis pipeline. The app selects the best supported locale, falling back to US English or another available locale.

Transcription does not require a network connection after the device has the appropriate speech model. iOS may perform a one-time model download before the first recording for a locale.

### Post-recording enhancement pass

After a transcript is saved (or recovered), Record runs a best-effort enhancement pass, entirely on-device:

1. **Speaker diarization** — the journaled audio is analyzed with [FluidAudio](https://github.com/FluidInference/FluidAudio) CoreML models. When more than one substantial speaker is detected (at least 5% of talk time and 10 seconds each), paragraphs are prefixed with `Speaker 1:`, `Speaker 2:`, and so on. Single-speaker recordings such as lectures stay unlabeled. The first run downloads the diarization models (about 100 MB, cached afterward).
2. **Text cleanup** — on Apple Intelligence devices, the on-device Foundation Models LLM fixes punctuation and casing, corrects context-obvious mishearings (for example "Asians" → "agents" in a software discussion), and removes filler words, processing the transcript in small batches. When acoustic diarization found only one voice but the text is clearly an interview or podcast, the cleanup stage also labels speaker turns from conversational context. Batches the model cannot improve are kept verbatim.
3. **Title** — one guided-generation call names the file after the specific topic discussed.

Every stage degrades independently: if diarization fails there are no speaker labels, if the language model is unavailable the text stays raw, and if title generation fails the date-based filename is kept. The raw transcript is durable on disk before the pass begins, and the pre-enhancement original remains viewable from the transcript detail screen. New recordings are disabled while a pass is running (typically one to two minutes for an hour-long session, with progress shown).

### Long recordings and background operation

The app configures an `AVAudioSession` for recording and declares the `audio` background mode. Recording can therefore continue when Record is backgrounded or the screen locks; there is no need to keep the screen awake or periodically interact with it.

Record intentionally does not disable Auto-Lock. A locked screen saves battery during long sessions.

### Durable temporary journal

While a session is active, analyzer-compatible PCM audio is written to private Application Support storage as five-minute CAF segments. Finalized transcript text is checkpointed alongside those segments.

Segmenting limits the amount of audio at risk if the process is terminated while a file is open. If a write fails, recording stops safely and the transcript captured so far is saved when possible.

### Stop, interruption, and recovery behavior

- Normal stop finalizes the analyzer and saves a `.txt` transcript before anything else happens. The temporary audio journal is deleted as soon as the enhancement pass has read it for speaker analysis (immediately, if diarization is skipped).
- A `transcript-saved` marker is written to the journal the moment the transcript reaches Documents. If the app dies during the enhancement pass, the next launch discards the marked journal instead of recovering it into a duplicate transcript.
- Phone calls, system audio interruptions, microphone changes, and audio-route changes stop the session safely and save the portion captured before the interruption.
- On launch, any unmarked journal left by a crash or force-quit is transcribed again. The recovered transcript is saved, enhanced, and the temporary audio is deleted.
- If full recovery is not possible, the finalized text checkpoint is saved when available and the temporary journal remains for another recovery attempt.
- Raw audio is not exposed in Documents and is not retained after a successful transcript save.

An interruption ends the current recording rather than resuming it automatically. This makes the save boundary explicit and avoids silently missing audio while iOS owns the microphone.

## Requirements

- Xcode 26 or later.
- A physical iPhone running iOS 26 or later. The on-device speech models are not available in the Simulator.
- An Apple Intelligence-capable iPhone with Apple Intelligence enabled for transcript cleanup and title generation. Without it, those stages are skipped silently; recording, transcription, and speaker labeling still work.
- An Apple signing team. A free Personal Team is sufficient for installing on your own iPhone, though Personal Team builds generally need to be reinstalled after their provisioning period expires.

## Deployment

The project currently supports development deployment to a personally owned iPhone. TestFlight and App Store distribution are not configured.

### First-time signing setup

1. Open Xcode, then choose **Xcode → Settings → Accounts**.
2. Add an Apple ID. A free account creates a **Personal Team** and is sufficient for installing Record on your own device.
3. Open `Record.xcodeproj`.
4. Select the **Record** target, open **Signing & Capabilities**, and enable **Automatically manage signing**.
5. Choose your team. The checked-in bundle identifier is `com.mds.Record`; if Xcode reports that it is unavailable, change it to a unique identifier you control.
6. On the iPhone, enable **Settings → Privacy & Security → Developer Mode** if iOS requests it, then restart the phone as directed.

Personal Team provisioning normally expires after seven days. Rebuild and reinstall the app using the same bundle identifier when it expires. A paid Apple Developer Program membership is not required for this personal-device workflow.

### Deploy with Xcode

1. Connect the iPhone by cable, unlock it, and accept **Trust This Computer** if prompted.
2. Select the iPhone in Xcode's run-destination menu.
3. Press **Run** (`Command-R`). Xcode builds, signs, installs, and launches Record.
4. Grant microphone permission on first use. If iOS blocks the first launch as an untrusted developer, open **Settings → General → VPN & Device Management**, select the developer identity, and trust it.

Subsequent deployments use the same steps. Installing a newer build with the same bundle identifier preserves the app's Documents container under normal development-install behavior. Do not delete the app if its transcripts have not been exported; uninstalling removes its local data.

### Deploy from the command line

The following is the command-line equivalent of the deployment used during development.

First, list paired devices and copy the target iPhone's identifier:

```bash
xcrun devicectl list devices
```

Build and sign the app. Xcode obtains or refreshes the provisioning profile when needed:

```bash
xcodebuild \
  -project Record.xcodeproj \
  -scheme Record \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/record-device-build \
  -allowProvisioningUpdates \
  build
```

Install and launch it, replacing `<DEVICE-ID>` with the identifier reported above. If the bundle identifier was changed, also replace `com.mds.Record` in the launch command.

```bash
xcrun devicectl device install app \
  --device '<DEVICE-ID>' \
  /tmp/record-device-build/Build/Products/Debug-iphoneos/Record.app

xcrun devicectl device process launch \
  --device '<DEVICE-ID>' \
  com.mds.Record
```

Keep the iPhone unlocked while installing or launching. To deploy an update, repeat the build, install, and launch commands.

### Compile without signing

For CI or a local compile check that does not install the app:

```bash
xcodebuild \
  -project Record.xcodeproj \
  -scheme Record \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Deployment troubleshooting

- **No signing certificate or team:** sign in again under **Xcode → Settings → Accounts**, then reselect the team under **Signing & Capabilities**.
- **Bundle identifier unavailable:** replace `com.mds.Record` with a unique reverse-DNS identifier in the target's Signing settings.
- **Device unavailable:** unlock the phone, reconnect the cable, accept the trust prompt, and rerun `xcrun devicectl list devices`.
- **Provisioning profile expired:** rebuild with Xcode or rerun the signed command-line deployment. This is expected periodically with a Personal Team.
- **Launch is blocked:** enable Developer Mode and trust the developer identity in the iPhone settings described above.
- **Speech model preparation takes time:** keep the app open and online for the first recording in a new language so iOS can download its on-device model.

TestFlight or App Store deployment would additionally require a paid Apple Developer Program membership, distribution signing, an archived Release build, App Store Connect configuration, privacy details, and review. None of those release artifacts are currently included in this repository.

## Smoke test

Run these checks on a physical iPhone:

1. Start a recording, speak for a minute, lock the screen, wait another minute, unlock, and stop. Confirm the transcript includes speech from both periods.
2. Record one sentence, pause silently for at least three seconds, then record another sentence. Stop and confirm the saved transcript has a blank line between them.
3. Start another recording, speak long enough to produce visible text, then force-quit Record. Reopen it and wait for recovery to finish. Confirm a transcript appears.
4. Open the recovered transcript, use Share, and verify the same file appears in **Files → On My iPhone → Record**.
5. Delete an unneeded transcript from the list and confirm it disappears from Files.
6. Record a short solo memo online and wait for **Enhancing transcript…** to finish. Confirm the file is renamed to a topic, has no speaker labels, and offers **View original** in the detail screen. Rename it and confirm the new name appears in Files and **View original** still works.
7. Record a few minutes of two people conversing. Confirm the enhanced transcript labels turns with `Speaker 1:` and `Speaker 2:`.
8. Start a recording, tap pause, speak (the transcript must not grow), tap resume, speak again, and stop. Confirm the post-resume speech begins a new paragraph.
9. Force-quit the app while **Enhancing transcript…** is showing. Relaunch and confirm exactly one transcript exists for that recording (unenhanced) and no recovery pass runs for it.

For an hour-plus lecture, begin with a charged device and sufficient free storage. Temporary uncompressed PCM audio is stored for the duration of the session and removed only after the transcript is safely saved.

## Privacy and limitations

- Speech analysis, speaker diarization, transcript cleanup, and title generation are all on-device. No recording or transcript is uploaded by this app.
- iOS may use the network to download a required speech model, and the first enhancement pass downloads speaker-diarization models (about 100 MB). Only models are downloaded; no audio or text is sent.
- Transcript cleanup and metadata generation require an Apple Intelligence device and are skipped otherwise; the transcript is then kept exactly as transcribed.
- The enhancement pass may be cut short if the app is backgrounded right after a long recording stops; the saved transcript is never at risk, it just stays unenhanced.
- Calls and other microphone interruptions end the active session after saving its captured portion.
- Force-quitting prevents any further background capture; audio recorded before termination is recovered on the next launch.
- Recovery protects against interrupted sessions, but no mobile app can guarantee capture after iOS terminates it, storage is exhausted, or the device loses power.

## License

Record is released under the [MIT License](LICENSE).
