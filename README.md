# beammp-mod-UI
Initial release of the mod
## Important clarification!
Indeed, the mod I'm posting works perfectly fine, but I'm not a professional programmer - I relied heavily on artificial intelligence [after training it to code according to the nuances of BeamMP]. So don't look at this as an example of "perfect programming", I'm almost certain there are cleaner and more efficient methods to code this.

Still, I’m sharing this because there’s a lack of good examples for server ↔ JavaScript communication in BeamMP.  
I hope this mod can serve as a useful reference, and maybe you’ll find the UI neat enough to reuse.

---

## ⚙️ Installation
1. Place the **`EconomyTest`** folder in:

Resources/Server/

2. Place **`EconomyUI.zip`** in:

Resources/Client/

3. Restart your BeamMP server.

---

# Overview

## 📢 Two-Way UI & Multilingual Mod

### 🌐 Bi-directional Communication
Server sends economy data to JS.  
When the player changes the language in the UI, the client sends it back to the server.

### 🌍 Language Support (i18n)
Real-time language switching.  
Currently supports **English, Hebrew, Arabic**.  
Easy to add new languages by editing the localization files.

### 🚓 Automatic Role Assignment
Assigns players to roles (Police / Civilian) based on vehicle skins. Can be extended to more roles.

### ☁️ Extensibility
Add more roles, custom events, or new languages.  
The structure is clear and designed for easy extension.

---

# Detailed Overview

This document provides a comprehensive overview of the EconomyTest mod, its features, and how to use and configure it. It's designed for players, server administrators, and aspiring developers who want to learn from the code.

## What is this mod?

EconomyTest is a complete, yet easy-to-understand, server-side economy mod for BeamMP. It introduces player accounts, currency, roles, and interactive commands to create a dynamic and engaging gameplay experience. The code is heavily commented to serve as a learning resource for how server-side mods can be built.

## Core Features

*  **Persistent Player Accounts:** Each player has an account tied to their unique ID, with money balances that save automatically and persist across sessions.
*  **Passive Income:** Players earn a configurable amount of money ($10 per minute by default) just for being active on the server.
*  **Player-to-Player Transactions:** Securely pay other players using the `/pay` command.
*  **Dynamic Role System:** Players are automatically assigned the "Police" or "Civilian" role based on their vehicle's skin.  Cops receive a "Welcome, officer!" message     , while civilians get a "Drive safe" message.
*  **Speeding Bonus:** Civilians are rewarded for risky driving!  Driving above the speed limit (100 km/h by default) for a full minute earns a bonus payout.
*  **Multi-Language Support:** The UI and server messages support multiple languages (English, Hebrew, and Arabic are included) and can be easily extended.
*  **Interactive UI/HUD:** A clean, modern UI allows players to see their balance and change their language settings with ease.
*  **Data Safe-Guards:** Player data is saved "atomically."  This means it writes to a temporary file first before replacing the main data file, which prevents data loss or corruption if the server crashes during a save operation.

## Configuration

 You can easily customize the mod by editing the constants at the top of the `Resources/Server/EconomyTest/main.lua` file.

* `MONEY_PER_MINUTE_AMOUNT`: Change the amount of passive income players receive.
* `AUTOSAVE_INTERVAL_MS`: Adjust how often (in milliseconds) player data is saved.
* `SPEED_LIMIT_KMH`: Set the speed civilians must exceed to start the speeding bonus.
* `SPEEDING_COOLDOWN_MS`: Set the cooldown time (in milliseconds) before a player can start another speeding bonus.
* `PoliceSkins`: This is a very important list.  Add or remove vehicle skin names here to define which cars grant players the "Police" role.

### Customizing Messages and Languages

* **Edit Text:** All server messages can be changed by editing the JSON files in `/Resources/Server/EconomyTest/lang/`.
* **Add a Language:** To add a new language, create a new `.json` file (e.g., `fr.json`), add it to the `SUPPORTED_LANGS` list in `main.lua`, and add a corresponding UI translation in the client files `EconomyUI.zip\ui\modules\apps\EconomyHUD\translations`.

## UI
*  Click the "💰 Open" button on your screen to view your balance panel.  Click the globe icon (🌐) to open the language menu and change the UI's language instantly.
*  Note: Sometimes immediately upon entering the server the UI will display: 0:00 on the screen but it will update immediately when the player's money amount changes. This is a timing issue that any professional developer can easily solve.

## Mod Architecture

This mod is split into three distinct parts, which is a common and effective pattern:

1. **Server (`main.lua`):** This is the authoritative core. It handles all logic, calculations, data storage (`players.DATA`), and game rules. It is the single source of truth for everything.
2. **Client (`key.lua`):** A lightweight bridge. Its only job is to pass messages between the server and the UI. It listens for events from the server (like `receiveMoney`) and pushes the data to the UI, and it listens for requests from the UI (like `setPlayerLanguage`) and sends them to the server.
3. **UI (`app.js`, `app.html`, `app.css`):** The visual front-end built with AngularJS. It is responsible only for displaying information and capturing user input. It holds no game logic itself and relies entirely on the client script for data.


## Acknowledgments

Special thanks to **Beams Of Norway** who brought me the code to test the speed
