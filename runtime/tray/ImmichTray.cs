// Compiled by Windows' .NET Framework csc.exe; no NuGet packages or resident PowerShell.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace Immich.Windows {
    public sealed class TrayOptions {
        public string InstallRoot;
        public string DataRoot;
        public string Scope;
        public string PowerShellPath;
        public bool Check;
        public bool ExitExisting;

        public string CurrentRoot { get { return Path.Combine(InstallRoot, "current"); } }
        public string EnvFile { get { return Path.Combine(DataRoot, "immich.env"); } }
        public string IconPath { get { return Path.Combine(CurrentRoot, @"build\www\favicon.ico"); } }

        public static TrayOptions Parse(string[] args) {
            var result = new TrayOptions();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            for (int i = 0; i < args.Length; i++) {
                string name = args[i];
                if (!seen.Add(name)) { throw new ArgumentException("Duplicate argument: " + name); }
                if (name == "--check") { result.Check = true; continue; }
                if (name == "--exit-existing") { result.ExitExisting = true; continue; }
                if (name != "--install-root" && name != "--data-root" && name != "--scope" && name != "--powershell-path") {
                    throw new ArgumentException("Unknown argument: " + name);
                }
                if (++i >= args.Length || String.IsNullOrWhiteSpace(args[i])) {
                    throw new ArgumentException("Missing value: " + name);
                }
                if (name == "--install-root") { result.InstallRoot = FullPath(args[i]); }
                else if (name == "--data-root") { result.DataRoot = FullPath(args[i]); }
                else if (name == "--powershell-path") { result.PowerShellPath = FullPath(args[i]); }
                else { result.Scope = args[i]; }
            }
            if (result.InstallRoot == null) { throw new ArgumentException("--install-root is required."); }
            if (result.Check && result.ExitExisting) { throw new ArgumentException("--check and --exit-existing cannot be combined."); }
            if (!result.ExitExisting) {
                if (result.DataRoot == null || result.PowerShellPath == null) {
                    throw new ArgumentException("--data-root and --powershell-path are required.");
                }
                if (result.Scope != "AllUsers" && result.Scope != "CurrentUser") {
                    throw new ArgumentException("--scope must be AllUsers or CurrentUser.");
                }
            }
            return result;
        }

        private static string FullPath(string path) {
            if (!Path.IsPathRooted(path)) { throw new ArgumentException("An absolute path is required: " + path); }
            return Path.GetFullPath(path);
        }

        public void ValidateFiles() {
            foreach (string path in new string[] {
                PowerShellPath, IconPath,
                Path.Combine(CurrentRoot, @"runtime\Common.psm1"),
                Path.Combine(CurrentRoot, @"runtime\launchers\Start-Immich.ps1"),
                Path.Combine(CurrentRoot, @"runtime\launchers\Stop-Immich.ps1"),
                Path.Combine(CurrentRoot, @"installer\Update-FromRelease.ps1")
            }) {
                if (!File.Exists(path)) { throw new FileNotFoundException("Required Immich file was not found.", path); }
            }
        }
    }

    public sealed class TrayText {
        public string Open, OpenConfigFolder, Start, Stop, Update, Exit, Busy, Failed, Cancelled, Continue, NotElevated;
        public string Started, Stopped, Updated, Language;
        public string Status, Running, NotRunning, Partial, Changing, Unknown;

        public static TrayText ForCulture(string culture) {
            bool japanese = (culture ?? "").Replace('_', '-').Split('-')[0].Equals("ja", StringComparison.OrdinalIgnoreCase);
            if (japanese) {
                return new TrayText {
                    Open = "Immichを開く", Start = "Immichを起動", Stop = "Immichを停止", Update = "Immichを更新",
                    OpenConfigFolder = "設定フォルダーを開く",
                    Exit = "トレイを終了（サーバーは停止しません）", Busy = "処理中…", Failed = "操作に失敗しました。",
                    Cancelled = "操作はキャンセルされました。", Continue = "Enterキーを押して閉じます",
                    NotElevated = "トレイは管理者として実行できません。スタートアップのImmich Trayショートカットを通常の方法で開くか、サインインし直してください。",
                    Started = "Immichを起動しました。", Stopped = "Immichを停止しました。", Updated = "Immichの更新処理が完了しました。",
                    Status = "サーバー・MLの状態: ", Running = "稼働中",
                    NotRunning = "停止中", Partial = "一部稼働／一時停止", Changing = "状態変更中", Unknown = "確認できません",
                    Language = "ja"
                };
            }
            return new TrayText {
                Open = "Open Immich", Start = "Start Immich", Stop = "Stop Immich", Update = "Update Immich",
                OpenConfigFolder = "Open configuration folder",
                Exit = "Exit tray (keep server running)", Busy = "Working…", Failed = "The action failed.",
                Cancelled = "The action was cancelled.", Continue = "Press Enter to close",
                NotElevated = "The tray cannot run as administrator. Open the Immich Tray Startup shortcut normally, or sign out and sign in again.",
                Started = "Immich started.", Stopped = "Immich stopped.", Updated = "Immich update completed.",
                Status = "Server / ML status: ", Running = "Running",
                NotRunning = "Stopped", Partial = "Partially running / paused", Changing = "Changing", Unknown = "Unknown",
                Language = "en"
            };
        }

        public string RuntimeStatus(string state) {
            switch (state) {
                case "Running": return Running;
                case "Stopped": return NotRunning;
                case "Partial": return Partial;
                case "Changing": return Changing;
                default: return Unknown;
            }
        }
    }

    public static class TrayCommands {
        private static string Quote(string value) { return "'" + value.Replace("'", "''") + "'"; }

        public static string BuildCommand(TrayOptions options, string action, TrayText text) {
            string command;
            string common = " -InstallRoot " + Quote(options.InstallRoot) + " -DataRoot " + Quote(options.DataRoot);
            if (action == "open") {
                // Always read the current env through the same helper used by the installer.
                command = "Import-Module " + Quote(Path.Combine(options.CurrentRoot, @"runtime\Common.psm1")) +
                    " -Force; Start-Process -FilePath (Get-ImmichLocalUrl -EnvFile " + Quote(options.EnvFile) +
                    " -InstallRoot " + Quote(options.InstallRoot) + ")";
            } else if (action == "status") {
                command = "Import-Module " + Quote(Path.Combine(options.CurrentRoot, @"runtime\Common.psm1")) +
                    " -Force -DisableNameChecking; Get-ImmichUserProcessSnapshot" + common;
            } else if (action == "start" || action == "stop") {
                string script = action == "start" ? "Start-Immich.ps1" : "Stop-Immich.ps1";
                command = "& " + Quote(Path.Combine(options.CurrentRoot, @"runtime\launchers", script)) +
                    common + " -EnvFile " + Quote(options.EnvFile);
            } else if (action == "update") {
                command = "& " + Quote(Path.Combine(options.CurrentRoot, @"installer\Update-FromRelease.ps1")) +
                    common + " -Scope " + Quote(options.Scope) + " -Interactive -Language " + Quote(text.Language);
            } else { throw new ArgumentException("Unknown tray action: " + action); }

            // Management actions have a real console for progress and a persistent error on failure,
            // including when an update replaces/exits this tray. No -NoExit after a successful action.
            string failure = action == "open" || action == "status"
                ? "[Console]::Error.WriteLine($_.Exception.Message); exit 1"
                : "Write-Host ($_ | Out-String) -ForegroundColor Red; [void](Read-Host " + Quote(text.Continue) + "); exit 1";
            // Update results are acknowledged by the updater itself, even if it replaces this tray.
            string result = action == "update" ? "; if ($LASTEXITCODE -in @(10,20)) { exit $LASTEXITCODE }" : "";
            return "$ErrorActionPreference='Stop'; $global:LASTEXITCODE=0; try { " + command + result +
                "; if ($LASTEXITCODE -ne 0) { throw ('Exit code: ' + $LASTEXITCODE) }; exit 0 } catch { " + failure + " }";
        }

        public static ProcessStartInfo BuildStartInfo(TrayOptions options, string action, TrayText text) {
            if (action == "open-config-folder") {
                // Use this installation's active env path, without reading its secrets or launching PowerShell.
                return new ProcessStartInfo(Path.GetDirectoryName(options.EnvFile)) { UseShellExecute = true, Verb = "open" };
            }
            string command = BuildCommand(options, action, text);
            var info = new ProcessStartInfo(options.PowerShellPath,
                "-NoLogo -NoProfile -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(command)));
            info.WorkingDirectory = options.InstallRoot;
            if (action == "open" || action == "status") {
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
            } else {
                info.UseShellExecute = true;
                info.WindowStyle = ProcessWindowStyle.Normal;
                if (options.Scope == "AllUsers") { info.Verb = "runas"; }
            }
            return info;
        }
    }

    public static class ImmichTray {
        // The Local namespace and SID/session in the key prevent one user's exit from targeting another.
        public static string InstanceName(string installRoot, string sid, int sessionId) {
            string normalized = Path.GetFullPath(installRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).ToUpperInvariant();
            string identity = normalized + "\n" + sid + "\n" + sessionId.ToString(CultureInfo.InvariantCulture);
            using (SHA256 hash = SHA256.Create()) {
                return @"Local\ImmichTray-" + BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(identity))).Replace("-", "");
            }
        }

        [STAThread]
        public static int Main(string[] args) {
            bool headless = Array.IndexOf(args, "--check") >= 0 || Array.IndexOf(args, "--exit-existing") >= 0;
            TrayText text = TrayText.ForCulture(CultureInfo.CurrentUICulture.Name);
            try {
                TrayOptions options = TrayOptions.Parse(args);
                string instance;
                bool elevated;
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) {
                    instance = InstanceName(options.InstallRoot, identity.User.Value, Process.GetCurrentProcess().SessionId);
                    elevated = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
                }
                if (options.ExitExisting) { return ExitExisting(instance); }
                options.ValidateFiles();
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                if (options.Check) {
                    // Exercise the actual menu/icon and all commands without publishing a tray icon,
                    // taking the resident mutex, launching a process, or entering a message loop.
                    using (var context = new TrayContext(options, text, null, false)) {
                        foreach (string action in new string[] { "open", "open-config-folder", "start", "stop", "update", "status" }) {
                            TrayCommands.BuildStartInfo(options, action, text);
                        }
                    }
                    return 0;
                }
                if (elevated) { throw new InvalidOperationException(text.NotElevated); }
                using (var mutex = new Mutex(false, instance + "-instance")) {
                    bool owns;
                    try { owns = mutex.WaitOne(0); } catch (AbandonedMutexException) { owns = true; }
                    if (!owns) { return 0; }
                    try {
                        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                        Application.ThreadException += delegate(object sender, ThreadExceptionEventArgs e) {
                            MessageBox.Show(e.Exception.Message, "Immich", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        };
                        using (var context = new TrayContext(options, text, instance, true)) {
                            Application.Run(context);
                        }
                    } finally { mutex.ReleaseMutex(); }
                }
                return 0;
            } catch (Exception error) {
                string message = error.Message;
                var missing = error as FileNotFoundException;
                if (missing != null && !String.IsNullOrEmpty(missing.FileName)) { message += "\n" + missing.FileName; }
                if (headless) { Console.Error.WriteLine(message); }
                else { MessageBox.Show(message, "Immich", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                return 1;
            }
        }

        public static string QuoteArgument(string value) {
            // CommandLineToArgvW quoting, including trailing slashes in directory paths.
            var result = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char c in value) {
                if (c == '\\') { backslashes++; continue; }
                if (c == '\"') { result.Append('\\', backslashes * 2 + 1); }
                else { result.Append('\\', backslashes); }
                result.Append(c);
                backslashes = 0;
            }
            result.Append('\\', backslashes * 2);
            result.Append('\"');
            return result.ToString();
        }

        private static int ExitExisting(string instance) {
            Mutex mutex;
            try { mutex = Mutex.OpenExisting(instance + "-instance"); }
            catch (WaitHandleCannotBeOpenedException) { return 0; }
            using (mutex) {
                bool signalled = false;
                var deadline = Stopwatch.StartNew();
                do {
                    bool owns;
                    try { owns = mutex.WaitOne(0); } catch (AbandonedMutexException) { owns = true; }
                    if (owns) { mutex.ReleaseMutex(); return 0; }
                    if (!signalled) {
                        try {
                            using (EventWaitHandle signal = EventWaitHandle.OpenExisting(instance + "-exit")) { signal.Set(); }
                            signalled = true;
                        } catch (WaitHandleCannotBeOpenedException) {
                            // The owner may still be creating its context, or may already be exiting.
                        }
                    }
                    try { owns = mutex.WaitOne(100); } catch (AbandonedMutexException) { owns = true; }
                    if (owns) { mutex.ReleaseMutex(); return 0; }
                } while (deadline.ElapsedMilliseconds < 10000);
            }
            throw new TimeoutException("Immich tray did not exit within 10 seconds.");
        }
    }

    public static class RuntimeStatus {
        public static string Combine(string first, string second) {
            if (first == "Unknown" || second == "Unknown") { return "Unknown"; }
            if (first == "Changing" || second == "Changing") { return "Changing"; }
            if (first == "Running" && second == "Running") { return "Running"; }
            if (first == "Stopped" && second == "Stopped") { return "Stopped"; }
            return "Partial";
        }

        public static string ServiceState(uint state) {
            if (state == 1) { return "Stopped"; }
            if (state == 4) { return "Running"; }
            if (state == 2 || state == 3 || state == 5 || state == 6) { return "Changing"; }
            return state == 7 ? "Partial" : "Unknown";
        }
    }

    public sealed class ProcessSnapshot {
        public int Id;
        public long Started;
        public string State = "Unknown";

        public static ProcessSnapshot[] Parse(string output) {
            var result = new ProcessSnapshot[] { new ProcessSnapshot(), new ProcessSnapshot() };
            string[] lines = (output ?? "").Trim().Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            if (lines.Length != 2) { return result; }
            for (int i = 0; i < 2; i++) {
                if (lines[i] == "Stopped") { result[i].State = "Stopped"; continue; }
                string[] values = lines[i].Split(':');
                int id; long started;
                if (values.Length == 2 && Int32.TryParse(values[0], NumberStyles.None, CultureInfo.InvariantCulture, out id) && id > 0 &&
                    Int64.TryParse(values[1], NumberStyles.None, CultureInfo.InvariantCulture, out started) && started > 0) {
                    result[i].Id = id; result[i].Started = started; result[i].State = "Running";
                }
            }
            return result;
        }
    }

    internal sealed class RuntimeMonitor : IDisposable {
        private static readonly string[] Names = { "ImmichServer", "ImmichMachineLearning" };
        private readonly TrayOptions options;
        private readonly TrayText text;
        private readonly Action<string> changed;
        private readonly object sync = new object();
        private readonly string[] states = { "Unknown", "Unknown" };
        private readonly Process[] processes = new Process[2];
        private readonly IntPtr[] services = new IntPtr[2];
        private readonly IntPtr[] subscriptions = new IntPtr[2];
        private readonly ServiceCallback serviceCallback;
        private FileSystemWatcher watcher;
        private Process query;
        private bool disposed, refreshing, dirty, resetWatcher, userMonitoring;
        private int revision;
        private string published = "Unknown";

        public RuntimeMonitor(TrayOptions options, TrayText text, Action<string> changed) {
            this.options = options; this.text = text; this.changed = changed;
            // SCM callbacks must return immediately: no file I/O, RPC, or unsubscription here.
            serviceCallback = delegate { ThreadPool.QueueUserWorkItem(delegate { RequestRefresh(); }); };
        }

        public void Start() { RequestRefresh(); }

        public void AfterAction() {
            // Healthy subscriptions already observe starts/stops. Retry only a failed attachment.
            lock (sync) {
                if (disposed || (options.Scope == "CurrentUser" ? watcher != null : subscriptions[0] != IntPtr.Zero && subscriptions[1] != IntPtr.Zero)) { return; }
            }
            RequestRefresh();
        }

        private void RequestRefresh() {
            lock (sync) {
                if (disposed) { return; }
                dirty = true; revision++;
                if (refreshing) { return; }
                refreshing = true;
            }
            ThreadPool.QueueUserWorkItem(delegate { Refresh(); });
        }

        private void Refresh() {
            int current;
            lock (sync) { if (disposed) { refreshing = false; return; } dirty = false; current = revision; }
            try {
                if (options.Scope == "AllUsers") {
                    lock (sync) {
                        if (disposed) { return; }
                        AttachServices(); // Subscribe before reading, so a concurrent change is not lost.
                        for (int i = 0; i < 2; i++) {
                            ServiceStatus status;
                            states[i] = subscriptions[i] != IntPtr.Zero && QueryServiceStatus(services[i], out status)
                                ? RuntimeStatus.ServiceState(status.CurrentState) : "Unknown";
                        }
                    }
                } else {
                    AttachFileWatcher(); // Arm directory notification before the initial PID snapshot.
                    ProcessSnapshot[] snapshot = ProcessSnapshot.Parse(ReadSnapshot());
                    lock (sync) {
                        if (disposed || current != revision) { return; }
                        for (int i = 0; i < 2; i++) { AttachProcess(i, snapshot[i]); }
                        userMonitoring = true;
                    }
                }
            } catch { lock (sync) { userMonitoring = false; states[0] = states[1] = "Unknown"; } }
            finally {
                Publish();
                bool again;
                lock (sync) { refreshing = false; again = dirty && !disposed; if (again) { refreshing = true; } }
                // Drain only notifications received during this read. There is no timer/retry loop.
                if (again) { ThreadPool.QueueUserWorkItem(delegate { Refresh(); }); }
            }
        }

        private void AttachFileWatcher() {
            lock (sync) {
                if (disposed) { throw new ObjectDisposedException("RuntimeMonitor"); }
                if (resetWatcher && watcher != null) { watcher.Dispose(); watcher = null; }
                resetWatcher = false;
                if (watcher != null) { return; }
                var next = new FileSystemWatcher(Path.Combine(options.DataRoot, "services"), "*.pid");
                next.IncludeSubdirectories = false;
                next.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size;
                next.Created += PidChanged; next.Changed += PidChanged; next.Deleted += PidChanged;
                next.Renamed += delegate(object sender, RenamedEventArgs e) {
                    if (IsManagedPid(e.Name) || IsManagedPid(e.OldName)) { RequestRefresh(); }
                };
                next.Error += delegate {
                    lock (sync) { resetWatcher = true; userMonitoring = false; states[0] = states[1] = "Unknown"; }
                    Publish(); RequestRefresh();
                };
                try { next.EnableRaisingEvents = true; watcher = next; }
                catch { next.Dispose(); throw; }
            }
        }

        private static bool IsManagedPid(string name) {
            return String.Equals(name, Names[0] + ".pid", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(name, Names[1] + ".pid", StringComparison.OrdinalIgnoreCase);
        }

        private void PidChanged(object sender, FileSystemEventArgs e) {
            if (IsManagedPid(e.Name)) { RequestRefresh(); }
        }

        private string ReadSnapshot() {
            using (var process = new Process()) {
                var output = new StringBuilder();
                process.StartInfo = TrayCommands.BuildStartInfo(options, "status", text);
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                    if (e.Data != null) { lock (output) { if (output.Length < 256) { output.AppendLine(e.Data); } } }
                };
                process.ErrorDataReceived += delegate { };
                try {
                    lock (sync) {
                        if (disposed) { return null; }
                        if (!process.Start()) { return null; }
                        query = process;
                    }
                    process.BeginOutputReadLine(); process.BeginErrorReadLine();
                    if (!process.WaitForExit(10000)) { StopQuery(process); return null; }
                    process.WaitForExit(); // Drain async pipe callbacks after the bounded process wait.
                    if (process.ExitCode != 0) { return null; }
                    lock (output) { return output.ToString(); }
                } finally { lock (sync) { query = null; } }
            }
        }

        private void AttachProcess(int index, ProcessSnapshot snapshot) {
            Process previous = processes[index];
            if (previous != null && !previous.HasExited &&
                (snapshot.State == "Stopped" || (snapshot.State == "Running" && previous.Id == snapshot.Id && previous.StartTime.ToUniversalTime().Ticks == snapshot.Started))) {
                // A deleted PID file cannot turn a still-observed owned process into Stopped.
                states[index] = "Running"; return;
            }
            processes[index] = null;
            if (previous != null) { previous.Dispose(); }
            states[index] = snapshot.State;
            if (snapshot.State != "Running") { return; }
            Process next = null;
            try {
                next = Process.GetProcessById(snapshot.Id);
                IntPtr handle = next.Handle; // Retain this exact process instance across PID reuse.
                Process observed = next;
                next.Exited += delegate {
                    // Process invokes Exited under its own lock; never acquire sync there.
                    ThreadPool.QueueUserWorkItem(delegate {
                        lock (sync) {
                            if (disposed || processes[index] != observed) { return; }
                            states[index] = "Stopped";
                        }
                        Publish(); // TaskKill/crash/normal exit: no PowerShell or PID reread.
                    });
                };
                processes[index] = next;
                next.EnableRaisingEvents = true;
                // Pin the process handle, then revalidate snapshot identity across the handoff.
                if (next.StartTime.ToUniversalTime().Ticks != snapshot.Started) { throw new InvalidOperationException(); }
                states[index] = next.HasExited ? "Stopped" : "Running";
            } catch (ArgumentException) { states[index] = "Stopped"; }
            catch { states[index] = "Unknown"; }
            if (states[index] != "Running") {
                processes[index] = null;
                if (next != null) { next.Dispose(); }
            }
        }

        private void AttachServices() {
            IntPtr manager = OpenSCManager(null, null, 1); // SC_MANAGER_CONNECT only.
            if (manager == IntPtr.Zero) { throw new Win32Exception(); }
            try {
                for (int i = 0; i < 2; i++) {
                    if (subscriptions[i] != IntPtr.Zero) { continue; }
                    IntPtr service = OpenService(manager, Names[i], 4); // SERVICE_QUERY_STATUS only.
                    if (service == IntPtr.Zero) { continue; }
                    IntPtr subscription;
                    uint result;
                    try { result = SubscribeServiceChangeNotifications(service, 2, serviceCallback, IntPtr.Zero, out subscription); }
                    catch { CloseServiceHandle(service); throw; }
                    if (result != 0) { CloseServiceHandle(service); continue; }
                    services[i] = service; subscriptions[i] = subscription;
                }
            } finally { CloseServiceHandle(manager); }
        }

        private void Publish() {
            lock (sync) {
                if (disposed) { return; }
                string state = options.Scope == "CurrentUser" && !userMonitoring ? "Unknown" : RuntimeStatus.Combine(states[0], states[1]);
                if (state == published) { return; }
                published = state;
                changed(state); // Caller only posts to the UI queue; never blocks this lock.
            }
        }

        private static void StopQuery(Process process) {
            try { if (!process.HasExited) { process.Kill(); } }
            catch (InvalidOperationException) { }
            catch (Win32Exception) { }
        }

        public void Dispose() {
            FileSystemWatcher oldWatcher;
            lock (sync) {
                if (disposed) { return; }
                disposed = true;
                if (query != null) { StopQuery(query); }
                oldWatcher = watcher; watcher = null;
                foreach (Process process in processes) { if (process != null) { process.Dispose(); } }
            }
            if (oldWatcher != null) { oldWatcher.Dispose(); }
            // Do not hold sync or execute this from an SCM callback: unsubscribe waits for callbacks.
            for (int i = 0; i < 2; i++) {
                if (subscriptions[i] != IntPtr.Zero) { UnsubscribeServiceChangeNotifications(subscriptions[i]); }
                if (services[i] != IntPtr.Zero) { CloseServiceHandle(services[i]); }
            }
            GC.KeepAlive(serviceCallback);
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate void ServiceCallback(uint notification, IntPtr context);
        [StructLayout(LayoutKind.Sequential)]
        private struct ServiceStatus {
            public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint;
        }
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenSCManager(string machine, string database, uint access);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenService(IntPtr manager, string name, uint access);
        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryServiceStatus(IntPtr service, out ServiceStatus status);
        [DllImport("advapi32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseServiceHandle(IntPtr handle);
        [DllImport("sechost.dll")]
        private static extern uint SubscribeServiceChangeNotifications(IntPtr service, uint eventType, ServiceCallback callback, IntPtr context, out IntPtr subscription);
        [DllImport("sechost.dll")]
        private static extern void UnsubscribeServiceChangeNotifications(IntPtr subscription);
    }

    internal sealed class TrayContext : ApplicationContext {
        private readonly TrayOptions options;
        private readonly TrayText text;
        private readonly Control dispatcher;
        private readonly MemoryStream iconBytes;
        private readonly Icon icon;
        private readonly NotifyIcon tray;
        private readonly ContextMenuStrip menu;
        private readonly ToolStripMenuItem statusItem;
        private readonly RuntimeMonitor runtimeMonitor;
        private readonly List<ToolStripMenuItem> actions = new List<ToolStripMenuItem>();
        private readonly EventWaitHandle exitSignal;
        private readonly RegisteredWaitHandle exitWait;
        private bool busy;
        private bool disposed;

        public TrayContext(TrayOptions options, TrayText text, string instance, bool visible) {
            this.options = options;
            this.text = text;
            // Retain in-memory icon data for its lifetime, while allowing release files to be moved.
            iconBytes = new MemoryStream(File.ReadAllBytes(options.IconPath), false);
            icon = new Icon(iconBytes);
            menu = new ContextMenuStrip();
            statusItem = new ToolStripMenuItem(text.Status + text.Unknown) { Enabled = false };
            menu.Items.Add(statusItem);
            menu.Items.Add(new ToolStripSeparator());
            AddAction(text.Open, "open");
            AddAction(text.OpenConfigFolder, "open-config-folder");
            AddAction(text.Start, "start");
            AddAction(text.Stop, "stop");
            AddAction(text.Update, "update");
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(text.Exit, null, delegate { ExitThread(); });
            tray = new NotifyIcon { Icon = icon, Text = "Immich: " + text.Unknown, ContextMenuStrip = menu };
            tray.DoubleClick += delegate { RunAction("open"); };
            if (visible) {
                dispatcher = new Control();
                IntPtr unused = dispatcher.Handle; // Created on the UI thread before worker callbacks.
                exitSignal = new EventWaitHandle(false, EventResetMode.AutoReset, instance + "-exit");
                exitWait = ThreadPool.RegisterWaitForSingleObject(exitSignal, delegate { Post(delegate { ExitThread(); }); },
                    null, Timeout.Infinite, false);
                runtimeMonitor = new RuntimeMonitor(options, text, delegate(string state) {
                    Post(delegate {
                        statusItem.Text = text.Status + text.RuntimeStatus(state);
                        tray.Text = "Immich: " + text.RuntimeStatus(state);
                    });
                });
                runtimeMonitor.Start();
                tray.Visible = true;
            }
        }

        private void AddAction(string label, string action) {
            var item = new ToolStripMenuItem(label);
            item.Click += delegate { RunAction(action); };
            actions.Add(item);
            menu.Items.Add(item);
        }

        private void RunAction(string action) {
            if (busy || disposed) { return; }
            if (action == "open-config-folder") {
                try {
                    // Explorer may reuse a window and return no process. Never wait for it to close.
                    using (Process.Start(TrayCommands.BuildStartInfo(options, action, text))) { }
                } catch (Exception error) {
                    MessageBox.Show(error.Message, "Immich", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                return;
            }
            busy = true;
            foreach (ToolStripMenuItem item in actions) { item.Enabled = false; }
            ThreadPool.QueueUserWorkItem(delegate {
                string failure = null;
                bool cancelled = false;
                try {
                    var errors = new StringBuilder();
                    using (var process = new Process()) {
                        process.StartInfo = TrayCommands.BuildStartInfo(options, action, text);
                        if (action == "open") {
                            // Drain both pipes asynchronously to avoid deadlocks. Never retain env values.
                            process.OutputDataReceived += delegate { };
                            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                                if (e.Data != null) {
                                    lock (errors) { if (errors.Length < 8192) { errors.AppendLine(e.Data); } }
                                }
                            };
                        }
                        if (!process.Start()) { throw new InvalidOperationException(text.Failed); }
                        if (action == "open") { process.BeginOutputReadLine(); process.BeginErrorReadLine(); }
                        process.WaitForExit();
                        // 10 = already current; 20 = failure acknowledged in the update shell.
                        // The unified updater owns tray replacement after qualification.
                        bool acknowledged = action == "update" && (process.ExitCode == 10 || process.ExitCode == 20);
                        if (process.ExitCode != 0 && !acknowledged) {
                            lock (errors) { failure = errors.Length > 0 ? errors.ToString() : text.Failed + " (" + process.ExitCode.ToString(CultureInfo.InvariantCulture) + ")"; }
                        }
                    }
                } catch (Win32Exception error) {
                    cancelled = error.NativeErrorCode == 1223; // The user cancelled the UAC prompt.
                    failure = cancelled ? text.Cancelled : error.Message;
                } catch (Exception error) { failure = error.Message; }
                Post(delegate {
                    busy = false;
                    foreach (ToolStripMenuItem item in actions) { item.Enabled = true; }
                    if (runtimeMonitor != null) { runtimeMonitor.AfterAction(); }
                    if (failure != null) {
                        MessageBox.Show(failure, "Immich", MessageBoxButtons.OK, cancelled ? MessageBoxIcon.Information : MessageBoxIcon.Error);
                    } else if (action == "start" || action == "stop") {
                        string completed = action == "start" ? text.Started : action == "stop" ? text.Stopped : text.Updated;
                        tray.ShowBalloonTip(4000, "Immich", completed, ToolTipIcon.Info);
                    }
                });
            });
        }

        private void Post(MethodInvoker callback) {
            try {
                if (dispatcher != null && !dispatcher.IsDisposed) {
                    dispatcher.BeginInvoke((MethodInvoker)delegate { if (!disposed) { callback(); } });
                }
            } catch (InvalidOperationException) { /* The user exited the tray while an action finished. */ }
        }

        protected override void ExitThreadCore() {
            if (tray != null) { tray.Visible = false; }
            base.ExitThreadCore();
        }

        protected override void Dispose(bool disposing) {
            if (disposing && !disposed) {
                disposed = true;
                if (runtimeMonitor != null) { runtimeMonitor.Dispose(); }
                if (exitWait != null) { exitWait.Unregister(null); }
                if (exitSignal != null) { exitSignal.Dispose(); }
                if (tray != null) { tray.Visible = false; tray.Dispose(); }
                if (menu != null) { menu.Dispose(); }
                if (icon != null) { icon.Dispose(); }
                if (iconBytes != null) { iconBytes.Dispose(); }
                if (dispatcher != null) { dispatcher.Dispose(); }
            }
            base.Dispose(disposing);
        }
    }
}
