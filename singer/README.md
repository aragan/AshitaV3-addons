# Singer (Ashita v3) — No HUD
**Author:** Aragan  
**Version:** 1.1 ,version transformers coming.

This package is **Ashita v3 ONLY** (LuaJIT / Lua 5.1).  
It is a lightweight Singer addon (no HUD) that cycles through BRD song playlists.

- **Playlists source:** `settings.lua` (old-style playlists table)  
- **Saved settings:** `configs.xml` (single file)  
- **Auto-start on load:** **Disabled** (the addon will NOT start singing just because it was ON previously)

**Version:** `1.0-v3-playlists-from-settingslua`

---

## Folder Contents

```
addons/singer/
  singer.lua
  settings.lua
  configs.xml
```

---

## Install

1. Unload old version (if loaded):
   - `/addon unload singer`
2. Delete the old folder:
   - `addons/singer/`
3. Copy this new `singer` folder into:
   - `Ashita/addons/`
4. Load it:
   - `/addon load singer`

---

## Playlists (settings.lua)

Playlists MUST be defined inside `settings.lua` in a table named `playlist`.
Example:

```lua
return {
    playlist = {
        ["ongo"]  = { "Learned Etude", "Sage Etude", "Mage's Ballad III", "Victory March", "Mage's Ballad II" },
        ["range"] = { "Honor March", "Valor Minuet V", "Valor Minuet IV", "Archer's Prelude", "Valor Minuet III" },
    },
}
```

> Notes:
> - Playlist names are **case-insensitive** when using `/singer playlist <name>`.
> - The addon does **NOT** auto-save or edit playlists. You edit `settings.lua` manually.

---

## Basic Usage

### 1) Choose a playlist
- `/singer playlist ongo`

When you select a playlist, the addon prints the playlist name and song list in chat.

### 2) Start / Stop
- `/singer on`      → enable auto cycling (does not auto-start on addon load)
- `/singer off`
- `/singer toggle`
- `/singer status`

### 3) Cast once now (manual)
- `/singer now`

---

## Settings Commands

### Delay between songs
- `/singer delay <seconds>`
  - Minimum: `0.5`

### Cycle interval
- `/singer interval <seconds>`
  - Minimum: `30`

### Target
- `/singer target <target>`
  - Examples: `<me>`, `<t>`

### Repeat
- `/singer repeat on|off|toggle`
  - If repeat is OFF, auto-cycle runs once per enable; you can still use `/singer now`.

### List playlists (safe paging)
- `/singer playlists`   → show playlist names (10 per call; repeat to see next page)
- `/singer playlist <name>`

---

## Job Abilities Toggles

### Nitro (Nightingale + Troubadour)
- `/singer nitro on|off|toggle`

### CCSV (Clarion Call + Soul Voice)
- `/singer ccsv on|off|toggle`

---

## Marcato System

There are **two Marcato modes**:

### A) Marcato by index (when Marcato is ON)
Enable Marcato and choose **which song number** gets Marcato:

- `/singer marcato on`
- `/singer marcato 1`  → Marcato on **1st song**
- `/singer marcato 2`  → Marcato on **2nd song**
- `/singer marcato 3`  → etc...

> This index is **saved** in `configs.xml` as `marcato_index`.

### B) Marcato by song name (when Marcato is OFF)
If you want Marcato on a **specific song name** (matching the playlist song text), keep Marcato OFF and set a saved Marcato song:

- `/singer marcato off`
- `/singer marcato "Mage's Ballad II"`

Then, during the cycle, Marcato will be used **right before the matching song** (once per cycle).

> The saved song name is stored in `configs.xml` as `marcato_song`.

---

## Persistence (configs.xml)

Saved fields include:
- enabled (forced OFF on addon load)
- repeat
- delay
- cycle interval
- target
- active playlist name
- nitro / ccsv
- marcato on/off
- marcato_index
- marcato_song

✅ Even if it was ON before, after you reload the addon it stays OFF (no auto-start).

---

## Troubleshooting

### “Set not found: <name>”
- Make sure `settings.lua` is in `addons/singer/`
- Make sure your playlists are inside `playlist = Ellipsis`
- Run `/singer playlists` to confirm the addon sees your names.

### It starts singing immediately after load
- This build disables auto-start. If it still happens, you likely still have an old copy loaded.
  - Delete the whole `addons/singer/` folder and reinstall.

---

## Notes

- Ashita v3 only.
- No HUD / no screen drawing.
- Chat output is in English.
