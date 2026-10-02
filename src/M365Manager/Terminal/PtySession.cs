using System.Collections;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace M365Manager.Terminal;

/// <summary>
/// Startet einen Prozess in einer Windows-Pseudokonsole (ConPTY) – dieselbe Technik wie Windows Terminal.
/// Ausgabe kommt als VT-Datenstrom (UTF-8), Eingabe wird als VT-Sequenzen geschrieben.
/// </summary>
public sealed class PtySession : IDisposable
{
    public event Action<string>? Output;
    public event Action<int>? Exited;

    private IntPtr _hpc;
    private IntPtr _hProcess;
    private IntPtr _hThread;
    private SafeFileHandle? _inputWrite;
    private SafeFileHandle? _outputRead;
    private FileStream? _inputStream;
    private readonly object _writeLock = new();
    private int _disposed;

    public int ProcessId { get; private set; }

    public static PtySession Start(string commandLine, string? workingDirectory, IDictionary<string, string?> environment, int cols, int rows)
    {
        var s = new PtySession();
        s.StartCore(commandLine, workingDirectory, environment, cols, rows);
        return s;
    }

    private void StartCore(string commandLine, string? workingDirectory, IDictionary<string, string?> environment, int cols, int rows)
    {
        if (!Native.CreatePipe(out var inputRead, out var inputWrite, IntPtr.Zero, 0) ||
            !Native.CreatePipe(out var outputRead, out var outputWrite, IntPtr.Zero, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe");

        var hr = Native.CreatePseudoConsole(new Native.COORD((short)cols, (short)rows), inputRead, outputWrite, 0, out _hpc);
        if (hr != 0) throw new Win32Exception(hr, "CreatePseudoConsole");

        // Die PTY-seitigen Enden gehören jetzt der Pseudokonsole.
        inputRead.Dispose();
        outputWrite.Dispose();
        _inputWrite = inputWrite;
        _outputRead = outputRead;

        var attrSize = IntPtr.Zero;
        Native.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        var attrList = Marshal.AllocHGlobal(attrSize);
        var envBlock = IntPtr.Zero;
        try
        {
            if (!Native.InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "InitializeProcThreadAttributeList");
            if (!Native.UpdateProcThreadAttribute(attrList, 0, (IntPtr)Native.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                    _hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateProcThreadAttribute");

            var si = new Native.STARTUPINFOEX();
            si.StartupInfo.cb = Marshal.SizeOf<Native.STARTUPINFOEX>();
            si.lpAttributeList = attrList;

            envBlock = Marshal.StringToHGlobalUni(BuildEnvironmentBlock(environment));
            var cmd = new StringBuilder(commandLine);

            if (!Native.CreateProcessW(null, cmd, IntPtr.Zero, IntPtr.Zero, false,
                    Native.EXTENDED_STARTUPINFO_PRESENT | Native.CREATE_UNICODE_ENVIRONMENT,
                    envBlock, workingDirectory, ref si, out var pi))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess");

            _hProcess = pi.hProcess;
            _hThread = pi.hThread;
            ProcessId = pi.dwProcessId;
        }
        finally
        {
            Native.DeleteProcThreadAttributeList(attrList);
            Marshal.FreeHGlobal(attrList);
            if (envBlock != IntPtr.Zero) Marshal.FreeHGlobal(envBlock);
        }

        _inputStream = new FileStream(_inputWrite, FileAccess.Write, 1, false);
    }

    /// <summary>Startet Lesen und Prozessüberwachung – erst aufrufen, nachdem Output/Exited abonniert sind.</summary>
    public void Run()
    {
        var reader = new Thread(ReadLoop) { IsBackground = true, Name = "pty-read" };
        reader.Start();

        var waiter = new Thread(() =>
        {
            var hProcess = _hProcess;
            Native.WaitForSingleObject(hProcess, Native.INFINITE);
            Native.GetExitCodeProcess(hProcess, out var code);
            if (_disposed == 0) Exited?.Invoke((int)code);
            // Nur dieser Thread schließt die Prozess-Handles.
            Native.CloseHandle(_hThread);
            Native.CloseHandle(hProcess);
        }) { IsBackground = true, Name = "pty-wait" };
        waiter.Start();
    }

    private void ReadLoop()
    {
        var decoder = Encoding.UTF8.GetDecoder();
        var bytes = new byte[16384];
        var chars = new char[Encoding.UTF8.GetMaxCharCount(bytes.Length)];
        try
        {
            using var stream = new FileStream(_outputRead!, FileAccess.Read, 1, false);
            int n;
            while ((n = stream.Read(bytes, 0, bytes.Length)) > 0)
            {
                var c = decoder.GetChars(bytes, 0, n, chars, 0);
                if (c > 0) Output?.Invoke(new string(chars, 0, c));
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    public void Write(string text)
    {
        if (_disposed != 0 || _inputStream is null) return;
        var data = Encoding.UTF8.GetBytes(text);
        lock (_writeLock)
        {
            try
            {
                _inputStream.Write(data, 0, data.Length);
                _inputStream.Flush();
            }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
        }
    }

    private static readonly object ConsoleGate = new();

    /// <summary>
    /// Macht <paramref name="owner"/> zum Besitzer des (unsichtbaren) Pseudokonsolen-Fensters.
    /// Anmeldedialoge (WAM/MSAL) nutzen dieses Fenster als Parent – ohne Besitzer landen sie
    /// unsichtbar im Hintergrund und ohne Taskleisteneintrag. Gleiches Vorgehen wie Windows Terminal.
    /// </summary>
    public bool SetConsoleOwner(IntPtr owner)
    {
        if (_disposed != 0 || owner == IntPtr.Zero || ProcessId == 0) return false;
        lock (ConsoleGate)
        {
            if (!Native.AttachConsole((uint)ProcessId)) return false;
            try
            {
                var console = Native.GetConsoleWindow();
                if (console == IntPtr.Zero) return false;
                Native.SetWindowLongPtr(console, Native.GWLP_HWNDPARENT, owner);
                return true;
            }
            finally
            {
                Native.FreeConsole();
            }
        }
    }

    public void Resize(int cols, int rows)
    {
        if (_disposed != 0 || _hpc == IntPtr.Zero || cols < 2 || rows < 2) return;
        Native.ResizePseudoConsole(_hpc, new Native.COORD((short)cols, (short)rows));
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;

        try { _inputStream?.Dispose(); } catch { }

        var hpc = _hpc;
        _hpc = IntPtr.Zero;
        var hProcess = _hProcess;

        // ClosePseudoConsole kann blockieren, bis die Ausgabe gelesen wurde – daher im Hintergrund.
        Task.Run(() =>
        {
            if (hpc != IntPtr.Zero) Native.ClosePseudoConsole(hpc);
            if (hProcess != IntPtr.Zero && Native.WaitForSingleObject(hProcess, 3000) == Native.WAIT_TIMEOUT)
                Native.TerminateProcess(hProcess, 1);
            try { _outputRead?.Dispose(); } catch { }
        });
    }

    private static string BuildEnvironmentBlock(IDictionary<string, string?> overrides)
    {
        var env = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry e in Environment.GetEnvironmentVariables())
            env[(string)e.Key] = (string?)e.Value ?? "";
        foreach (var (k, v) in overrides)
        {
            if (v is null) env.Remove(k); else env[k] = v;
        }

        var sb = new StringBuilder();
        foreach (var (k, v) in env)
            sb.Append(k).Append('=').Append(v).Append('\0');
        sb.Append('\0');
        return sb.ToString();
    }

    private static class Native
    {
        public const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        public const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        public const int PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;
        public const uint INFINITE = 0xFFFFFFFF;
        public const uint WAIT_TIMEOUT = 0x00000102;

        [StructLayout(LayoutKind.Sequential)]
        public struct COORD
        {
            public short X;
            public short Y;
            public COORD(short x, short y) { X = x; Y = y; }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFO
        {
            public int cb;
            public IntPtr lpReserved;
            public IntPtr lpDesktop;
            public IntPtr lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct STARTUPINFOEX
        {
            public STARTUPINFO StartupInfo;
            public IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern int CreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out IntPtr phPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern int ResizePseudoConsole(IntPtr hPC, COORD size);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern void ClosePseudoConsole(IntPtr hPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CreatePipe(out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe, IntPtr lpPipeAttributes, int nSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateProcessW")]
        public static extern bool CreateProcessW(string? lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
            bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string? lpCurrentDirectory, ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);

        public const int GWLP_HWNDPARENT = -8;

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AttachConsole(uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool FreeConsole();

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
        public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
    }
}