# Record

Record is a small iPhone app for long-form, on-device transcription. It is designed for lectures and other recordings lasting an hour or more, including sessions where the screen is locked.

The app keeps the transcript, not the source recording. Audio is journaled temporarily so work can be recovered after an interruption or unexpected termination, then deleted after the transcript is saved successfully.

## Product specification

- Record and transcribe microphone audio entirely on the iPhone.
- Support long sessions without an app-imposed recording limit. Practical limits are available storage, battery life, and iOS resource management.
- Continue recording while the screen is locked or the app is in the background.
- Show finalized and in-progress transcription while the app is visible.
- Save completed transcripts as plain text files.
- Preserve useful work when recording is interrupted, the audio route changes, or the app terminates unexpectedly.
- Retain raw audio only while it is required for in-progress recovery.
- Make transcripts available in the app, the Files app, and the iOS share sheet.

## What is implemented

### Live, on-device transcription

`AVAudioEngine` captures microphone buffers and `SpeechAnalyzer` with `SpeechTranscriber` performs transcription. Audio is converted into the analyzer's preferred format before it is streamed into the analysis pipeline. The app selects the best supported locale, falling back to US English or another available locale.

Transcription does not require a network connection after the device has the appropriate speech model. iOS may perform a one-time model download before the first recording for a locale.

### Readable paragraph heuristics

`SpeechTranscriber` returns timed recognition chunks, not semantic paragraph or topic labels. Record turns those chunks into readable plain text using conservative, deterministic heuristics:

- a pause of at least two seconds starts a new paragraph;
- a pause of at least 1.25 seconds starts a new paragraph when the previous sentence is complete and the current paragraph is already at least 200 characters; and
- shorter pauses join chunks with normal sentence spacing.

The formatting runs live and during crash recovery, entirely on-device. These are presentation heuristics rather than topic detection, and the API does not currently provide speaker diarization.

### Long recordings and background operation

The app configures an `AVAudioSession` for recording and declares the `audio` background mode. Recording can therefore continue when Record is backgrounded or the screen locks; there is no need to keep the screen awake or periodically interact with it.

Record intentionally does not disable Auto-Lock. A locked screen saves battery during long sessions.

### Durable temporary journal

While a session is active, analyzer-compatible PCM audio is written to private Application Support storage as five-minute CAF segments. Finalized transcript text is checkpointed alongside those segments.

Segmenting limits the amount of audio at risk if the process is terminated while a file is open. If a write fails, recording stops safely and the transcript captured so far is saved when possible.

### Stop, interruption, and recovery behavior

- Normal stop finalizes the analyzer, saves a `.txt` transcript, and deletes the temporary audio journal.
- Phone calls, system audio interruptions, microphone changes, and audio-route changes stop the session safely and save the portion captured before the interruption.
- On launch, any journal left by a crash or force-quit is transcribed again. The recovered transcript is saved and the temporary audio is deleted.
- If full recovery is not possible, the finalized text checkpoint is saved when available and the temporary journal remains for another recovery attempt.
- Raw audio is not exposed in Documents and is not retained after a successful transcript save.

An interruption ends the current recording rather than resuming it automatically. This makes the save boundary explicit and avoids silently missing audio while iOS owns the microphone.

### Transcript storage

Transcripts are named `Recording YYYY-MM-DD at HH.mm.ss.txt` and stored in the app's Documents directory. They can be:

- opened and deleted inside Record;
- shared from the transcript detail screen; or
- accessed under **On My iPhone → Record** in the Files app.

## Project layout

- `Record/RecordingController.swift` — recording lifecycle, speech analysis, interruptions, and recovery.
- `Record/RecordingJournal.swift` — temporary manifest, transcript checkpoint, and segmented CAF writer.
- `Record/BufferConverter.swift` — microphone-to-analyzer audio conversion.
- `Record/TranscriptStore.swift` — durable plain-text transcript storage.
- `Record/ContentView.swift` — recording UI, recovery state, transcript list, sharing, and deletion.
- `Record/Info.plist` — microphone permission, Files integration, and audio background mode.

## Requirements

- Xcode 26 or later.
- A physical iPhone running iOS 26 or later. The on-device speech models are not available in the Simulator.
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

For an hour-plus lecture, begin with a charged device and sufficient free storage. Temporary uncompressed PCM audio is stored for the duration of the session and removed only after the transcript is safely saved.

## Privacy and limitations

- Speech analysis is on-device. No recording or transcript is uploaded by this app.
- iOS may use the network to download a required speech model.
- Calls and other microphone interruptions end the active session after saving its captured portion.
- Force-quitting prevents any further background capture; audio recorded before termination is recovered on the next launch.
- Recovery protects against interrupted sessions, but no mobile app can guarantee capture after iOS terminates it, storage is exhausted, or the device loses power.
