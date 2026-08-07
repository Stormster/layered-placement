# Layered Placement

**A quality-of-life mod for [Project Zomboid](https://projectzomboid.com/) (Build 42)** that makes furniture placement feel closer to the admin brush — without giving up normal Pickup / Place Furniture gameplay.

Available on the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3775423228).

---

## What it does

In vanilla Project Zomboid, decorating with Move Furniture is limited: lights, posters, and other wall or ceiling items often cannot sit where you want them. Layered Placement loosens those placement rules so you can decorate more freely while still using the standard furniture tools.

- Hang lights over tables, counters, and other furniture  
- Place lamps and decor on railings and catwalks  
- Run outdoor and railing lights on battery, so they still switch on where a room has no power  
- Reliably turn high and railing lights on or off by clicking the light or using its context menu
- Keep normal floor stacking (crates, tables, and so on) and the usual skill / tool requirements  

Server owners choose which features are allowed for everyone in Sandbox Options. Players can still turn allowed features off for themselves in Mod Options, but cannot enable a feature the server has disabled.

Compatible with **Build 42.20+**, safe to add mid-save, and designed for **multiplayer** (enable on the server and all clients).

---

## Multiplayer setup

The mod must be enabled **on the server as well as on every client**, in singleplayer, co-op, and on a dedicated server alike. Hosting co-op counts: the host's game and the co-op server are separate processes, so the server has to load the mod too (Host → Manage settings → Mods, plus the mod list in the co-op save's settings).

The reason is that furniture Place and Pickup only ever finish on the client, and a client cannot create a world object that survives a rejoin. When you stack decor on an occupied tile, the client asks the server to do it; if the server does not have the mod, nothing happens and you keep the item.

If placement behaves differently in multiplayer than in singleplayer, the logs say which side stopped:

- Client: `%UserProfile%\Zomboid\console.txt` (and `Zomboid\Logs\`)
- Dedicated server: `Zomboid\server-console.txt` on the machine running the server
- Every mod line is prefixed with `[LayeredPlacement]`, starting with a load line naming the version and whether that process writes to the world locally or through the server

Useful lines to look for: `client requested placeLayered …` (client asked), `server placeLayered ok …` (server did it), `server placeLayered refused … (reason)`, and `no server reply for … — is Layered Placement enabled and up to date on the server?`.

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
