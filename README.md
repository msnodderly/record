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

## Build and run

1. Open `Record.xcodeproj` in Xcode.
2. Select the **Record** target, open **Signing & Capabilities**, enable automatic signing, and choose your team.
3. Connect and unlock an iPhone, choose it as the run destination, and press **Run** (`Command-R`).
4. Grant microphone permission on first use.

For a command-line compile check:

```bash
xcodebuild \
  -project Record.xcodeproj \
  -scheme Record \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Smoke test

Run these checks on a physical iPhone:

1. Start a recording, speak for a minute, lock the screen, wait another minute, unlock, and stop. Confirm the transcript includes speech from both periods.
2. Start another recording, speak long enough to produce visible text, then force-quit Record. Reopen it and wait for recovery to finish. Confirm a transcript appears.
3. Open the recovered transcript, use Share, and verify the same file appears in **Files → On My iPhone → Record**.
4. Delete an unneeded transcript from the list and confirm it disappears from Files.

For an hour-plus lecture, begin with a charged device and sufficient free storage. Temporary uncompressed PCM audio is stored for the duration of the session and removed only after the transcript is safely saved.

## Privacy and limitations

- Speech analysis is on-device. No recording or transcript is uploaded by this app.
- iOS may use the network to download a required speech model.
- Calls and other microphone interruptions end the active session after saving its captured portion.
- Force-quitting prevents any further background capture; audio recorded before termination is recovered on the next launch.
- Recovery protects against interrupted sessions, but no mobile app can guarantee capture after iOS terminates it, storage is exhausted, or the device loses power.
