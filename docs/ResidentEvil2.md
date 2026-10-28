# Resident Evil 2 (Steam) on Whisky

The Steam copy of Resident Evil 2 (2019, app 883710) runs on DirectX 12 through
D3DMetal, cutscenes included, with the setup below. Tested on an M3 Pro with
macOS 26.6, this repo's `main` (app 3.7.0+), engine 4.0.0-beta.2 and Apple's
GPTK 4.0 beta 3.

## Fresh setup

1. Build and install the app, open it once and let it finish first-run setup.
2. Quit Whisky and run `scripts/re2-setup.sh engine`. It downloads the
   GPTK-capable engine 4.0.0-beta.2, verifies its digest, fixes its libiconv
   linkage and installs it (your current engine is kept as
   `Libraries-backup-<date>`).
3. Open Whisky, go to **Settings > Game Porting Toolkit** and import Apple's
   GPTK `.dmg` (download it from
   [developer.apple.com](https://developer.apple.com/download/all/?q=Game%20Porting%20Toolkit)
   with your Apple ID). Opening that page also deploys D3DMetal into the engine.
4. Create a bottle (for example "Steam"), quit Whisky, and run
   `scripts/re2-setup.sh bottle Steam`.
5. Install Steam in the bottle, log in, install and play Resident Evil 2.

If you only uninstall the game, nothing above needs redoing: the fixes live in
the engine and in the bottle's registry, not in the game folder.

## What the script changes, and why

| Change | Why |
|---|---|
| Engine 4.0.0-beta.2 (CrossOver 25, wine-10.0) | The wine 11 engines (4.6.4, 4.8.1) swap GSBASE between Windows and macOS code; RE Engine dies there within seconds (`_os_unfair_lock_unowned_abort`, `_dispatch_event_loop_end_ownership`, stack-cookie fail-fasts). The same recipe works on CrossOver-lineage wine 10 elsewhere (Sikarugir-App/Sikarugir#178). |
| Six engine libraries relinked to `/usr/lib/libiconv.2.dylib` | The build links glib, ffmpeg and others against a bundled libiconv that only exports `_libiconv*`. They import `_iconv*`, so GStreamer and winedmo never load ("GStreamer doesn't support H.264") and the game crashes on its first video. Later engines link the system libiconv the same way. |
| `HKCU\Software\Wine\MediaFoundation` `DisableGstByteStreamHandler=1` | The GStreamer media source fails (`Failed to construct MFMediaSource`) on the video RE2 opens when a cutscene ends or is skipped, and the game dereferences the missing source. The ffmpeg-based winedmo source handles it. |
| `AppDefaults\re2.exe\DllOverrides` `gameoverlayrenderer64=""` | Steam injects its overlay renderer even with the overlay disabled for the game. |
| Bottle: msync on, AVX off, Metal 4 off, MetalFX off | The settings the working runs used. Metal 4 and MetalFX have not been retested on this engine. |

## What stays manual

- **Apple's Game Porting Toolkit.** Its license does not allow redistribution,
  so each install imports its own copy.
- **Steam login and the game download.**

## Backups

Never commit a bottle. It holds your Steam login tokens, a copyrighted game and
tens of gigabytes. To keep one, use **Bottle > Export as Archive** in Whisky and
store the archive somewhere private; **File > Import Bottle** restores it.

## Troubleshooting

- **Crash right after a cutscene:** check the registry value with
  `wine reg query 'HKCU\Software\Wine\MediaFoundation'` in the bottle.
- **Crash on the first video, or `support H.264` errors in the log:** the engine
  was reinstalled without the libiconv fix. Run `scripts/re2-setup.sh engine`
  again; `otool -L .../Libraries/Wine/lib/libglib-2.0.0.dylib` should list
  `/usr/lib/libiconv.2.dylib`.
- **D3DMetal greyed out or missing after an engine swap:** open
  **Settings > Game Porting Toolkit** once so Whisky redeploys it.
