# PSRegEdit - Modern PowerShell Dark-Mode Registry Editor

**PSRegEdit** is an advanced, standalone Windows PowerShell GUI application that enhances and modernizes the native Windows Registry Editor (`regedit.exe`). Built with Windows Presentation Foundation (WPF) and custom dark-theme styling, PSRegEdit offers lightning-fast performance, multi-threaded search, interactive path navigation, value filtering, bookmarking, and ACL permissions viewing.

![PSRegEdit Dark Theme](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-blue?logo=powershell)
![Platform](https://img.shields.io/badge/Platform-Windows-007ACC?logo=windows)
![Theme](https://img.shields.io/badge/Theme-Native%20Dark-181818)

---

## ✨ Features & Enhancements over `regedit.exe`

- 🌙 **Native Dark Mode UI**: Full dark theme styling across all menus, toolbars, tree views, data grids, status bars, and popup dialogs.
- ⚡ **Lazy-Loaded High-Performance Tree**: Supports all hives (`HKLM`, `HKCU`, `HKCR`, `HKU`, `HKCC`) with asynchronous node expansion to maintain smooth responsiveness on massive registry keys.
- 📍 **Interactive Path / Breadcrumb Bar**: Type or paste any registry path (e.g. `Computer\HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft`) for instant jump navigation.
- 🔍 **Advanced Multi-Threaded Search Panel**:
  - Global or key-scoped recursive search.
  - Search across key names, value names, and value data.
  - Regular Expression (Regex) matching support.
  - Clickable results table with direct jump navigation to matching keys.
- 🧹 **Live Value Filter Bar**: Instant client-side filtering of value names and data in the current key.
- 📝 **Full Registry CRUD Capabilities**:
  - Create, rename, and delete keys.
  - Create and edit value types: `REG_SZ`, `REG_EXPAND_SZ`, `REG_MULTI_SZ`, `REG_DWORD`, `REG_QWORD`, `REG_BINARY`.
  - Multi-line text editor for string and multi-string arrays.
- ⭐ **Favorites & Bookmarks System**: Save custom registry locations with friendly names for quick access anytime.
- 📤 **Native Export & Import**: Export selected keys to standard `.reg` files or import `.reg` files seamlessly.
- 🔒 **ACL Security & Permissions Viewer**: Inspect key ownership and Access Control Lists directly from the GUI.
- 🛡️ **Administrator Mode Detection**: Visual indicator showing Administrator vs Non-Admin privileges.

---

## 🚀 Quick Start & Installation

### Requirements
- **Operating System**: Windows 10, 11, or Windows Server 2016+
- **PowerShell**: Windows PowerShell 5.1 or PowerShell Core 7+ with WPF support.

### Launching the Application

1. Clone or download `PSRegEdit.ps1` into your local directory.
2. Open a PowerShell terminal (Run as Administrator recommended for system key modifications):
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\PSRegEdit.ps1
   ```
3. Alternatively, right-click `PSRegEdit.ps1` and select **Run with PowerShell**.

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Ctrl + F` | Toggle Advanced Search Panel |
| `F5` | Refresh current registry key/tree |
| `F2` | Rename selected item |
| `Del` | Delete selected key or value |
| `Ctrl + I` | Import `.reg` file |
| `Ctrl + E` | Export current registry key |
| `Ctrl + Shift + C` | Copy current path to clipboard |
| `Alt + F4` | Exit PSRegEdit |

---

## 🛠️ Architecture Overview

PSRegEdit is engineered as a single, zero-dependency PowerShell script using:
- **WPF (XAML)**: Loaded via `[System.Windows.Markup.XamlReader]` for full control over styling and visual trees.
- **.NET Registry Engine**: Utilizes `[Microsoft.Win32.RegistryKey]` for direct high-speed registry access.
- **`System.ComponentModel.BackgroundWorker`**: Performs non-blocking multi-threaded search sweeps across registry hierarchies.
- **JSON Persistence**: Stores user favorites in `$env:APPDATA\PSRegEdit\favorites.json`.

---

## 📄 License
Released under the MIT License. Feel free to customize and distribute.
