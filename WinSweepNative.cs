// Native helpers for WinSweep. The installer compiles this file into WinSweep.Native.dll in
// C:\ProgramData\WinSweep (a folder only admins can change), so the scripts don't compile code
// while they run. When the scripts run from the source folder instead, they compile it themselves.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace WinSweep {
    public static class Native {
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
    }

    // Deletes files and empty folders only when they are really inside the folder being cleaned.
    //
    // A path can lead somewhere else if a folder on the way is a junction or symbolic link, and a
    // user can swap a folder for a link between the moment it is listed and the moment it is
    // deleted. So each item is opened first (without following a link at the item itself), the
    // real location of the open handle is checked, and the item is deleted through that same
    // handle. Whatever is deleted is exactly what was checked.
    public static class SafeDelete {
        public const int Deleted = 0, InUse = 1, Outside = 2, Gone = 3;

        const uint DELETE = 0x00010000, FILE_READ_ATTRIBUTES = 0x80;
        const uint SHARE_ALL = 7, OPEN_EXISTING = 3;
        const uint FLAG_BACKUP_SEMANTICS = 0x02000000, FLAG_OPEN_REPARSE_POINT = 0x00200000;
        const int FileDispositionInfo = 4, FileDispositionInfoEx = 21;
        const uint DISPOSITION_DELETE = 0x1, DISPOSITION_POSIX = 0x2, DISPOSITION_IGNORE_READONLY = 0x10;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
                                                 uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint size, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileInformationByHandle(SafeFileHandle file, int infoClass, ref uint info, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileInformationByHandle(SafeFileHandle file, int infoClass, ref byte info, uint size);

        // Real location of an open file or folder, without the \\?\ prefix.
        static string RealPath(SafeFileHandle handle) {
            StringBuilder buffer = new StringBuilder(1024);
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0 || length >= buffer.Capacity) return null;
            string path = buffer.ToString();
            if (path.StartsWith(@"\\?\UNC\")) return @"\\" + path.Substring(8);
            if (path.StartsWith(@"\\?\")) return path.Substring(4);
            return path;
        }

        static string Long(string path) {
            return path.StartsWith(@"\\") ? path : @"\\?\" + path;
        }

        // Returns the folder's real path if the folder and every folder above it are ordinary
        // folders. Returns null if the folder is missing or a link leads somewhere else.
        public static string CheckRoot(string path) {
            string wanted = Path.GetFullPath(path).TrimEnd('\\');
            using (SafeFileHandle handle = CreateFileW(Long(wanted), FILE_READ_ATTRIBUTES, SHARE_ALL,
                                                       IntPtr.Zero, OPEN_EXISTING, FLAG_BACKUP_SEMANTICS, IntPtr.Zero)) {
                if (handle.IsInvalid) return null;
                string real = RealPath(handle);
                if (real == null) return null;
                real = real.TrimEnd('\\');
                return string.Equals(real, wanted, StringComparison.OrdinalIgnoreCase) ? real : null;
            }
        }

        // Deletes a file, a link (not its target) or an empty folder that must be inside root
        // (a path returned by CheckRoot). Read-only files are deleted too.
        public static int Delete(string path, string root, bool isFolder) {
            uint flags = FLAG_OPEN_REPARSE_POINT | (isFolder ? FLAG_BACKUP_SEMANTICS : 0);
            using (SafeFileHandle handle = CreateFileW(Long(path), DELETE | FILE_READ_ATTRIBUTES, SHARE_ALL,
                                                       IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero)) {
                if (handle.IsInvalid) {
                    int error = Marshal.GetLastWin32Error();
                    return (error == 2 || error == 3) ? Gone : InUse;
                }
                string real = RealPath(handle);
                if (real == null || !real.StartsWith(root + @"\", StringComparison.OrdinalIgnoreCase)) return Outside;

                // Windows 10 1809 and later: delete now, even if read-only.
                uint flagsEx = DISPOSITION_DELETE | DISPOSITION_POSIX | DISPOSITION_IGNORE_READONLY;
                if (SetFileInformationByHandle(handle, FileDispositionInfoEx, ref flagsEx, 4)) return Deleted;
                // Older Windows: the classic way (fails for read-only files, which are then skipped).
                byte delete = 1;
                return SetFileInformationByHandle(handle, FileDispositionInfo, ref delete, 1) ? Deleted : InUse;
            }
        }
    }
}
