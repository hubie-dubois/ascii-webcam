# ASCII Webcam

Turn a live webcam feed into ASCII art. Use the standalone macOS app for a
point-and-click interface, or the original Python version in a terminal.

## Open the Mac app — no commands needed

1. In Finder, open this folder and double-click **ASCII Webcam.app**.
2. Click **Start camera** and allow camera access when macOS asks.
3. Adjust the picture using the controls below the preview.

You can drag **ASCII Webcam.app** into **Applications** and keep it in your Dock.
The app is self-contained: it does not need this folder, Python, packages, an
internet connection, or a running terminal. The included build is for Apple
silicon Macs running macOS 13 or newer.

### App controls

| Control | What it does |
| --- | --- |
| Camera menu | Choose a built-in, USB, or available Continuity Camera by name |
| Refresh | Look for connected cameras again |
| Start / Stop camera | Turn the live camera feed on or off |
| Try / Stop demo | Preview animated ASCII art without accessing the camera |
| Detail | Use fewer, larger characters or more, finer characters |
| Brightness | Move right to brighten shadows |
| Edges | Emphasize outlines |
| Color / Mirror / Invert | Change the rendering style |
| Characters | Choose Clean, Dense, Bold, or Thin character sets |
| Rotate | Turn the picture in 90-degree steps |
| Reset picture | Restore the default picture settings |
| Copy text | Copy the current frame as plain text; paste with a monospaced font |
| Save image | Save the current preview as a PNG using a normal save dialog |
| Camera access | Open macOS camera privacy settings |
| Full screen | Show just the video full screen; press Escape to return |
| Video output | Open a clean, video-only window for capture in OBS |
| FaceTime setup | Open the guided virtual-camera setup and check OBS availability |

### Full-screen video

Click **Full screen**, double-click either preview, or press **Control–Command–F**.
The picture opens in its own full-screen window without the adjustment controls.
Press **Escape** to leave full screen, then Escape again to close the video-only
window. **View → Show Controls** returns to the main app. Adjustments made in the
main app update both previews. Closing the main control window quits the app.

### Use in FaceTime with OBS Studio

The app does not install its own camera driver. The supported route uses the
free **OBS Studio** virtual camera. OBS 30+ on macOS 13+ uses Apple's modern
camera-extension system, which supports Mac calling apps. See
[OBS's compatibility and extension instructions](https://obsproject.com/kb/virtual-camera-troubleshooting).

Click **FaceTime setup…** in the app for these steps and convenient open buttons:

1. Start your physical camera in ASCII Webcam and click **Video output**. Keep
   that window open and unminimized. It contains the picture without controls,
   title text, or window buttons.
2. Install [OBS Studio](https://obsproject.com/download) in Applications and open
   it. Choose the virtual-camera option if the initial setup wizard appears.
3. In OBS's Sources box, click **+ → macOS Screen Capture**. Choose **Window
   Capture** and the window **ASCII Webcam — Video Output**. Turn off **Show
   cursor** and audio capture. macOS may request screen-recording permission.
   Right-click the source and use **Transform → Fit to screen**. The source
   supports individual-window capture; see
   [OBS's screen-capture guide](https://obsproject.com/kb/macos-screen-capture-source).
4. Click **Start Virtual Camera** in OBS. If macOS asks, approve OBS's camera
   extension in **System Settings → General → Login Items & Extensions → Camera
   Extensions**, then restart OBS. On macOS 13/14, approval is in **Privacy &
   Security** instead. Start the virtual camera again after approval.
5. In FaceTime, choose **Video → OBS Virtual Camera**. Keep your normal microphone
   selected. Apple documents camera selection in
   [FaceTime's Video menu](https://support.apple.com/guide/facetime/choose-a-camera-or-microphone-fctm26739220/mac).

Keep both apps running during the call. Do not select OBS Virtual Camera as the
input in ASCII Webcam, which would create a feedback loop. If you change the
output-window size, check that it still fits the OBS canvas. To stop sending the
feed, stop the virtual camera in OBS; stop the camera in ASCII Webcam as well.
The virtual camera only supplies video; FaceTime handles your microphone and call.

OBS installation, macOS permission approvals, and selecting the virtual camera
in FaceTime are required separately. The **FaceTime setup** panel checks whether
OBS and its camera are detected; detection alone does not verify a FaceTime call.

Picture settings and the selected camera are remembered between launches. The
camera starts only when you click **Start camera**. Closing the window quits the
app and stops capture. Stop leaves the last picture visible so you can save it.
Frames are processed on your Mac; the app has no video upload or network-streaming
feature. If you send its output to OBS and FaceTime, FaceTime transmits that video
to the participants in your call.

If camera access was denied, click **Camera access…**, enable **ASCII Webcam**,
then quit and reopen the app. If a camera is unavailable, close other apps using
it or select another camera. Demo mode is available even with no camera attached.

This is a locally built, ad-hoc-signed app, not an Apple-notarized distribution.
The native renderer has its own implementation; Python-only options such as
CLAHE and dithering are not part of the Mac app.

## Original terminal version

The Python version renders in a macOS terminal, with optional ANSI truecolor,
mirroring, rotation, contrast enhancement, and dithering.

### Setup

Use Python 3.9 or newer:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

### Run

```sh
.venv/bin/python ascii_art_webcam.py --list-cameras
.venv/bin/python ascii_art_webcam.py --camera 0 --width 180 --color --hud
```

The camera commands access your camera. macOS may ask for camera permission for
your terminal app. Try another index if the default camera cannot be opened.

Press `q` to quit, `c` to toggle color, `e` to cycle edge enhancement, `i` to
invert, `m` to mirror, and `h` to show or hide the status line. `Ctrl+C` also exits.
Use `--help` for all options.

- Output fits the current terminal; `--width` and `--height` are upper limits.
  One column is reserved to prevent wrapping. The status line is hidden when
  there is no room for it.
- `--gamma 0.7` brightens shadows; `--gamma 1.5` darkens them.
- `--chars ' .:-=+*#%@'` sets a darkest-to-brightest ramp. Use at least two
  different printable ASCII characters so every character occupies one cell.
- `--frames 100` exits after 100 rendered frames; `--fps 0` removes the frame cap.
- `--no-alt-screen` draws in the current terminal buffer.

### Camera-free checks

```sh
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python ascii_art_webcam.py --self-test --width 80 --height 24
.venv/bin/python ascii_art_webcam.py --self-test --color --dither --gamma 0.7
```

The tests use synthetic images and mocked camera/terminal objects. They cover
rendering, size limits, argument validation, and cleanup without opening a camera.

## Rebuilding the Mac app (developers only)

The ready-to-use app is already included. To rebuild after changing
`macos/ASCIIWebcam.swift`, use Xcode's command-line tools on an Apple silicon Mac:

```sh
bash scripts/build-macos.sh
"ASCII Webcam.app/Contents/MacOS/ASCII Webcam" --self-test
```

The build uses only Apple's SDK frameworks. `--self-test` checks the native
renderer without opening a camera; `--demo` opens the app in camera-free demo
mode. Camera authorization follows
[Apple's camera access API](https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:completionhandler:)).
