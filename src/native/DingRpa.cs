using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class DingRpa {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
    [StructLayout(LayoutKind.Sequential)] public struct GuiInfo {
        public uint Size, Flags; public IntPtr Active,Focus,Capture,MenuOwner,MoveSize,Caret; public Rect CaretRect;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MouseInput { public int X,Y; public uint Data,Flags,Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] public struct KeyInput { public ushort Key,Scan; public uint Flags,Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Explicit)] public struct InputData { [FieldOffset(0)] public MouseInput Mouse; [FieldOffset(0)] public KeyInput Keyboard; }
    [StructLayout(LayoutKind.Sequential)] public struct Input { public uint Type; public InputData Data; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int size);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int size);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetGUIThreadInfo(uint threadId, ref GuiInfo info);
    [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd,uint flags);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint message,UIntPtr wparam,IntPtr lparam,uint flags,uint timeout,out UIntPtr result);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint threadId);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder text, uint length, out uint needed);
    public sealed class WindowInfo { public long Handle; public uint ProcessId; public string Title; public string ClassName; public bool Visible; }
    public static WindowInfo ReadWindow(IntPtr hwnd) {
        uint pid; GetWindowThreadProcessId(hwnd,out pid);
        var title=new StringBuilder(4096); GetWindowText(hwnd,title,title.Capacity);
        var cls=new StringBuilder(512); GetClassName(hwnd,cls,cls.Capacity);
        return new WindowInfo {Handle=hwnd.ToInt64(),ProcessId=pid,Title=title.ToString(),ClassName=cls.ToString(),Visible=IsWindowVisible(hwnd)};
    }
    public static WindowInfo[] ListWindows() {
        var result = new List<WindowInfo>();
        EnumWindows((hwnd, data) => {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            var title = new StringBuilder(4096); GetWindowText(hwnd, title, title.Capacity);
            var cls = new StringBuilder(512); GetClassName(hwnd, cls, cls.Capacity);
            result.Add(new WindowInfo {Handle=hwnd.ToInt64(),ProcessId=pid,Title=title.ToString(),ClassName=cls.ToString(),Visible=IsWindowVisible(hwnd)});
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
    public static string DesktopName() {
        var name = new StringBuilder(512); uint needed;
        if (!GetUserObjectInformation(GetThreadDesktop(GetCurrentThreadId()),2,name,(uint)(name.Capacity*2),out needed)) return "unavailable:" + Marshal.GetLastWin32Error();
        return name.ToString();
    }
    public static string InputDesktopName() {
        IntPtr desktop=OpenInputDesktop(0,false,1);
        if(desktop==IntPtr.Zero) return "unavailable:"+Marshal.GetLastWin32Error();
        try {
            var name=new StringBuilder(512); uint needed;
            if(!GetUserObjectInformation(desktop,2,name,(uint)(name.Capacity*2),out needed)) return "unavailable:"+Marshal.GetLastWin32Error();
            return name.ToString();
        } finally { CloseDesktop(desktop); }
    }
    public static string ActivateTarget(IntPtr hwnd,uint expectedProcessId) {
        uint targetProcessId;
        if(hwnd==IntPtr.Zero || GetWindowThreadProcessId(hwnd,out targetProcessId)==0 || targetProcessId!=expectedProcessId)
            throw new InvalidOperationException("Activation target identity changed");
        if(DesktopName()!="Default" || InputDesktopName()!="Default") throw new InvalidOperationException("Interactive Default desktop is unavailable");
        foreach(int key in new int[]{0x1b,0x10,0x11,0x12,0x5b,0x5c})
            if((GetAsyncKeyState(key)&0x8000)!=0) throw new InvalidOperationException("User key is held; stopping activation");
        if(GetForegroundWindow()==hwnd) return "AlreadyForeground";
        if(IsIconic(hwnd)) ShowWindowAsync(hwnd,9);
        SetForegroundWindow(hwnd);
        System.Threading.Thread.Sleep(250);
        if(GetForegroundWindow()==hwnd) return "SetForegroundWindow";
        BringWindowToTop(hwnd);
        System.Threading.Thread.Sleep(150);
        if(GetForegroundWindow()==hwnd) return "BringWindowToTop";
        // Use a real, exposed caption hit, never a stale pixel or a click in another app.
        Rect bounds;
        if(!GetWindowRect(hwnd,out bounds) || IsIconic(hwnd)) return "ActivationDenied";
        var timer=System.Diagnostics.Stopwatch.StartNew();
        for(int y=bounds.Top+12;y<Math.Min(bounds.Top+60,bounds.Bottom);y+=12) {
            for(int x=bounds.Left+80;x<bounds.Right-160;x+=40) {
                if(timer.ElapsedMilliseconds>2500) return "ActivationDenied";
                IntPtr hit=WindowFromPoint(new Point{X=x,Y=y});
                if(hit!=hwnd && GetAncestor(hit,2)!=hwnd) continue;
                UIntPtr answer;
                IntPtr packed=new IntPtr(unchecked((int)(((uint)(ushort)y<<16)|(ushort)x)));
                if(SendMessageTimeout(hwnd,0x84,UIntPtr.Zero,packed,2,80,out answer)==IntPtr.Zero || answer.ToUInt64()!=2) continue;
                if((GetAsyncKeyState(0x1b)&0x8000)!=0) throw new InvalidOperationException("User pressed Escape");
                hit=WindowFromPoint(new Point{X=x,Y=y});
                if(hit!=hwnd && GetAncestor(hit,2)!=hwnd) continue;
                if(!SetCursorPos(x,y)) return "ActivationDenied";
                var down=new Input(); down.Type=0; down.Data.Mouse.Flags=2;
                var up=new Input(); up.Type=0; up.Data.Mouse.Flags=4;
                if(SendInput(2,new Input[]{down,up},Marshal.SizeOf(typeof(Input)))!=2) {
                    SendInput(1,new Input[]{up},Marshal.SizeOf(typeof(Input)));
                    throw new InvalidOperationException("Caption activation outcome unknown");
                }
                System.Threading.Thread.Sleep(250);
                return GetForegroundWindow()==hwnd?"CaptionMouseClick":"ActivationDenied";
            }
        }
        return "ActivationDenied";
    }
    public static GuiInfo GetMenuState(IntPtr hwnd) {
        uint pid; uint threadId=GetWindowThreadProcessId(hwnd,out pid);
        if (threadId==0) throw new InvalidOperationException("Target window is no longer available");
        var info=new GuiInfo(); info.Size=(uint)Marshal.SizeOf(typeof(GuiInfo));
        if (!GetGUIThreadInfo(threadId,ref info)) throw new InvalidOperationException("GetGUIThreadInfo failed: "+Marshal.GetLastWin32Error());
        return info;
    }
    public static bool MenuIsOpen(IntPtr hwnd) {
        var info=GetMenuState(hwnd); return (info.Flags & 0x1c)!=0 && info.MenuOwner==hwnd;
    }
    static Input Key(ushort key,bool up) {
        var input=new Input(); input.Type=1; input.Data.Keyboard.Key=key; input.Data.Keyboard.Flags=up?2u:0u; return input;
    }
    static void AssertTextInputTarget(IntPtr hwnd) {
        if(hwnd==IntPtr.Zero || GetForegroundWindow()!=hwnd) throw new InvalidOperationException("Text target window lost focus");
        foreach(int key in new int[]{0x1b,0x10,0x11,0x12,0x5b,0x5c})
            if((GetAsyncKeyState(key)&0x8000)!=0) throw new InvalidOperationException("User key is held; stopping text input");
    }
    // The caller must first verify the focused editor and its existing value through UIA.
    public static void PressEnter(IntPtr hwnd) {
        AssertTextInputTarget(hwnd);
        var inputs=new Input[]{Key(0x0d,false),Key(0x0d,true)};
        if(SendInput(2,inputs,Marshal.SizeOf(typeof(Input)))!=2) {
            SendInput(1,new Input[]{Key(0x0d,true)},Marshal.SizeOf(typeof(Input)));
            throw new InvalidOperationException("Enter input outcome unknown; inspect before retrying");
        }
    }
    public static void TypeUnicodeText(IntPtr hwnd,string text) {
        if(String.IsNullOrEmpty(text) || text.Length>1000) throw new ArgumentException("Text length must be 1 through 1000");
        foreach(char character in text)
            if(Char.IsControl(character)) throw new ArgumentException("Control characters are not allowed");
        AssertTextInputTarget(hwnd);
        foreach(char character in text) {
            AssertTextInputTarget(hwnd);
            var down=new Input(); down.Type=1; down.Data.Keyboard.Scan=character; down.Data.Keyboard.Flags=4;
            var up=down; up.Data.Keyboard.Flags=6;
            if(SendInput(2,new Input[]{down,up},Marshal.SizeOf(typeof(Input)))!=2) {
                SendInput(1,new Input[]{up},Marshal.SizeOf(typeof(Input)));
                throw new InvalidOperationException("Text input outcome unknown; inspect before retrying");
            }
            System.Threading.Thread.Sleep(15);
        }
    }
    public static uint OpenSystemMenu(IntPtr hwnd) {
        if (GetForegroundWindow()!=hwnd) throw new InvalidOperationException("Target window lost focus");
        foreach(int key in new int[]{0x1b,0x10,0x11,0x12,0x5b,0x5c})
            if ((GetAsyncKeyState(key)&0x8000)!=0) throw new InvalidOperationException("User key is held; stopping input");
        var inputs=new Input[]{Key(0x12,false),Key(0x20,false),Key(0x20,true),Key(0x12,true)};
        uint sent=SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(Input)));
        if(sent!=inputs.Length) {
            var release=new Input[]{Key(0x20,true),Key(0x12,true)};
            SendInput((uint)release.Length,release,Marshal.SizeOf(typeof(Input)));
            throw new InvalidOperationException("Input injection incomplete: "+sent);
        }
        return sent;
    }
    public static void CloseSystemMenu(IntPtr hwnd) {
        if(GetForegroundWindow()!=hwnd || !MenuIsOpen(hwnd)) return;
        var inputs=new Input[]{Key(0x1b,false),Key(0x1b,true)};
        if(SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(Input)))!=inputs.Length)
            throw new InvalidOperationException("Could not send menu-close key");
    }
    public static void ClickPoint(IntPtr hwnd,int x,int y) {
        if(GetForegroundWindow()!=hwnd) throw new InvalidOperationException("Target window lost focus");
        if((GetAsyncKeyState(0x1b)&0x8000)!=0) throw new InvalidOperationException("User pressed Escape");
        var point=new Point{X=x,Y=y}; var hit=WindowFromPoint(point);
        if(hit!=hwnd && GetAncestor(hit,2)!=hwnd) throw new InvalidOperationException("Click point is covered by another window");
        if(!SetCursorPos(x,y)) throw new InvalidOperationException("Could not move pointer");
        var down=new Input(); down.Type=0; down.Data.Mouse.Flags=2;
        var up=new Input(); up.Type=0; up.Data.Mouse.Flags=4;
        var inputs=new Input[]{down,up};
        if(SendInput(2,inputs,Marshal.SizeOf(typeof(Input)))!=2) {
            SendInput(1,new Input[]{up},Marshal.SizeOf(typeof(Input)));
            throw new InvalidOperationException("Mouse input incomplete");
        }
    }
    public static void WheelDown(IntPtr hwnd,int x,int y) {
        if(GetForegroundWindow()!=hwnd) throw new InvalidOperationException("Target window lost focus");
        if((GetAsyncKeyState(0x1b)&0x8000)!=0) throw new InvalidOperationException("User pressed Escape");
        var hit=WindowFromPoint(new Point{X=x,Y=y});
        if(hit!=hwnd && GetAncestor(hit,2)!=hwnd) throw new InvalidOperationException("Scroll point is covered by another window");
        if(!SetCursorPos(x,y)) throw new InvalidOperationException("Could not position pointer");
        var input=new Input(); input.Type=0; input.Data.Mouse.Flags=0x0800; input.Data.Mouse.Data=unchecked((uint)-1200);
        if(SendInput(1,new Input[]{input},Marshal.SizeOf(typeof(Input)))!=1) throw new InvalidOperationException("Scroll input failed");
    }
}
