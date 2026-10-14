using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

public static class ReplySession {
    [StructLayout(LayoutKind.Sequential)]
    struct SessionInfo { public int Id; public IntPtr Station; public int State; }
    [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool WTSEnumerateSessionsW(IntPtr server, int reserved, int version, out IntPtr sessions, out int count);
    [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool WTSQuerySessionInformationW(IntPtr server, int session, int info, out IntPtr buffer, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr memory);
    static string Query(int session, int info) {
        IntPtr buffer; int bytes;
        if (!WTSQuerySessionInformationW(IntPtr.Zero, session, info, out buffer, out bytes))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try { return Marshal.PtrToStringUni(buffer) ?? ""; }
        finally { WTSFreeMemory(buffer); }
    }
    public sealed class UserSession { public int SessionId; public string UserSid; public bool Active; }
    public static UserSession[] List() {
        IntPtr buffer; int count;
        if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out buffer, out count))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        var result = new List<UserSession>();
        try {
            int size = Marshal.SizeOf(typeof(SessionInfo));
            for (int i=0; i<count; i++) {
                var session = (SessionInfo)Marshal.PtrToStructure(IntPtr.Add(buffer, i*size), typeof(SessionInfo));
                if (session.Id<=0 || session.State!=0) continue; // WTSActive only.
                string user = Query(session.Id, 5), domain = Query(session.Id, 7);
                if (user.Length==0) continue;
                string account = domain.Length==0 ? user : domain+"\\"+user;
                string sid = new NTAccount(account).Translate(typeof(SecurityIdentifier)).Value;
                result.Add(new UserSession {SessionId=session.Id, UserSid=sid, Active=true});
            }
        } finally { WTSFreeMemory(buffer); }
        return result.ToArray();
    }
}
