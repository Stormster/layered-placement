# Layered Placement

**A quality-of-life mod for [Project Zomboid](https://projectzomboid.com/) (Build 42)** that makes furniture placement feel closer to the admin brush — without giving up normal Pickup / Place Furniture gameplay.

Available on the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3775423228).

---

## What it does

In vanilla Project Zomboid, decorating with Move Furniture is limited: lights, posters, and other wall or ceiling items often cannot sit where you want them. Layered Placement loosens those placement rules so you can decorate more freely while still using the standard furniture tools.

- Hang lights over tables, counters, and other furniture  
- Place lamps and decor on railings and catwalks  
- Toggle floating or railing-mounted lights without the railing stealing your clicks  
- Keep normal floor stacking (crates, tables, and so on) and the usual skill / tool requirements  

Each feature has its own toggle in Mod Options, so players can enable only what they want.

Compatible with **Build 42.20+**, safe to add mid-save, and designed for **multiplayer** (enable on the server and all clients).

---

## Play the mod

Subscribe on Steam — that is the supported way to install and receive updates:

**[Layered Placement on Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3775423228)**

Please do not reupload the mod.

---

## Technical notes

This repository contains the Lua source for the mod: client-side placement and interaction logic, shared placement checks, and server commands so floating light state and multiplayer placement stay in sync.

Built for Project Zomboid’s Lua modding API (client / shared / server scripts under `LayeredPlacement/`).

### Local development

Run `./tools/sync.ps1` after editing to push the mod into `Zomboid\mods\` and the Workshop staging folder in one step, or `./tools/sync.ps1 -Watch` to keep syncing on every save.

Do not link these folders with a junction or symlink. Project Zomboid's mod scanner treats a reparse point as a file, so a linked mod folder silently fails to load and a linked staging folder is rejected on upload with *"Files are not allowed in the Contents/mods/ folder"*. The sync script copies for that reason, and removes any link it finds in a destination.

---

## Author

**Storm** — Project Zomboid mod author

Workshop ID: `3775423228`
