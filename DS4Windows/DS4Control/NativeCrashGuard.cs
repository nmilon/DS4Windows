/*
DS4Windows
Copyright (C) 2026 hbashton

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
*/

using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace DS4Windows
{
    /// <summary>
    /// Last-chance handler for native faults CoreCLR does not own. Windows
    /// otherwise shows the modal "instruction at ... referenced memory" hard
    /// error, which blocks shutdown until someone clicks OK. Record the faulting
    /// module and offset, then terminate without the popup.
    /// </summary>
    public static class NativeCrashGuard
    {
        private const uint GetModuleHandleExFlagFromAddress = 0x4;
        private const uint GetModuleHandleExFlagUnchangedRefcount = 0x2;
        private const int ExceptionExecuteHandler = 1;
        private const int ExceptionContinueSearch = 0;
        private const uint ClrExceptionCode = 0xE0434352;

        private delegate int TopLevelExceptionFilter(IntPtr exceptionPointers);

        // Kept in a static so the delegate outlives the native registration.
        private static TopLevelExceptionFilter filter;
        private static TopLevelExceptionFilter previousFilter;
        private static string logPath;
        private static string processRole;
        private static int handling;

        public static void Install(string role)
        {
            processRole = role;
            try
            {
                string logDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "DS4Windows", "Logs");
                Directory.CreateDirectory(logDir);
                logPath = Path.Combine(logDir, "native_crash.txt");
            }
            catch
            {
                logPath = null;
            }

            filter = OnUnhandledException;
            IntPtr previous = SetUnhandledExceptionFilter(filter);
            if (previous != IntPtr.Zero)
            {
                previousFilter = Marshal.GetDelegateForFunctionPointer<TopLevelExceptionFilter>(previous);
            }
        }

        private static int OnUnhandledException(IntPtr exceptionPointers)
        {
            // Unhandled managed exceptions keep CoreCLR's own reporting.
            IntPtr firstRecord = Marshal.ReadIntPtr(exceptionPointers);
            if (unchecked((uint)Marshal.ReadInt32(firstRecord)) == ClrExceptionCode)
            {
                return previousFilter?.Invoke(exceptionPointers) ?? ExceptionContinueSearch;
            }

            // A second fault while logging must not recurse.
            if (Interlocked.Exchange(ref handling, 1) == 0)
            {
                try
                {
                    // EXCEPTION_POINTERS { EXCEPTION_RECORD*, CONTEXT* }
                    // EXCEPTION_RECORD { DWORD code; DWORD flags; PVOID record; PVOID address; ... }
                    IntPtr record = Marshal.ReadIntPtr(exceptionPointers);
                    uint code = unchecked((uint)Marshal.ReadInt32(record));
                    IntPtr address = Marshal.ReadIntPtr(record, 8 + IntPtr.Size);

                    string module = "unknown module";
                    long offset = address.ToInt64();
                    if (GetModuleHandleExW(GetModuleHandleExFlagFromAddress |
                        GetModuleHandleExFlagUnchangedRefcount, address, out IntPtr moduleBase))
                    {
                        var name = new StringBuilder(520);
                        if (GetModuleFileNameW(moduleBase, name, (uint)name.Capacity) > 0)
                        {
                            module = name.ToString();
                        }

                        offset = address.ToInt64() - moduleBase.ToInt64();
                    }

                    if (logPath != null)
                    {
                        File.AppendAllText(logPath,
                            $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {processRole} pid={Environment.ProcessId} " +
                            $"thread={GetCurrentThreadId()} code=0x{code:X8} at {module}+0x{offset:X}" +
                            Environment.NewLine);
                    }
                }
                catch
                {
                }
            }

            TerminateProcess(GetCurrentProcess(), 0xC0000005);
            return ExceptionExecuteHandler;
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr SetUnhandledExceptionFilter(TopLevelExceptionFilter filter);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetModuleHandleExW(uint flags, IntPtr address,
            out IntPtr module);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetModuleFileNameW(IntPtr module, StringBuilder fileName,
            uint size);

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll")]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);
    }
}
