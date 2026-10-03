// Existing desktop shell automation only. No tokens are changed or duplicated.
// https://learn.microsoft.com/windows/win32/shell/samples-execinexplorer
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace Immich.Windows {
    [ComImport, Guid("85CB6900-4D95-11CF-960C-0080C7F4EE85"), InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
    interface IDesktopShellWindows {
        [DispId(1610743816)]
        [return: MarshalAs(UnmanagedType.IDispatch)]
        object FindWindowSW(ref object location, ref object root, int windowClass, out int window, int options);
    }
    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDesktopServiceProvider {
        void QueryService(ref Guid service, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object value);
    }
    [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDesktopShellBrowser {
        // Unused vtable slots retain the SDK interface order.
        void GetWindow(); void ContextSensitiveHelp(); void InsertMenusSB(); void SetMenuSB();
        void RemoveMenusSB(); void SetStatusTextSB(); void EnableModelessSB(); void TranslateAcceleratorSB();
        void BrowseObject(); void GetViewStateStream(); void GetControlWindow(); void SendControlMsg();
        void QueryActiveShellView(out IDesktopShellView view);
    }
    [ComImport, Guid("000214E3-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDesktopShellView {
        void GetWindow(); void ContextSensitiveHelp(); void TranslateAccelerator(); void EnableModeless();
        void UIActivate(); void Refresh(); void CreateViewWindow(); void DestroyViewWindow();
        void GetCurrentInfo(); void AddPropertySheetPages(); void SaveViewState(); void SelectItem();
        void GetItemObject(uint item, ref Guid iid, [MarshalAs(UnmanagedType.IDispatch)] out object value);
    }

    public static class DesktopShell {
        internal const uint SvgioBackground = 0;
        internal const int SwcDesktop = 8, SwfoNeedDispatch = 1;
        [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("advapi32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool GetTokenInformation(IntPtr token, int infoClass, out int value, int size, out int returned);

        static IntPtr ReadProcessToken(Process process) {
            // Query only. In particular, do not ask for PROCESS_ALL_ACCESS on another user's shell.
            IntPtr handle = OpenProcess(0x1000, false, process.Id); // PROCESS_QUERY_LIMITED_INFORMATION
            if (handle == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            try {
                IntPtr token;
                if (!OpenProcessToken(handle, 0x0008, out token)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                return token;
            } finally { CloseHandle(handle); }
        }
        public static bool IsElevated(Process process) {
            IntPtr token = ReadProcessToken(process);
            try {
                int elevated, returned;
                if (!GetTokenInformation(token, 20, out elevated, sizeof(int), out returned)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return elevated != 0;
            } finally { CloseHandle(token); }
        }

        public static string ProcessUser(Process process) {
            IntPtr token = ReadProcessToken(process);
            try { using (var identity = new WindowsIdentity(token)) { return identity.User.Value; } }
            finally { CloseHandle(token); }
        }

        public static Process GetDesktopProcess() {
            IntPtr window = GetShellWindow();
            if (window == IntPtr.Zero) { return null; }
            uint id;
            GetWindowThreadProcessId(window, out id);
            var process = Process.GetProcessById(checked((int)id));
            using (var current = Process.GetCurrentProcess()) {
                if (process.SessionId != current.SessionId) {
                    process.Dispose();
                    throw new InvalidOperationException("The desktop shell belongs to another session.");
                }
            }
            return process;
        }

        public static void Execute(string file, string arguments, string directory) {
            using (var desktopProcess = GetDesktopProcess()) {
                if (desktopProcess == null) { throw new InvalidOperationException("No desktop shell is available in this session."); }
                if (IsElevated(desktopProcess)) { throw new InvalidOperationException("The desktop shell is elevated; refusing to start an elevated tray."); }
                object windows = null, desktop = null, browser = null, background = null, application = null;
                IDesktopShellView view = null;
                try {
                    // Find the desktop itself, even with no open Explorer folder windows.
                    windows = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39"), true));
                    object location = 0, root = null;
                    int window;
                    desktop = ((IDesktopShellWindows)windows).FindWindowSW(ref location, ref root, SwcDesktop, out window, SwfoNeedDispatch);
                    if (desktop == null) { throw new InvalidOperationException("The desktop shell automation object is unavailable."); }
                    uint owner;
                    GetWindowThreadProcessId(new IntPtr(window), out owner);
                    if (owner != desktopProcess.Id) { throw new InvalidOperationException("Desktop shell identity changed."); }
                    Guid service = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837");
                    Guid browserId = typeof(IDesktopShellBrowser).GUID;
                    ((IDesktopServiceProvider)desktop).QueryService(ref service, ref browserId, out browser);
                    ((IDesktopShellBrowser)browser).QueryActiveShellView(out view);
                    Guid dispatch = new Guid("00020400-0000-0000-C000-000000000046");
                    view.GetItemObject(SvgioBackground, ref dispatch, out background); // SVGIO_BACKGROUND
                    application = background.GetType().InvokeMember("Application", BindingFlags.GetProperty, null, background, null);
                    application.GetType().InvokeMember("ShellExecute", BindingFlags.InvokeMethod, null, application,
                        new object[] { file, arguments, directory, "open", 1 });
                } finally {
                    Release(application); Release(background); Release(view); Release(browser); Release(desktop); Release(windows);
                }
            }
        }
        static void Release(object value) { if (value != null && Marshal.IsComObject(value)) { Marshal.ReleaseComObject(value); } }
    }
}
