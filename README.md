# MRU Layout for Windows

Linux-style keyboard layout switching for Windows.
Instead of cycling through layouts in a fixed order:
1 → 2 → 3 → 1 → 2 → 3
MRU Layout switches to the previously used layout first:
1 ⇄ 2
and only reaches the third layout when you continue cycling while holding Win.

## Installation

No installation required.

1. Download the latest ZIP from Releases.
2. Extract it to a permanent folder.
3. Run `Start.cmd`.
4. Optionally enable `Run at startup` from the tray menu.

START
1. All files should be in same folder.
2. Run Start.cmd with a double-click. Standard user rights are enough
   for ordinary applications. Do not run it from inside the ZIP.
3. A tray icon named "MRU Layout" will appear near the clock,
   possibly inside the hidden-icons area.
4. Test it in Notepad first, then in your usual applications.

## Privacy

- No network access
- No telemetry
- No keystroke logging
- No third-party dependencies
- Source code is fully contained in MRU-Layout.ps1

HOW IT WORKS
Press Win + Space and then release both keys:
switch to the previously used layout.

Hold Win, press and release Space twice:
select the third layout in the MRU history. Release Win to finish.
Do not hold Space: hardware auto-repeat is intentionally ignored.

The order is committed when Win is released, not after each
intermediate step. No language pair is hard-coded.
Changes made through the standard Windows language indicator are also learned.

FIRST RUN / EMPTY HISTORY
Before real MRU history exists, the script uses the natural Windows layout order.
The current layout becomes the start of that cycle: for example, with natural
order 1, 2, 3 and layout 2 active, the first Win + Space selects 3.
After the first actual switch, normal MRU behavior takes over.
If the Windows API does not expose the full layout list, the script also reads
its configured order from the user profile. As a final safety net, that single
keypress is replayed to the native Windows language switcher.

QUICK TEST
After launch, choose layout 1 and then layout 2 from the Windows indicator.
After each manual change, return to Notepad for about a second.
Press and release Win + Space: it should switch to 1.
Press and release Win + Space: it should switch to 2.
Hold Win, press Space twice, release Win: it should switch to 3.
Press and release Win + Space: it should switch to 2, not to a fixed language.

TRAY MENU
Right-click the MRU Layout tray icon:
"Pause (default Windows switching)" restores the standard shortcut behavior.
"Run at startup" enables or disables autostart through HKCU\...\Run.
"Exit" stops the process and removes the keyboard hook.
Win alone, Win + R/E/L, and combinations with Ctrl/Alt/Shift
are intentionally left untouched.

AUTOSTART
You no longer need to create a shortcut manually.
The "Run at startup" menu item adds or removes an entry in
HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
When Windows signs in, it starts a hidden PowerShell process
that launches this same MRU-Layout.ps1 file.

WHAT CHANGES AND WHAT DOES NOT
Start.cmd launches the built-in Windows PowerShell with a hidden console.
PowerShell compiles the C# code from MRU-Layout.ps1 through Add-Type,
runs the built-in MRU logic tests, and starts the keyboard handler.
One additional PowerShell process stays running in the background.
The script does not download packages, does not use the network,
and does not log keystrokes or entered text.
There are no persistent system changes except the optional HKCU Run entry
when you enable autostart.
The hook receives keyboard events only to recognize the shortcut;
it stores only the order of layout identifiers in RAM.
The history starts fresh after launch and is not saved across restarts.
Initially unknown layouts are taken in the order reported by Windows.
There is no custom on-screen switcher; the active language is shown by
Windows itself and by the MRU Layout tray tooltip.

POWERSHELL POLICY
Start.cmd passes -ExecutionPolicy Bypass only to the new PowerShell process.
The permanent execution policy is not changed and Set-ExecutionPolicy is not called.
Corporate policy may still block execution.
Do not disable Defender, SmartScreen or corporate protection for this script.
The full source is available in MRU-Layout.ps1.

LIMITATIONS AND HONEST TEST STATUS
Built-in MRU logic checks run after compilation at startup,
but they do not replace real testing of keyboard hooking and compatibility
with your specific Windows applications.

Windows may block interaction with elevated applications.
In that case you may get ordinary switching instead of MRU switching,
or a warning balloon.
Some applications may ignore WM_INPUTLANGCHANGEREQUEST.
In such a program, use the Windows language indicator or temporarily enable Pause.
Support is not guaranteed for the sign-in screen, UAC prompts, remote sessions,
games, or advanced IME/TSF profiles as opposed to ordinary keyboard layouts.

If Windows is configured to keep a separate layout for each window,
changing focus to another window can also change the language.
This script does not disable that Windows option.

IF IT DOES NOT START
In a terminal opened in the script folder, run:
.\Start.cmd debug
The console will stay visible and show the compilation or startup error.

REMOVAL
Choose "Exit", disable “Run at startup" if you enabled it,
and delete the folder with these files.

UPDATE 1.1.2
On a cold start, before any real MRU history exists, the script uses the
natural Windows layout order, rotated so the current layout is first.
Added a user-profile ordering fallback and a native Windows-switcher fallback
when no alternate layout can be resolved. Icons were rebuilt from the source

UPDATE 1.1.3
Fixed startup initialization: the global keyboard hook is now installed only
after the WinForms message loop is actually running. This removes the dependency
on first opening the tray menu or the tray overflow. 
