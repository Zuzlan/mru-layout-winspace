#Requires -Version 5.1
<#
MRU Layout 1.1.3: Win + Space with most-recently-used ordering.
Run with the included Start.cmd. No installation or internet access.
The only persistent change is an optional HKCU Run entry when you enable
"Run at startup" from the tray menu.

Native API documentation:
https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc
https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-inputlangchangerequest
https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-postmessagew

This implementation has not been runtime-tested on Windows by its author.
Ordinary keyboard layouts are supported by design; TSF-only/IME profiles,
elevated windows, remote desktops and protected desktops are not guaranteed.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
$scriptDir = Split-Path -Parent $scriptPath
$powerShellExe = Join-Path $PSHOME 'powershell.exe'
$env:LOCAL_MRU_SCRIPT = $scriptPath
$env:LOCAL_MRU_BASEDIR = $scriptDir
$env:LOCAL_MRU_POWERSHELL = $powerShellExe
$source = @'
// MRU Layout 1.1.3. Windows-only runtime; C# 5 / .NET Framework compatible.
// No network or package downloads. No keystroke logging. No elevation.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace LocalMruLayout
{
    // The ordering logic is independent of Windows and can be unit-tested.
    public sealed class MruOrder
    {
        private readonly List<IntPtr> order = new List<IntPtr>();
        private List<IntPtr> snapshot;
        private IntPtr lastObserved;
        private int index;
        private bool hasHistory;
        public bool Cycling { get { return snapshot != null; } }
        public int Count { get { return order.Count; } }
        public bool HasHistory { get { return hasHistory; } }

        public void Available(IntPtr[] layouts)
        {
            var natural = new List<IntPtr>();
            foreach (IntPtr h in layouts)
                if (h != IntPtr.Zero && !natural.Contains(h)) natural.Add(h);

            // Before the user has created real MRU history, the configured
            // Windows order is the history. This makes the very first press
            // useful instead of waiting until layouts have been observed.
            if (!hasHistory)
            {
                order.Clear();
                order.AddRange(natural);
                if (lastObserved != IntPtr.Zero && !order.Contains(lastObserved))
                    order.Insert(0, lastObserved);
                return;
            }

            order.RemoveAll(delegate(IntPtr h) { return !natural.Contains(h); });
            foreach (IntPtr h in natural)
                if (!order.Contains(h)) order.Add(h);
        }

        public void Observe(IntPtr layout)
        {
            if (Cycling || layout == IntPtr.Zero) return;
            if (lastObserved == IntPtr.Zero)
            {
                // Merely seeing the startup layout is not MRU history yet.
                lastObserved = layout;
                if (!order.Contains(layout)) order.Insert(0, layout);
                return;
            }
            if (layout == lastObserved) return;

            hasHistory = true;
            order.Remove(layout);
            order.Insert(0, layout);
            lastObserved = layout;
        }

        public void Begin(IntPtr current)
        {
            if (current == IntPtr.Zero) return;
            if (lastObserved == IntPtr.Zero) lastObserved = current;
            else if (current != lastObserved) Observe(current);

            if (!order.Contains(current)) order.Insert(0, current);

            if (!hasHistory)
            {
                // Rotate the natural order so the current layout is first.
                // Example: natural A,B,C and current B => B,C,A.
                snapshot = new List<IntPtr>();
                int start = order.IndexOf(current);
                for (int i = 0; i < order.Count; i++)
                    snapshot.Add(order[(start + i) % order.Count]);
            }
            else
            {
                // Once there is real history, current must be the MRU head.
                order.Remove(current);
                order.Insert(0, current);
                snapshot = new List<IntPtr>(order);
            }
            index = 0;
        }

        public IntPtr Next()
        {
            if (!Cycling || snapshot.Count == 0) return IntPtr.Zero;
            index = (index + 1) % snapshot.Count;
            return snapshot[index];
        }

        public void Finish()
        {
            if (!Cycling) return;
            IntPtr selected = snapshot.Count > 0 ? snapshot[index] : IntPtr.Zero;
            snapshot = null;
            Observe(selected);
        }
        public void Cancel() { snapshot = null; }
        public IntPtr[] ReadOrder() { return order.ToArray(); }
    }

    internal static class Native
    {
        internal const int WH_KEYBOARD_LL = 13;
        internal const int KEYDOWN = 0x100, KEYUP = 0x101;
        internal const int SYSKEYDOWN = 0x104, SYSKEYUP = 0x105;
        internal const int SPACE = 0x20, LWIN = 0x5B, RWIN = 0x5C;
        internal const uint INPUTLANG = 0x50;
        internal const uint STEP = 0x8001, FINISH = 0x8002, START = 0x8003;
        internal delegate IntPtr HookProc(int code, IntPtr message, IntPtr data);
        [StructLayout(LayoutKind.Sequential)]
        internal struct KeyboardEvent
        {
            public uint vk, scan, flags, time;
            public UIntPtr extra;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct Rect { public int left, top, right, bottom; }
        [StructLayout(LayoutKind.Sequential)]
        internal struct GuiInfo
        {
            public uint size, flags;
            public IntPtr active, focus, capture, menuOwner, moveSize, caret;
            public Rect caretRect;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct KeyboardInput
        {
            public ushort vk, scan;
            public uint flags, time;
            public UIntPtr extra;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct MouseInput
        {
            public int dx, dy;
            public uint mouseData, flags, time;
            public UIntPtr extra;
        }
        [StructLayout(LayoutKind.Explicit)]
        internal struct InputUnion
        {
            [FieldOffset(0)] public KeyboardInput keyboard;
            [FieldOffset(0)] public MouseInput mouse;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct Input { public uint type; public InputUnion data; }
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern IntPtr SetWindowsHookEx(int type, HookProc callback, IntPtr module, uint thread);
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")]
        internal static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll")]
        internal static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        internal static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetGUIThreadInfo(uint thread, ref GuiInfo info);
        [DllImport("user32.dll")]
        internal static extern IntPtr GetKeyboardLayout(uint thread);
        [DllImport("user32.dll")]
        internal static extern int GetKeyboardLayoutList(int count, [Out] IntPtr[] layouts);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        internal static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern uint SendInput(uint count, Input[] inputs, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern int GetClassName(IntPtr window, System.Text.StringBuilder buffer, int count);
        internal static bool Down(int key) { return (GetAsyncKeyState(key) & 0x8000) != 0; }
        internal static IntPtr[] Layouts()
        {
            int count = GetKeyboardLayoutList(0, null);
            if (count <= 0) return new IntPtr[0];
            IntPtr[] result = new IntPtr[count];
            int copied = GetKeyboardLayoutList(count, result);
            if (copied < count) Array.Resize(ref result, Math.Max(copied, 0));
            return result;
        }

        internal static IntPtr[] NaturalLayouts()
        {
            IntPtr[] system = Layouts();
            var natural = new List<IntPtr>();
            var used = new HashSet<IntPtr>();
            try
            {
                using (RegistryKey preload = Registry.CurrentUser.OpenSubKey(@"Keyboard Layout\Preload", false))
                using (RegistryKey substitutes = Registry.CurrentUser.OpenSubKey(@"Keyboard Layout\Substitutes", false))
                {
                    if (preload != null)
                    {
                        string[] names = preload.GetValueNames();
                        Array.Sort(names, delegate(string a, string b)
                        {
                            int ai, bi;
                            if (!Int32.TryParse(a, out ai)) ai = Int32.MaxValue;
                            if (!Int32.TryParse(b, out bi)) bi = Int32.MaxValue;
                            int byNumber = ai.CompareTo(bi);
                            return byNumber != 0 ? byNumber : String.CompareOrdinal(a, b);
                        });

                        foreach (string valueName in names)
                        {
                            string klid = Convert.ToString(preload.GetValue(valueName));
                            if (String.IsNullOrWhiteSpace(klid)) continue;
                            if (substitutes != null)
                            {
                                string substitute = Convert.ToString(substitutes.GetValue(klid));
                                if (!String.IsNullOrWhiteSpace(substitute)) klid = substitute;
                            }

                            uint raw;
                            if (!UInt32.TryParse(klid, NumberStyles.HexNumber,
                                CultureInfo.InvariantCulture, out raw)) continue;
                            ushort lang = (ushort)(raw & 0xFFFFu);

                            IntPtr match = IntPtr.Zero;
                            // Prefer an already loaded handle with the same language.
                            foreach (IntPtr h in system)
                            {
                                if (used.Contains(h)) continue;
                                if ((ushort)(h.ToInt64() & 0xFFFFL) == lang)
                                {
                                    match = h;
                                    break;
                                }
                            }

                            // Primary KLIDs have a predictable HKL form. This also
                            // gives a cold-start fallback if GetKeyboardLayoutList
                            // has not exposed every configured language yet.
                            if (match == IntPtr.Zero && (raw & 0xFFFF0000u) == 0)
                            {
                                long hkl = ((long)lang << 16) | lang;
                                match = new IntPtr(hkl);
                            }

                            if (match != IntPtr.Zero && !used.Contains(match))
                            {
                                natural.Add(match);
                                used.Add(match);
                            }
                        }
                    }
                }
            }
            catch
            {
                // Registry order is only a preferred cold-start source.
            }

            foreach (IntPtr h in system)
            {
                if (h != IntPtr.Zero && !used.Contains(h))
                {
                    natural.Add(h);
                    used.Add(h);
                }
            }
            return natural.Count > 0 ? natural.ToArray() : system;
        }
        // An unassigned virtual key marks Win as part of a combination,
        // so releasing Win does not normally open Start after Space is swallowed.
        // No Ctrl/Alt/Shift keystrokes are synthesized.
        internal static bool MaskStartMenu()
        {
            Input[] inputs = new Input[2];
            for (int i = 0; i < 2; i++)
            {
                inputs[i].type = 1;
                inputs[i].data.keyboard.vk = 0xE8;
                inputs[i].data.keyboard.flags = i == 0 ? 0u : 2u;
                inputs[i].data.keyboard.extra = new UIntPtr(0x4D525531u);
            }
            return SendInput(2, inputs, Marshal.SizeOf(typeof(Input))) == 2;
        }

        internal static bool ReplaySpaceForWindowsSwitcher()
        {
            // Used only as a safety net if no second layout can be resolved.
            // Win is still physically held; injected Space is ignored by our hook
            // and therefore reaches the native Windows language switcher.
            Input[] inputs = new Input[2];
            for (int i = 0; i < 2; i++)
            {
                inputs[i].type = 1;
                inputs[i].data.keyboard.vk = SPACE;
                inputs[i].data.keyboard.flags = i == 0 ? 0u : 2u;
                inputs[i].data.keyboard.extra = new UIntPtr(0x4D525532u);
            }
            return SendInput(2, inputs, Marshal.SizeOf(typeof(Input))) == 2;
        }
    }

    internal sealed class Target
    {
        internal IntPtr root, focus, layout;
        internal uint thread;
        internal static Target Read(IntPtr root, uint ownProcess)
        {
            if (root == IntPtr.Zero) return null;
            uint process;
            uint thread = Native.GetWindowThreadProcessId(root, out process);
            if (thread == 0 || process == ownProcess) return null;
            var className = new System.Text.StringBuilder(128);
            Native.GetClassName(root, className, className.Capacity);
            string cls = className.ToString();
            // Do not learn the taskbar's layout when the user opens its menus.
            if (cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd" ||
                cls == "#32768" || cls == "ForegroundStaging") return null;
            Native.GuiInfo info = new Native.GuiInfo();
            info.size = (uint)Marshal.SizeOf(typeof(Native.GuiInfo));
            IntPtr focus = root;
            if (Native.GetGUIThreadInfo(thread, ref info) && info.focus != IntPtr.Zero)
            {
                focus = info.focus;
                uint focusThread = Native.GetWindowThreadProcessId(focus, out process);
                if (focusThread != 0) thread = focusThread;
            }
            return new Target { root = root, focus = focus, thread = thread,
                layout = Native.GetKeyboardLayout(thread) };
        }
    }

    internal sealed class MessageSink : NativeWindow, IDisposable
    {
        internal Action<uint, IntPtr> Dispatch;
        internal MessageSink()
        {
            CreateHandle(new CreateParams { Caption = "Local MRU Layout",
                Parent = new IntPtr(-3) }); // HWND_MESSAGE
        }
        protected override void WndProc(ref Message m)
        {
            if ((uint)m.Msg == Native.STEP || (uint)m.Msg == Native.FINISH ||
                (uint)m.Msg == Native.START)
            {
                if (Dispatch != null) Dispatch((uint)m.Msg, m.LParam);
                return;
            }
            base.WndProc(ref m);
        }
        public void Dispose() { Dispatch = null; DestroyHandle(); }
    }

    internal sealed class SwitchContext : ApplicationContext
    {
        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValueName = "MRU Layout WinSpace";
        private readonly MruOrder history = new MruOrder();
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private readonly uint ownProcess = (uint)Process.GetCurrentProcess().Id;
        private readonly MessageSink sink;
        private readonly NotifyIcon tray;
        private readonly ContextMenuStrip menu;
        private readonly System.Windows.Forms.Timer timer;
        private readonly Native.HookProc hookProc; // Keep delegate alive.
        private readonly Icon primaryIcon;
        private readonly Icon secondaryIcon;
        private readonly string scriptPath;
        private readonly string powerShellPath;
        private readonly string startupCommand;
        private ToolStripMenuItem startupItem;
        private IntPtr hook, cycleRoot, pendingRoot, pendingLayout, lastShownLayout;
        private long pendingUntil, nextWarning;
        private bool leftWin, rightWin, consumedSpace, hookSession, paused, cleaned;
        private bool useSecondaryIcon, suppressStartupEvents, runtimeStarted;

        internal SwitchContext()
        {
            scriptPath = Environment.GetEnvironmentVariable("LOCAL_MRU_SCRIPT") ?? string.Empty;
            powerShellPath = Environment.GetEnvironmentVariable("LOCAL_MRU_POWERSHELL") ?? string.Empty;
            startupCommand = BuildStartupCommand();
            primaryIcon = LoadPrimaryIcon();
            secondaryIcon = LoadSecondaryIcon();
            history.Available(Native.NaturalLayouts());
            sink = new MessageSink();
            sink.Dispatch = Dispatch;
            menu = new ContextMenuStrip();
            var title = new ToolStripMenuItem("MRU Layout 1.1.3 · Win + Space");
            title.Enabled = false;
            menu.Items.Add(title);
            var pause = new ToolStripMenuItem("Pause (default Windows switching)");
            pause.CheckOnClick = true;
            pause.CheckedChanged += delegate
            {
                paused = pause.Checked;
                history.Finish();
                pendingLayout = IntPtr.Zero;
                tray.Text = paused ? "MRU Layout: paused" : "MRU Layout: Win + Space";
            };
            menu.Items.Add(pause);
            startupItem = new ToolStripMenuItem("Run at startup");
            if (CanManageStartup())
            {
                startupItem.CheckOnClick = true;
                SetStartupChecked(IsStartupEnabled());
                startupItem.CheckedChanged += delegate
                {
                    if (!suppressStartupEvents) Guard(ApplyStartupToggle);
                };
            }
            else
            {
                startupItem.Enabled = false;
                startupItem.Text = "Run at startup (unavailable)";
            }
            menu.Items.Add(startupItem);
            menu.Items.Add("Exit", null, delegate { ExitThread(); });
            tray = new NotifyIcon { Icon = primaryIcon,
                Text = "MRU Layout: starting...", ContextMenuStrip = menu, Visible = true };
            timer = new System.Windows.Forms.Timer { Interval = 80 };
            timer.Tick += delegate { Guard(Poll); };
            hookProc = KeyboardHook;

            // Do not install WH_KEYBOARD_LL in the constructor. At this point
            // Application.Run(context) has not entered the WinForms message loop yet.
            // A low-level keyboard hook is delivered back to the installing thread
            // through that thread's message queue. On some Windows builds the hook
            // could therefore remain effectively dormant until another tray/UI message
            // happened to wake the loop. Queue our own START message instead: it is
            // handled only after Application.Run is actively pumping messages.
            if (!Native.PostMessage(sink.Handle, Native.START, IntPtr.Zero, IntPtr.Zero))
            {
                int error = Marshal.GetLastWin32Error();
                Cleanup();
                throw new Win32Exception(error, "Failed to queue MRU Layout startup.");
            }
        }

        private void StartRuntime()
        {
            if (runtimeStarted || cleaned) return;

            leftWin = Native.Down(Native.LWIN);
            rightWin = Native.Down(Native.RWIN);
            hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, hookProc,
                Native.GetModuleHandle(null), 0);
            if (hook == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, "Failed to hook Win + Space.");
            }

            runtimeStarted = true;
            timer.Start();
            Poll();
        }

        private static Icon LoadEmbeddedIcon(string base64)
        {
            byte[] bytes = Convert.FromBase64String(base64);
            using (var stream = new System.IO.MemoryStream(bytes))
            using (var icon = new Icon(stream, SystemInformation.SmallIconSize))
            {
                return (Icon)icon.Clone();
            }
        }
        private static Icon LoadPrimaryIcon()
        {
            const string base64 = "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";
            return LoadEmbeddedIcon(base64);
        }
        private static Icon LoadSecondaryIcon()
        {
            const string base64 = "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";
            return LoadEmbeddedIcon(base64);
        }
        private static string Quote(string value)
        {
            return "\"" + value + "\"";
        }
        private string BuildStartupCommand()
        {
            if (string.IsNullOrWhiteSpace(scriptPath) || string.IsNullOrWhiteSpace(powerShellPath))
                return string.Empty;
            return Quote(powerShellPath) +
                " -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " +
                Quote(scriptPath);
        }
        private bool CanManageStartup()
        {
            return !string.IsNullOrWhiteSpace(startupCommand);
        }
        private void SetStartupChecked(bool value)
        {
            suppressStartupEvents = true;
            try { startupItem.Checked = value; }
            finally { suppressStartupEvents = false; }
        }
        private bool IsStartupEnabled()
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false))
            {
                string current = key == null ? null : Convert.ToString(key.GetValue(RunValueName));
                return string.Equals(current ?? string.Empty, startupCommand,
                    StringComparison.OrdinalIgnoreCase);
            }
        }
        private void ApplyStartupToggle()
        {
            bool desired = startupItem.Checked;
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKeyPath))
                {
                    if (key == null) throw new InvalidOperationException("The Run registry key is unavailable.");
                    if (desired) key.SetValue(RunValueName, startupCommand, RegistryValueKind.String);
                    else if (key.GetValue(RunValueName) != null) key.DeleteValue(RunValueName, false);
                }
            }
            catch (Exception ex)
            {
                SetStartupChecked(IsStartupEnabled());
                Warn("Could not update startup: " + ex.Message);
                return;
            }
            bool actual = IsStartupEnabled();
            if (actual != desired)
            {
                SetStartupChecked(actual);
                Warn("Could not update startup.");
            }
        }

        private IntPtr KeyboardHook(int code, IntPtr message, IntPtr data)
        {
            if (code < 0) return Native.CallNextHookEx(hook, code, message, data);
            var e = (Native.KeyboardEvent)Marshal.PtrToStructure(data, typeof(Native.KeyboardEvent));
            // Synthetic input is neither recorded nor treated as a physical shortcut.
            if ((e.flags & 0x10) != 0)
                return Native.CallNextHookEx(hook, code, message, data);
            int msg = message.ToInt32();
            bool down = msg == Native.KEYDOWN || msg == Native.SYSKEYDOWN;
            bool up = msg == Native.KEYUP || msg == Native.SYSKEYUP;
            if (!down && !up) return Native.CallNextHookEx(hook, code, message, data);

            if (e.vk == Native.LWIN || e.vk == Native.RWIN)
            {
                if (e.vk == Native.LWIN) leftWin = down; else rightWin = down;
                if (up && !leftWin && !rightWin && hookSession)
                {
                    hookSession = false;
                    Native.PostMessage(sink.Handle, Native.FINISH, IntPtr.Zero, IntPtr.Zero);
                }
            }
            if (e.vk == Native.SPACE)
            {
                // Swallow both edges and hardware auto-repeat of an intercepted Space.
                if (consumedSpace)
                {
                    if (up) consumedSpace = false;
                    return new IntPtr(1);
                }
                if (down && !paused && (leftWin || rightWin) &&
                    !Native.Down(0x11) && !Native.Down(0x12) && !Native.Down(0x10))
                {
                    // If injection is blocked (e.g. an elevated target), leave
                    // the original shortcut available instead of swallowing it.
                    if (!hookSession && !Native.MaskStartMenu())
                        return Native.CallNextHookEx(hook, code, message, data);
                    if (Native.PostMessage(sink.Handle, Native.STEP, IntPtr.Zero,
                        Native.GetForegroundWindow()))
                    {
                        hookSession = true;
                        consumedSpace = true;
                        return new IntPtr(1);
                    }
                }
            }
            // Win alone, Win+R/E/L, typing and other combinations pass through.
            return Native.CallNextHookEx(hook, code, message, data);
        }

        private void Dispatch(uint message, IntPtr root)
        {
            Guard(delegate
            {
                if (message == Native.START) StartRuntime();
                else if (message == Native.STEP) Step(root);
                else if (message == Native.FINISH) history.Finish();
            });
        }

        private void Step(IntPtr root)
        {
            if (paused) return;
            // Never apply a queued command to a window which is no longer active.
            if (root != Native.GetForegroundWindow()) return;
            Target target = Target.Read(root, ownProcess);
            if (target == null || target.layout == IntPtr.Zero) return;
            if (history.Cycling && cycleRoot != root) history.Finish();
            if (!history.Cycling)
            {
                // A previous posted request can still be in flight during rapid taps.
                // Use its intended state until acknowledged or timed out.
                IntPtr current = target.layout;
                if (pendingRoot == root && pendingLayout != IntPtr.Zero &&
                    clock.ElapsedMilliseconds < pendingUntil) current = pendingLayout;
                history.Available(Native.NaturalLayouts());
                history.Begin(current);
                cycleRoot = root;
            }
            IntPtr selected = history.Next();
            if (selected == IntPtr.Zero || selected == target.layout)
            {
                history.Cancel();
                pendingLayout = IntPtr.Zero;
                if (!Native.ReplaySpaceForWindowsSwitcher())
                    Warn("No alternate keyboard layout could be resolved.");
                return;
            }
            if (!Native.PostMessage(target.focus, Native.INPUTLANG, IntPtr.Zero, selected))
            {
                int error = Marshal.GetLastWin32Error();
                history.Cancel();
                pendingLayout = IntPtr.Zero;
                history.Observe(target.layout);
                Warn("Windows rejected the switch (code " + error +
                    "). Matching rights may be required for an elevated window.");
                return;
            }
            pendingRoot = root;
            pendingLayout = selected;
            pendingUntil = clock.ElapsedMilliseconds + 1500;
            ShowLayout(selected);
        }

        private void Poll()
        {
            // Resynchronize after lock/unlock or a missed modifier release.
            leftWin = Native.Down(Native.LWIN);
            rightWin = Native.Down(Native.RWIN);
            if (hookSession && !leftWin && !rightWin)
            {
                hookSession = false;
                Native.PostMessage(sink.Handle, Native.FINISH, IntPtr.Zero, IntPtr.Zero);
            }
            if (paused || history.Cycling) return;
            Target target = Target.Read(Native.GetForegroundWindow(), ownProcess);
            if (target == null || target.layout == IntPtr.Zero) return;
            if (pendingLayout != IntPtr.Zero)
            {
                if (target.root == pendingRoot && target.layout != pendingLayout)
                {
                    if (clock.ElapsedMilliseconds < pendingUntil) return;
                    Warn("The application did not confirm the layout change. " +
                        "Try Notepad or enable Pause temporarily.");
                }
                pendingLayout = IntPtr.Zero;
            }
            history.Observe(target.layout);
            ShowLayout(target.layout);
        }

        private void ShowLayout(IntPtr layout)
        {
            if (layout == IntPtr.Zero) return;
            if (lastShownLayout == IntPtr.Zero)
            {
                useSecondaryIcon = false;
                tray.Icon = primaryIcon;
                lastShownLayout = layout;
            }
            else if (layout != lastShownLayout)
            {
                useSecondaryIcon = !useSecondaryIcon;
                tray.Icon = useSecondaryIcon ? secondaryIcon : primaryIcon;
                lastShownLayout = layout;
            }
            string name;
            try { name = CultureInfo.GetCultureInfo((int)(layout.ToInt64() & 0xFFFF)).Name; }
            catch (CultureNotFoundException) { name = "0x" + layout.ToInt64().ToString("X"); }
            tray.Text = "MRU Layout: " + name + " · Win + Space";
        }
        private void Warn(string text)
        {
            if (clock.ElapsedMilliseconds < nextWarning) return;
            nextWarning = clock.ElapsedMilliseconds + 10000;
            tray.ShowBalloonTip(5000, "MRU Layout", text, ToolTipIcon.Warning);
        }
        private void Guard(Action action)
        {
            try { action(); }
            catch (Exception ex)
            {
                Cleanup();
                MessageBox.Show(ex.Message, "MRU Layout: error",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                ExitThread();
            }
        }
        private void Cleanup()
        {
            if (cleaned) return;
            cleaned = true;
            if (timer != null) { timer.Stop(); timer.Dispose(); }
            if (hook != IntPtr.Zero) { Native.UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
            if (tray != null) { tray.Visible = false; tray.Dispose(); }
            if (primaryIcon != null) primaryIcon.Dispose();
            if (secondaryIcon != null) secondaryIcon.Dispose();
            if (menu != null) menu.Dispose();
            if (sink != null) sink.Dispose();
        }
        protected override void ExitThreadCore() { Cleanup(); base.ExitThreadCore(); }
        protected override void Dispose(bool disposing)
        {
            if (disposing) Cleanup();
            base.Dispose(disposing);
        }
    }

    public static class Entry
    {
        public static void VerifyHistory()
        {
            IntPtr a = new IntPtr(1), b = new IntPtr(2), c = new IntPtr(3);
            var h = new MruOrder();
            var cold = new MruOrder();
            cold.Available(new IntPtr[] { a, b, c });
            cold.Observe(b);
            cold.Begin(b);
            if (cold.Next() != c) throw new Exception("MRU self-test: natural cold start");
            cold.Cancel();

            h.Available(new IntPtr[] { a, b, c });
            h.Observe(a);
            h.Begin(a);
            if (h.Next() != b) throw new Exception("MRU self-test: first switch");
            h.Finish();
            h.Begin(b);
            if (h.Next() != a) throw new Exception("MRU self-test: return");
            h.Finish();
            h.Begin(a);
            if (h.Next() != b || h.Next() != c)
                throw new Exception("MRU self-test: third layout");
            h.Finish();
            h.Begin(c);
            if (h.Next() != a) throw new Exception("MRU self-test: real previous layout");
            h.Finish();
            h.Observe(b); // A change outside this program must affect recency.
            h.Begin(b);
            if (h.Next() != a) throw new Exception("MRU self-test: external change");
            h.Cancel();
            h.Available(new IntPtr[] { a, c });
            if (h.Count != 2) throw new Exception("MRU self-test: removed layout");
            h.Observe(a);
            h.Begin(a);
            if (h.Next() != c || h.Next() != a)
                throw new Exception("MRU self-test: wraparound");
            h.Cancel();
        }

        public static void Run()
        {
            Exception failure = null;
            var worker = new Thread(delegate()
            {
                try
                {
                    bool created;
                    using (var instance = new Mutex(true, @"Local\LocalMruLayout.WinSpace.1", out created))
                    {
                        if (!created)
                        {
                            MessageBox.Show("MRU Layout is already running. Look for its tray icon near the clock.",
                                "MRU Layout", MessageBoxButtons.OK, MessageBoxIcon.Information);
                            return;
                        }
                        try
                        {
                            Application.EnableVisualStyles();
                            using (var context = new SwitchContext()) Application.Run(context);
                        }
                        finally { instance.ReleaseMutex(); }
                    }
                }
                catch (Exception ex) { failure = ex; }
            });
            worker.SetApartmentState(ApartmentState.STA);
            worker.IsBackground = false;
            worker.Start();
            worker.Join();
            if (failure != null) throw new InvalidOperationException(failure.Message, failure);
        }
    }
}

'@
try {
    Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies @(
        'System.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll'
    )
    [LocalMruLayout.Entry]::VerifyHistory()
    [LocalMruLayout.Entry]::Run()
} catch {
    $details = $_.Exception.ToString()
    [Console]::Error.WriteLine($details)
    [void][System.Windows.Forms.MessageBox]::Show(
        $details, 'MRU Layout: startup error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}
