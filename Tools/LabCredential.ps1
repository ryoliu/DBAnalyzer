# Windows Credential Manager storage authorized for this lab account.
if (-not ('DBAnalyzerLabCredential' -as [type])) {
    Add-Type @"
using System;
using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;

public static class DBAnalyzerLabCredential {
    private const string Target = "DBAnalyzer/WIN2019LAB/Administrator";
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential {
        public uint Flags, Type;
        public string TargetName, Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CredWrite(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr credential);

    public static void Save(string userName, string password) {
        IntPtr blob = Marshal.StringToCoTaskMemUni(password);
        try {
            Credential value = new Credential();
            value.Type = 1;
            value.TargetName = Target;
            value.UserName = userName;
            value.CredentialBlobSize = (uint)(password.Length * 2);
            value.CredentialBlob = blob;
            value.Persist = 2;
            if (!CredWrite(ref value, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.ZeroFreeCoTaskMemUnicode(blob); }
    }

    public static NetworkCredential Load() {
        IntPtr pointer;
        if (!CredRead(Target, 1, 0, out pointer)) {
            int error = Marshal.GetLastWin32Error();
            if (error == 1168) return null;
            throw new Win32Exception(error);
        }
        try {
            Credential value = (Credential)Marshal.PtrToStructure(pointer, typeof(Credential));
            string password = Marshal.PtrToStringUni(value.CredentialBlob, (int)value.CredentialBlobSize / 2);
            return new NetworkCredential(value.UserName, password);
        } finally { CredFree(pointer); }
    }
}
"@
}
