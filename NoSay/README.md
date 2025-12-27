# NoSay (Ashita v3 Addon)

**Author:** Aragan  
**Version:** 1.1

NoSay blocks **/say** before it is sent, so you don’t accidentally talk in **Say**.

It also protects you from typing **bare text** (messages without `/`) when your default channel is Say.

---

## Install (Ashita v3)

Copy this folder into:
```
Ashita4/addons/
```

You must have:
- `Ashita4/addons/nosay/nosay.lua`
- `Ashita4/addons/nosay/settings/settings.json`

---

## Load / Unload

Load in-game:
```
/addon load nosay
```

Unload:
```
/addon unload nosay
```

---

## Commands

Use:
```
/nosay <command>
```

### Main
- `/nosay on`  
- `/nosay off`  
- `/nosay toggle`  
- `/nosay status`

### Strict Mode (optional)
Strict mode blocks **any** message typed without `/`.

- `/nosay strict on`
- `/nosay strict off`
- `/nosay strict toggle`

### Notifications
- `/nosay notify on`
- `/nosay notify off`

---

## Bypass (Allow Prefix)

Default allow prefix is:
```
!!
```
If you want to say anything use `/say !!hello` or just `!!hello` in the chatbox.

Examples:
- `/say !!hello`  => sends `hello` (one-time bypass, prefix removed)
- `!!hello`       => allows bare text (prefix removed)

---

## Settings File

Settings are stored here:
```
Ashita4/addons/nosay/settings/settings.json
```

This file supports optional per-character overrides by adding a key with your character name:
```json
{
  "global": { "strict_mode": false },
  "aragan": { "strict_mode": true }
}
```

> Note: Character keys are matched case-insensitively.

---
