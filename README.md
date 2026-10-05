# List Manager

This repository contains two browser apps served by one local PowerShell server:

- **List Manager** (`apps/listmanager`) manages schema-driven JSON lists.
- **Bills** (`apps/bills`) tracks household water and electricity readings.

The root `Start-WebServer.ps1` routes requests to either app. App-specific data validation is in each app's `Validate.ps1`; reusable HTML, data-integrity, and app-lifecycle helpers live in `shared/`.

## Start

Run from the repository folder:

```powershell
.\Start-WebServer.ps1 -OpenBrowser
```

By default, the server shows an app chooser and serves:

- `http://localhost:8080/apps/listmanager/`
- `http://localhost:8080/apps/bills/`

To mount one app at the root URL instead:

```powershell
.\Start-WebServer.ps1 -App bills -OpenBrowser
.\Start-WebServer.ps1 -App listmanager -OpenBrowser
```

With `-App`, the selected app opens at `http://localhost:8080/`. Shared files remain available under `/shared/`. The unselected app is not served in this mode.

The convenience launcher accepts the same options and forwards them:

```powershell
.\serve.ps1 -App bills
.\serve.ps1 -App listmanager -DataFile "./Passwords2.gz"
```

Without `-App`, `serve.ps1` opens the multi-app chooser on the first available port in `41000-41010`.
Press `q` in an interactive server terminal to stop it; use Ctrl+C when console input is unavailable. With `-AllowClientExit`, closing the app page also stops the server.
To switch apps while `-AllowClientExit` is enabled, open the root chooser in a new tab; navigating away from the current app in the same tab stops the server.

## Options

```powershell
.\Start-WebServer.ps1 -Port "8080-8090" -DataFile "records.json"
.\Start-WebServer.ps1 -DataFile "records.json.gz" -OpenBrowser
```

- `-Port 8080` tries one port. A port range advances sequentially when a port is occupied.
- `-Root` selects the repository root containing `apps` and `shared`.
- `-DataFile` selects the data file relative to each app folder, so `Passwords2.gz`, `./Passwords2.gz`, `.\Passwords2.gz`, and `lists/contacts.json` all work and resolve to `apps/<app>/<that path>`. A leading app folder name such as `./listmanager/Passwords2.gz` would resolve to `apps/listmanager/listmanager/Passwords2.gz`, so omit it. Paths that would leave the app folder (`../shared/x.json`) and absolute paths are rejected, and a file that does not exist fails at startup with the resolved path instead of returning 404 later. By default, the server uses `data.json.gz` when present, then `data.json`.
- `-EditPassword` protects saves, not reads. The server uses plain HTTP, so the password hash is not encrypted in transit; do not use this as network-grade authentication.
- `-AllAddresses` exposes the server and readable app data to the network, and may require a Windows URL reservation. Only use it on a trusted network.
- `-AllowClientExit` lets closing or navigating away from a page stop the server.

## Sample data

Each app ships sample data next to its real file, so the apps can be explored without touching live records. Pass `-DataFile` to serve one; the name is relative to the app folder.

List Manager includes four lists, each leaning on different field types:

```powershell
.\serve.ps1 -App listmanager -DataFile "contacts.json"   # Vendor Contacts: text, email, checkbox
.\serve.ps1 -App listmanager -DataFile "inventory.json"  # Equipment Inventory: number, date, checkbox
.\serve.ps1 -App listmanager -DataFile "tasks.json"      # Project Tasks: date, number, checkbox
.\serve.ps1 -App listmanager -DataFile "expenses.json"   # Household Expenses: number, date, checkbox
```

Bills ships three invented people, each with a water and an electricity baseline plus later priced readings:

```powershell
.\serve.ps1 -App bills -DataFile "people-sample.json"
```

Sample files are read and written like any other data file, so edits made while serving one persist to that file. To make a sample the default, replace `apps/<app>/data.json` with it.

## Backups

Both apps have a **Backup** control that writes a copy of the current data file to disk. The copy is always gzip, and its name is the served file's own name with a local timestamp, for example `contacts_2026-10-05_18-07-33.json.gz` or `Passwords2_2026-10-05_18-09-03.gz` when the served file was already compressed. The time part uses dashes because Windows rejects colons in file names.

The name follows the file the server actually serves, which matters when `-DataFile` renames it, since the page only requests the `data.json` URL; the server reports the real name in the `X-Data-File-Name` response header. Where the copy is stored is chosen by the browser: with the File System Access API the save dialog opens and any folder can be picked, and otherwise the file goes to the browser's configured download location or save dialog.

## Data integrity

Both apps share the ETag polling and conditional-save client logic in `shared/DataIntegrity.js`. The page checks for changes every five seconds and when its tab becomes visible. When another process changes a data file, the app automatically reloads; this discards unsaved browser edits. The server independently rejects stale writes, and saves use an atomic file replacement. The server rejects save bodies larger than 10 MiB and validates each app's document shape.

Each app validates its own document format before saving: List Manager checks `schema`/`records`, and Bills checks `people`/`persons`. JSON request bodies are decoded as strict UTF-8, and saved files are written as UTF-8 without a byte-order mark, preserving Hebrew and other Unicode text consistently across PowerShell versions and system locales.

Run the dependency-free shared browser-helper tests with Node.js 18 or newer:

```powershell
node --test tests/*.test.js
```

Run the server argument and data-file resolution checks with PowerShell 7 or newer:

```powershell
pwsh -File tests/webserver.test.ps1
```

## List Manager

- Search, sort, resize columns, or copy a field value.
- Add, edit, or remove records. **Quick delete** skips confirmation.
- Use **Edit columns** to add, rename, change the type or required flag of, or remove columns.
- **Backup** saves a timestamped gzip copy of the served data file.
- **RTL** mirrors the list layout. **Blur list** visually obscures record fields but does not encrypt or protect the underlying data.

Edits save to that app's JSON or gzip data file.

## Bills

Reading rows can be edited in place with **ערוך**; each edit can be saved or cancelled independently. Price inputs accept arbitrary decimal precision. The first reading for each utility is a valid baseline and does not require or store a price; its date can be edited as long as it remains earlier than the other readings. Prices are required for later readings, once usage can be compared.
