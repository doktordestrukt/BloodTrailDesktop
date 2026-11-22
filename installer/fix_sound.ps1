# BTDesktop: if Blood Trail is silent, Windows may have the game muted in its per-app Volume Mixer
# (Windows remembers that per program). Run this while the game is running: it lists where the
# game's sound goes and unmutes the game's audio sessions.
#   powershell -ExecutionPolicy Bypass -File fix_sound.ps1
$code = @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCo {}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
  int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
}
[Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceCollection { int GetCount(out int n); int Item(int i, out IMMDevice d); }
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate(ref Guid iid, int clsCtx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
  int OpenPropertyStore(int access, out IPropertyStore store);
  int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
}
[Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyStore { int GetCount(out int c); int GetAt(int i, out PROPERTYKEY k); int GetValue(ref PROPERTYKEY k, out PROPVARIANT v); }
[StructLayout(LayoutKind.Sequential)] struct PROPERTYKEY { public Guid fmtid; public int pid; }
[StructLayout(LayoutKind.Explicit)] struct PROPVARIANT { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr p; }
[Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2 {
  int a(); int b();
  int GetSessionEnumerator(out IAudioSessionEnumerator e);
}
[Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator { int GetCount(out int n); int GetSession(int i, out IAudioSessionControl2 s); }
[Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl2 {
  int GetState(out int s); int GetDisplayName(out IntPtr n); int SetDisplayName(string n, Guid g);
  int GetIconPath(out IntPtr p); int SetIconPath(string p, Guid g); int GetGroupingParam(out Guid g);
  int SetGroupingParam(Guid g, Guid c); int RegisterAudioSessionNotification(IntPtr n); int UnregisterAudioSessionNotification(IntPtr n);
  int GetSessionIdentifier(out IntPtr s); int GetSessionInstanceIdentifier(out IntPtr s); int GetProcessId(out int pid);
}
[Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioMeterInformation { int GetPeakValue(out float peak); }
[Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISimpleAudioVolume { int SetMasterVolume(float v, ref Guid g); int GetMasterVolume(out float v); int SetMute(bool m, ref Guid g); int GetMute(out bool m); }

public static class AudioProbe {
  public static bool Unmute = false;
  static string Name(IMMDevice d) {
    IPropertyStore ps; d.OpenPropertyStore(0, out ps);
    var key = new PROPERTYKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
    PROPVARIANT v; ps.GetValue(ref key, out v);
    return Marshal.PtrToStringUni(v.p);
  }
  public static List<string> Run() {
    var res = new List<string>();
    var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
    IMMDevice def; en.GetDefaultAudioEndpoint(0, 0, out def);
    res.Add("DEFAULT: " + Name(def));
    IMMDeviceCollection col; en.EnumAudioEndpoints(0, 1, out col);
    int n; col.GetCount(out n);
    for (int i = 0; i < n; i++) {
      IMMDevice d; col.Item(i, out d);
      res.Add("DEVICE: " + Name(d));
      Guid iid = typeof(IAudioSessionManager2).GUID; object o;
      d.Activate(ref iid, 23, IntPtr.Zero, out o);
      var sm = (IAudioSessionManager2)o;
      IAudioSessionEnumerator se; sm.GetSessionEnumerator(out se);
      int sc; se.GetCount(out sc);
      for (int j = 0; j < sc; j++) {
        IAudioSessionControl2 s; se.GetSession(j, out s);
        int pid; s.GetProcessId(out pid); int st; s.GetState(out st);
        float peak = -1; float vol = -1; bool mute = false;
        try { peak = 0; ((IAudioMeterInformation)s).GetPeakValue(out peak); } catch {}
        try { var sv = (ISimpleAudioVolume)s; sv.GetMasterVolume(out vol); sv.GetMute(out mute); } catch {}
        string pn0 = "?"; try { pn0 = System.Diagnostics.Process.GetProcessById(pid).ProcessName; } catch {}
        if (Unmute && mute && pn0.StartsWith("BTVR")) { try { var g = Guid.Empty; ((ISimpleAudioVolume)s).SetMute(false, ref g); ((ISimpleAudioVolume)s).GetMute(out mute); res.Add("   -> unmuted " + pn0); } catch (Exception ex) { res.Add("   -> unmute failed " + ex.Message); } }
        string pname = "?";
        try { pname = System.Diagnostics.Process.GetProcessById(pid).ProcessName; } catch {}
        res.Add(String.Format("   session pid {0} {1} state {2} peak {3:0.000} volume {4:0.00} muted {5}", pid, pname, st, peak, vol, mute));
      }
    }
    return res;
  }
}
'@
Add-Type -TypeDefinition $code
[AudioProbe]::Unmute = $true
for ($k = 0; $k -lt 1; $k++) { [AudioProbe]::Run() | Where-Object { $_ -notmatch 'session' -or $_ -match 'BTVR' }; Start-Sleep -Milliseconds 700 }
