# ConFriKa Sign — browser extension (live camera)

Sign in web video calls (Google Meet, Zoom web, etc.). The extension reads your
signing **live from the webcam**, turns it into **speech** (so the other person
hears it on the call) and shows **captions** of what they say back.

## How it works

```
webcam → MediaPipe HandLandmarker (21 landmarks, on-device)
       → recognizer.js  (same geometry as the backend recognizer)
       → letters/digits/phrases → words → spoken aloud + on-screen
their speech → Web Speech API → captions
```

All recognition runs **on your device** — no login, no video leaves the browser.

## Install (developer mode)

1. Fetch the MediaPipe runtime + model (one time):
   ```bash
   ./fetch-vendor.sh
   ```
2. In Chrome/Edge, open `chrome://extensions`, enable **Developer mode**, click
   **Load unpacked**, and select this `browser-extension/` folder.
3. Click the ConFriKa Sign toolbar icon to open the side panel next to your call.
4. **Start camera**, sign a letter and hold briefly; lower your hand to end a
   word. Keep your speaker on so the other person hears your spoken signs.

## Notes

- Fingerspelling covers the geometrically-distinct ASL letters + digits; use the
  **phrase palette** for common whole signs. Ambiguous letters (M/N/S/T, J, Z)
  are intentionally not guessed.
- `vendor/` (MediaPipe wasm + model, a few MB) is git-ignored; `fetch-vendor.sh`
  repopulates it.
- Requires a Chromium browser with the Side Panel API (Chrome/Edge 114+).
