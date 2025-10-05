# 🚓 UIMPIT - Economy & Roleplay Mod

A comprehensive **server-side mod for BeamMP** that introduces a **dynamic economy**, **civilian vs. police roleplay mechanics**, and a **highly configurable gameplay experience**.

This mod includes:

* 🧠 Server-side script
* 💻 Client-side UI (HUD)
* ⚙️ Graphical configuration editor

---

## ✨ Features

### 💰 Dynamic Economy System

* Players earn money over time.
* Ability to pay other players using chat commands (`/pay`).
* Player data (money, language) is automatically saved.

---

### 🚔 Civilian vs. Police Roleplay

* **Automatic Role Detection**:
  The server automatically assigns players to *Civilian* or *Police* roles based on their vehicle’s skin.

* **Wanted System**:
  Civilians become *wanted* by performing actions like speeding or reckless driving (zigzagging).

* **High-Stakes Chases**:

  * Wanted civilians earn bonus money for driving near police officers.
  * Police officers earn money for pursuing wanted players.

* **Busting Mechanic**:
  Police can “bust” wanted civilians by staying close while they are stopped or driving slowly — earning a significant bonus.

* **Evasion Bonus**:
  Civilians who successfully evade police and survive the wanted timer receive a large reward.

---

### 🧭 Modern In-Game UI (HUD)

* Clean, toggleable interface showing the player’s money and wanted status.
* Displays a live “WANTED” timer during pursuits.
* **Full multi-language support**:

  * Change language directly in-game (English, Hebrew, Arabic supported).
  * UI automatically adjusts for RTL languages.

---

### ⚙️ Easy Configuration

* Every gameplay variable (payouts, timers, speeds, distances, etc.) can be easily configured in a single **`config.json`** file.
* Includes a **graphical Configuration Editor** tool to edit settings safely and intuitively.

---

## 🚀 Components

| Component              | Description                                                               |
| ---------------------- | ------------------------------------------------------------------------- |
| **`main.lua`**         | The core server script — manages all game logic, player data, and events. |
| **`EconomyUI.zip`**    | The in-game interface (HUD) that displays real-time information.          |
| **`config_editor.py`** | A standalone desktop configuration editor for Windows and Linux.          |

---

## 🧩 Configuration Editor

A standalone **desktop application** (Windows/Linux) that allows you to modify the mod’s core settings with a GUI — no coding required.

If you don’t know how to code, this tool lets you control all main functions and variables of the mod safely, enabling/disabling or modifying features with a few clicks.

### 🪟 Windows Version

The executable (`UIMPIT-Config-Editor.exe`) is provided within the release file.

### 🐧 Build it Yourself (Windows/Linux)

If you prefer to build the editor manually:

#### 📋 Prerequisites

1. **Python 3** installed and added to your system PATH.
2. Required packages:

```bash
pip install PySide6 PyInstaller
```

#### 📁 Setup

1. Create a file in:

```
Resources/Server/EconomyTest/config_editor.py
```

2. Copy the content from the repository’s `config_editor.py`.

#### ⚙️ Build Commands

##### 🪟 On Windows:

```bash
pyinstaller --onefile --windowed --name "UIMPIT-Config-Editor" --add-data "lang;lang" config_editor.py
```

##### 🐧 On Linux:

```bash
pyinstaller --onefile --noconsole --name "UIMPIT-Config-Editor" --add-data "lang:lang" config_editor.py
```

---

### 📦 Deployment

After building, a `dist` folder will be created. Inside, you’ll find the executable file:
`UIMPIT-Config-Editor.exe` *(Windows)* or `UIMPIT-Config-Editor` *(Linux)*

> ⚠️ **Important:**
> Move the generated executable to the main server directory:
>
> ```
> Resources/Server/EconomyTest/
> ```
>
> The file must be in the same directory as:
>
> * `config.json`
> * `lang/` folder

---

## 🧠 Credits

Special thanks to **Beams Of Norway** who brought me the code to test the speed


---

## 📜 License
© 2025 5DROR5

You are free to use, modify, and distribute this mod for any purpose, including commercial use, 
as long as you give credit to the original author (5DROR5).  

No warranty is provided.
