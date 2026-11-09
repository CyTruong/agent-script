#requires -Version 5.1
<#
MomoBleAgent.ps1
A PC-side agent for the MOMO ESP32-S3 device. It connects once over BLE GATT and
then runs a single loop: it asks the device for the next pending request, carries
it out on this PC, and reports back. Requests originate from the web config page
and are queued on the device.

Uses only what ships with Windows (WinRT BLE API, System.Drawing, Win32 user32);
nothing to install. Run from Windows PowerShell 5.1 (not PowerShell 7):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MomoBleAgent.ps1

Device protocol (over the CMD characteristic, UTF-8 text, reply <= ~90 bytes):
  The agent writes "REQ"; the device replies with the next queued request, or
  "none" when the queue is empty. One request per line:
    move <x> <y>            move the cursor to screen pixel (x,y)
    click <x> <y> <btn>     move to (x,y) then click (btn 1=left 2=right 4=middle)
    click <btn>             click at the current position
    scroll <notches>        wheel (+ = up, - = down)
    key <name>              one key: enter tab esc backspace delete up down
                            left right home end win space
    type <text>             type a string (Unicode, via clipboard paste)
    shot [threshold]        capture the screen and send it (full/delta, 0..255
                            threshold optional; keeps the last value otherwise)
  Mouse/keyboard are performed locally with Win32 (SetCursorPos / mouse_event /
  keybd_event), so they are pixel-exact and handle Unicode. "shot" reuses the
  full-frame + changed-tile (delta) upload over the DATA characteristic.

  FIRMWARE/WEB SUPPORT NEEDED: the device must implement CMD "REQ" (pop the next
  queued request, or "none") and the web page must enqueue requests. Until that
  is added, "REQ" returns "ERR unknown REQ" and the agent idles.

GATT UUIDs:
  Service 6d6f00f0-... INFO ...f1  STATUS ...f2  CMD ...f3  DATA ...f4
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Compiled types live for the whole PowerShell session, so re-running this script
# (or running it after the capture script, which defines the same types) in one
# window would fail with "type already exists". Only add a type when missing.
function Add-MomoType {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Def)
    if (-not ($Name -as [type])) { Add-Type -TypeDefinition $Def }
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# HTTP tuning for the LAN frame upload: no 100-continue round-trip, no Nagle
# batching delay, and keep the connection alive across frames.
[System.Net.ServicePointManager]::Expect100Continue = $false
[System.Net.ServicePointManager]::UseNagleAlgorithm = $false
[System.Net.ServicePointManager]::DefaultConnectionLimit = 4

# DPI awareness: so screen capture and SetCursorPos use physical pixels, matching
# the coordinates the web page sends. Must run before any screen query.
Add-MomoType 'MomoDpi' @'
public static class MomoDpi {
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@
$null = [MomoDpi]::SetProcessDPIAware()

# UI Automation: let the agent look up a control's REAL screen coordinates by its
# (visible) name, exact and vision-free. Assemblies ship with .NET Framework WPF.
try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $script:UiaOk = $true
} catch {
    $script:UiaOk = $false
    Write-Host 'UIAutomation không nạp được -> lệnh uia sẽ trả none (agent tự dùng vision).' -ForegroundColor DarkYellow
}
Add-MomoType 'MomoFg' @'
using System;
using System.Runtime.InteropServices;
public static class MomoFg {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@

# Win32 input + cursor. Mouse/keyboard are injected here on the PC (not as BLE
# HID), so moves are pixel-exact and typing is done by clipboard paste (Unicode).
Add-MomoType 'MomoInput' @'
using System;
using System.Runtime.InteropServices;
public static class MomoInput {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint f, int dx, int dy, int data, IntPtr ex);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte sc, uint f, IntPtr ex);

    const uint M_LDOWN = 0x02, M_LUP = 0x04, M_RDOWN = 0x08, M_RUP = 0x10,
               M_MDOWN = 0x20, M_MUP = 0x40, M_WHEEL = 0x800, K_UP = 0x02;

    public static POINT Get() { POINT p; GetCursorPos(out p); return p; }
    public static void MoveTo(int x, int y) { SetCursorPos(x, y); }
    public static void Click(int x, int y, int btn) {
        SetCursorPos(x, y);
        uint d = M_LDOWN, u = M_LUP;
        if (btn == 2) { d = M_RDOWN; u = M_RUP; } else if (btn == 4) { d = M_MDOWN; u = M_MUP; }
        mouse_event(d, 0, 0, 0, IntPtr.Zero);
        mouse_event(u, 0, 0, 0, IntPtr.Zero);
    }
    public static void Scroll(int notches) { mouse_event(M_WHEEL, 0, 0, notches * 120, IntPtr.Zero); }
    public static void Key(byte vk) { keybd_event(vk, 0, 0, IntPtr.Zero); keybd_event(vk, 0, K_UP, IntPtr.Zero); }
    // Hold modifiers, tap the key, release modifiers in reverse (Ctrl+C, Alt+Tab...).
    public static void Combo(byte[] mods, byte vk) {
        foreach (byte m in mods) { keybd_event(m, 0, 0, IntPtr.Zero); }
        keybd_event(vk, 0, 0, IntPtr.Zero);
        keybd_event(vk, 0, K_UP, IntPtr.Zero);
        for (int i = mods.Length - 1; i >= 0; i--) { keybd_event(mods[i], 0, K_UP, IntPtr.Zero); }
    }
    public static void Paste() {            // Ctrl+V
        keybd_event(0x11, 0, 0, IntPtr.Zero);
        keybd_event(0x56, 0, 0, IntPtr.Zero);
        keybd_event(0x56, 0, K_UP, IntPtr.Zero);
        keybd_event(0x11, 0, K_UP, IntPtr.Zero);
    }
}
'@

$script:ServiceUuid = [Guid]'6d6f00f0-e5f4-0312-2130-4f5e6d7c8b9a'
$script:InfoUuid    = [Guid]'6d6f00f1-e5f4-0312-2130-4f5e6d7c8b9a'
$script:StatusUuid  = [Guid]'6d6f00f2-e5f4-0312-2130-4f5e6d7c8b9a'
$script:CmdUuid     = [Guid]'6d6f00f3-e5f4-0312-2130-4f5e6d7c8b9a'
$script:DataUuid    = [Guid]'6d6f00f4-e5f4-0312-2130-4f5e6d7c8b9a'

# Windows Runtime projection used by the Windows BLE API.
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.BluetoothCacheMode, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristic, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattSession, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IBuffer, Windows.Storage.Streams, ContentType = WindowsRuntime]
}
catch {
    Write-Host 'Không thể nạp Windows Runtime BLE API.' -ForegroundColor Red
    Write-Host 'Hãy chạy bằng Windows PowerShell 5.1 trên Windows 10/11, không phải PowerShell 7.' -ForegroundColor Yellow
    Write-Host $_.Exception.Message -ForegroundColor DarkRed
    exit 1
}

$script:AsTaskGeneric = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } |
    Select-Object -First 1

$script:Uncached = [Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached

# IBuffer <-> byte[]: PowerShell 5.1 sees a GATT value as a bare __ComObject;
# invoking through reflection lets the CLR do the COM cast.
$script:BufferToArray = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions].GetMethod(
    'ToArray', [Type[]]@([Windows.Storage.Streams.IBuffer]))
$script:ArraySliceToBuffer = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions].GetMethod(
    'AsBuffer', [Type[]]@([byte[]], [int], [int]))
$script:ArrayToBuffer = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions].GetMethod(
    'AsBuffer', [Type[]]@([byte[]]))
$script:AsTaskWriteResult = $script:AsTaskGeneric.MakeGenericMethod(
    [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteResult])

# CRC-32 (zlib), same as the firmware's esp_rom_crc32_le, for frame headers.
Add-MomoType 'MomoCrc32' @'
public static class MomoCrc32 {
    static readonly uint[] T = Build();
    static uint[] Build() {
        var t = new uint[256];
        for (uint i = 0; i < 256; i++) {
            uint c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            t[i] = c;
        }
        return t;
    }
    public static uint Compute(byte[] data) {
        uint c = 0xFFFFFFFFu;
        foreach (byte b in data) c = T[(c ^ b) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }
}
'@

# Screen -> padded canvas + changed-tile delta, matching the firmware. Named
# MomoImg (not MomoMono) so it can coexist with the capture script's MomoMono in
# one session. Bit/byte conventions: MONO1 = 1-bit, MSB leftmost, bit 1 = white;
# GRAY8 = one luminance byte/pixel. Canvas padded to a 16x16 tile.
Add-MomoType 'MomoImg' @'
using System.Collections.Generic;
public static class MomoImg {
    public const int TILE = 16;
    // 1-bit pack (BLE path): black (clear bit) when luminance < thr, else white.
    public static byte[] PackMono(byte[] src, int ss, int w, int h, int dsPad, int hPad, int thr) {
        int total = dsPad * hPad;
        byte[] d = new byte[total];
        for (int i = 0; i < total; i++) { d[i] = 0xff; }
        for (int y = 0; y < h; y++) {
            int sr = y * ss, dr = y * dsPad;
            for (int x = 0; x < w; x++) {
                int i = sr + x * 3;
                int lum = (299 * src[i + 2] + 587 * src[i + 1] + 114 * src[i]) / 1000;
                if (lum < thr) { d[dr + (x >> 3)] &= (byte)~(0x80 >> (x & 7)); }
            }
        }
        return d;
    }
    // 8-bit grayscale pack (LAN path): one luminance byte per pixel; pad = white.
    public static byte[] PackGray8(byte[] src, int ss, int w, int h, int dsPad, int hPad) {
        int total = dsPad * hPad;
        byte[] d = new byte[total];
        for (int i = 0; i < total; i++) { d[i] = 0xff; }
        for (int y = 0; y < h; y++) {
            int sr = y * ss, dr = y * dsPad;
            for (int x = 0; x < w; x++) {
                int i = sr + x * 3;
                d[dr + x] = (byte)((299 * src[i + 2] + 587 * src[i + 1] + 114 * src[i]) / 1000);
            }
        }
        return d;
    }
    // Changed tiles. trb = bytes per tile row (MONO1 = 2, GRAY8 = 16). Payload:
    // count(u16 LE) then count x [idx(u16 LE) + TILE*trb bytes]. null if too big.
    public static byte[] EncodeDelta(byte[] prev, byte[] cur, int w, int h, int dsPad, int trb, int maxBytes) {
        int cols = (w + TILE - 1) / TILE, rows = (h + TILE - 1) / TILE, count = 0;
        var body = new List<byte>();
        for (int tr = 0; tr < rows; tr++) for (int tc = 0; tc < cols; tc++) {
            int baseoff = tc * trb; bool diff = false;
            for (int r = 0; r < TILE && !diff; r++) {
                int off = (tr * TILE + r) * dsPad + baseoff;
                for (int bx = 0; bx < trb; bx++) { if (prev[off + bx] != cur[off + bx]) { diff = true; break; } }
            }
            if (!diff) { continue; }
            int idx = tr * cols + tc;
            body.Add((byte)(idx & 0xff)); body.Add((byte)(idx >> 8));
            for (int r = 0; r < TILE; r++) {
                int off = (tr * TILE + r) * dsPad + baseoff;
                for (int bx = 0; bx < trb; bx++) { body.Add(cur[off + bx]); }
            }
            count++;
            if (2 + body.Count >= maxBytes) { return null; }
        }
        byte[] o = new byte[2 + body.Count];
        o[0] = (byte)(count & 0xff); o[1] = (byte)(count >> 8);
        body.CopyTo(o, 2);
        return o;
    }
}
'@

# --- BLE plumbing -----------------------------------------------------------

function Wait-WinRT {
    param([Parameter(Mandatory)] $Operation, [Parameter(Mandatory)] [Type] $ResultType, [int] $TimeoutSeconds = 30)
    $task = $script:AsTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    try { $done = $task.Wait([TimeSpan]::FromSeconds($TimeoutSeconds)) }
    catch { $e = $_.Exception; while ($null -ne $e.InnerException) { $e = $e.InnerException }; throw $e.Message }
    if (-not $done) { throw "BLE operation timed out after $TimeoutSeconds seconds." }
    return $task.Result
}

function Get-BleDeviceList {
    $selector = [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelector()
    $items = Wait-WinRT `
        ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector)) `
        ([Windows.Devices.Enumeration.DeviceInformationCollection]) 30
    $list = @()
    foreach ($item in $items) {
        $list += [pscustomobject]@{ Name = $item.Name; Id = $item.Id; IsPaired = $item.Pairing.IsPaired }
    }
    return $list
}

function Get-GattService {
    param([Parameter(Mandatory)] $BleDevice, [Parameter(Mandatory)] [Guid] $Uuid)
    $result = Wait-WinRT `
        ($BleDevice.GetGattServicesForUuidAsync($Uuid, $script:Uncached)) `
        ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult]) 30
    if ($result.Status.ToString() -ne 'Success') { throw "Không lấy được GATT service $Uuid. Status: $($result.Status)" }
    $services = @($result.Services)
    if ($services.Count -lt 1) { throw "Không tìm thấy service $Uuid trên thiết bị." }
    return $services[0]
}

function Get-GattCharacteristic {
    param([Parameter(Mandatory)] $Service, [Parameter(Mandatory)] [Guid] $Uuid, [Parameter(Mandatory)] [string] $Label)
    try {
        $result = Wait-WinRT `
            ($Service.GetCharacteristicsForUuidAsync($Uuid, $script:Uncached)) `
            ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult]) 30
    }
    catch {
        if ($_.Exception.Message -match '0x80070016') {
            throw ('Windows đang giữ bảng GATT cũ (firmware đã đổi characteristic). ' +
                   'Vào Settings > Bluetooth & devices, Remove device "Momo HID", rồi pair lại.')
        }
        throw
    }
    if ($result.Status.ToString() -ne 'Success') { throw "Không truy vấn được characteristic $Label ($Uuid). Status: $($result.Status)" }
    $characteristics = @($result.Characteristics)
    if ($characteristics.Count -lt 1) { throw "Không tìm thấy characteristic $Label ($Uuid). Kiểm tra UUID/firmware." }
    return $characteristics[0]
}

function Read-GattText {
    param([Parameter(Mandatory)] $Characteristic)
    $result = Wait-WinRT `
        ($Characteristic.ReadValueAsync($script:Uncached)) `
        ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattReadResult]) 20
    if ($result.Status.ToString() -ne 'Success') { throw "Đọc CMD thất bại. Status: $($result.Status)" }
    $bytes = [byte[]]$script:BufferToArray.Invoke($null, @($result.Value))
    if ($bytes.Length -eq 0) { return '' }
    return [System.Text.Encoding]::UTF8.GetString($bytes).Trim([char]0, [char]13, [char]10)
}

function Write-GattText {
    param([Parameter(Mandatory)] $Characteristic, [Parameter(Mandatory)] [string] $Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $buffer = $script:ArrayToBuffer.Invoke($null, @(, $bytes))
    $option = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteOption]::WriteWithResponse
    $result = Wait-WinRT `
        ($Characteristic.WriteValueWithResultAsync($buffer, $option)) `
        ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteResult]) 20
    if ($result.Status.ToString() -ne 'Success') { throw "Ghi CMD thất bại. Status: $($result.Status)" }
}

# Write a command, then read back the firmware's reply (CMD is auto-responded, so
# a read right after returns our own text until the firmware overwrites it).
function Invoke-GattCommand {
    param([Parameter(Mandatory)] $Characteristic, [Parameter(Mandatory)] [string] $Text)
    Write-GattText -Characteristic $Characteristic -Text $Text
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 40
        $reply = Read-GattText -Characteristic $Characteristic
        if ($reply -cne $Text) { return $reply }
    }
    throw "Firmware chưa trả lời lệnh '$Text'."
}

function Wait-GattWrite {
    param([Parameter(Mandatory)] $Task)
    if (-not $Task.Wait([TimeSpan]::FromSeconds(20))) { throw 'Ghi DATA quá thời gian chờ.' }
    if ($Task.Result.Status.ToString() -ne 'Success') { throw "Ghi DATA thất bại. Status: $($Task.Result.Status)" }
}

function Send-GattData {
    param([Parameter(Mandatory)] $Characteristic, [Parameter(Mandatory)] [byte[]] $Data,
          [Parameter(Mandatory)] [int] $ChunkSize, [int] $Window = 16)
    $option = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteOption]::WriteWithoutResponse
    $pending = New-Object System.Collections.Generic.Queue[System.Threading.Tasks.Task]
    for ($off = 0; $off -lt $Data.Length; $off += $ChunkSize) {
        $len = [Math]::Min($ChunkSize, $Data.Length - $off)
        $buffer = $script:ArraySliceToBuffer.Invoke($null, @($Data, $off, $len))
        $op = $Characteristic.WriteValueWithResultAsync($buffer, $option)
        $pending.Enqueue($script:AsTaskWriteResult.Invoke($null, @($op)))
        if ($pending.Count -ge $Window) { Wait-GattWrite $pending.Dequeue() }
    }
    while ($pending.Count -gt 0) { Wait-GattWrite $pending.Dequeue() }
}

# --- screen capture ---------------------------------------------------------

$script:MonoThreshold = 160       # black/white cut point (higher = bolder text)
$script:CanvasWMax = 1920         # firmware CANVAS_W_MAX / H_MAX
$script:CanvasHMax = 1088

# Grab the primary screen as 24bpp bytes, padded to a 16px grid. Returns the raw
# BGR bytes + stride + padded size for a packer to turn into mono or gray8.
function Get-ScreenBytes {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($bounds.Width -le 0 -or $bounds.Height -le 0) { throw 'Không xác định được kích thước màn hình chính.' }
    $w16 = [int]([Math]::Ceiling($bounds.Width / 16.0)) * 16
    $h16 = [int]([Math]::Ceiling($bounds.Height / 16.0)) * 16
    if ($w16 -gt $script:CanvasWMax -or $h16 -gt $script:CanvasHMax) {
        throw ("Màn hình {0}x{1} vượt giới hạn canvas {2}x{3} của firmware." -f `
            $bounds.Width, $bounds.Height, $script:CanvasWMax, $script:CanvasHMax)
    }
    $rect = [System.Drawing.Rectangle]::new(0, 0, $bounds.Width, $bounds.Height)
    $source = $null; $graphics = $null
    try {
        $source = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height,
            [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics = [System.Drawing.Graphics]::FromImage($source)
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size,
            [System.Drawing.CopyPixelOperation]::SourceCopy)
        $sd = $source.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
            [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $srcBytes = New-Object 'byte[]' ($sd.Stride * $bounds.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($sd.Scan0, $srcBytes, 0, $srcBytes.Length)
        $out = [pscustomobject]@{ Src = $srcBytes; Stride = $sd.Stride; W = $bounds.Width; H = $bounds.Height; W16 = $w16; H16 = $h16 }
        $source.UnlockBits($sd)
        return $out
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $source) { $source.Dispose() }
    }
}

# 1-bit mono canvas (BLE path). Fmt 0, tile row = 2 bytes, stride = W/8.
function Get-MonoCanvas {
    $s = Get-ScreenBytes
    $ds = $s.W16 / 8
    $canvas = [MomoImg]::PackMono($s.Src, $s.Stride, $s.W, $s.H, $ds, $s.H16, $script:MonoThreshold)
    return [pscustomobject]@{ Bytes = $canvas; W = $s.W16; H = $s.H16; DS = $ds; Fmt = 0; TileRow = 2 }
}

# 8-bit grayscale canvas (LAN path). Fmt 1, tile row = 16 bytes, stride = W.
function Get-GrayCanvas {
    $s = Get-ScreenBytes
    $ds = $s.W16
    $canvas = [MomoImg]::PackGray8($s.Src, $s.Stride, $s.W, $s.H, $ds, $s.H16)
    return [pscustomobject]@{ Bytes = $canvas; W = $s.W16; H = $s.H16; DS = $ds; Fmt = 1; TileRow = 16 }
}

function New-FrameHeader {
    param([Parameter(Mandatory)] [int] $Kind, [Parameter(Mandatory)] [int] $Width,
          [Parameter(Mandatory)] [int] $Height, [Parameter(Mandatory)] [int] $Seq,
          [Parameter(Mandatory)] [byte[]] $Payload)
    $h = New-Object byte[] 24
    $h[0] = [byte][char]'M'; $h[1] = [byte][char]'O'; $h[2] = [byte][char]'M'; $h[3] = [byte][char]'F'
    $h[4] = 1
    $h[5] = [byte]$Kind
    [BitConverter]::GetBytes([uint16]$Width).CopyTo($h, 6)
    [BitConverter]::GetBytes([uint16]$Height).CopyTo($h, 8)
    [BitConverter]::GetBytes([uint16]$Seq).CopyTo($h, 10)
    [BitConverter]::GetBytes([uint32]$Payload.Length).CopyTo($h, 12)
    [BitConverter]::GetBytes([MomoCrc32]::Compute($Payload)).CopyTo($h, 16)
    $first20 = New-Object byte[] 20
    [Array]::Copy($h, $first20, 20)
    [BitConverter]::GetBytes([MomoCrc32]::Compute($first20)).CopyTo($h, 20)
    return ,$h
}

function Wait-FrameResult {
    param([Parameter(Mandatory)] $CmdCharacteristic, [Parameter(Mandatory)] [int] $Seq,
          [Parameter(Mandatory)] [double] $TimeoutSeconds)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $reply = Invoke-GattCommand -Characteristic $CmdCharacteristic -Text 'FRAME'
        if ($reply -notmatch '^seq=(\d+);ok=(\d);len=(\d+);ms=(\d+);good=(\d+);bad=(\d+);busy=(\d)$') {
            throw "Firmware không hỗ trợ FRAME (trả lời: $reply)."
        }
        if ([int]$Matches[1] -eq $Seq) {
            return [pscustomobject]@{ Ok = $Matches[2] -eq '1'; Len = [int64]$Matches[3]; Ms = [int64]$Matches[4] }
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

# Capture state kept across "shot" requests, so only changed tiles are sent.
# Prev is invalid when the format changes (BLE mono vs LAN gray8).
$script:Prev = $null
$script:PrevFmt = -1
$script:Seq = Get-Random -Minimum 1 -Maximum 65536
$script:SinceKey = 0
# Device LAN endpoint, learned once from CMD "NET".
$script:NetIp = ''
$script:NetId = ''

# Raw-deflate compress (matches the device's tinfl, which reads a raw deflate
# stream). Shrinks grayscale frames ~3-5x, so the LAN upload moves far fewer bytes.
function Compress-Deflate {
    param([Parameter(Mandatory)] [byte[]] $Data)
    $ms = New-Object System.IO.MemoryStream
    $ds = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionMode]::Compress, $true)
    $ds.Write($Data, 0, $Data.Length)
    $ds.Dispose()            # finishes the deflate stream (flushes the final block)
    $out = $ms.ToArray()
    $ms.Dispose()
    return ,$out
}

# Capture once and send it. Mode 'lan' -> grayscale, deflate-compressed, POST to
# http://host/upload; Mode 'ble' -> 1-bit over the DATA characteristic. Chooses
# FULL (first/every 20th/after a failure/format change) or DELTA, or nothing when
# unchanged.
function Send-Frame {
    param(
        [Parameter(Mandatory)] [string] $Mode,   # 'lan' or 'ble'
        [string] $HostIp, [string] $Id,
        $CmdCharacteristic, $DataCharacteristic, [int] $ChunkSize
    )
    if ($Mode -eq 'lan') { $cur = Get-GrayCanvas } else { $cur = Get-MonoCanvas }
    $fmt = $cur.Fmt

    $op = 0; $payload = $null; $changed = 0
    $needFull = ($null -eq $script:Prev) -or ($script:PrevFmt -ne $fmt) -or `
                ($script:Prev.Length -ne $cur.Bytes.Length) -or ($script:SinceKey -ge 20)
    if ($needFull) {
        $op = 0; $payload = $cur.Bytes
    }
    else {
        $delta = [MomoImg]::EncodeDelta($script:Prev, $cur.Bytes, $cur.W, $cur.H, $cur.DS, $cur.TileRow, $cur.Bytes.Length)
        if ($null -eq $delta) {
            $op = 0; $payload = $cur.Bytes
        }
        else {
            $changed = [int]$delta[0] -bor ([int]$delta[1] -shl 8)
            if ($changed -eq 0) { return 'shot: màn hình không đổi' }
            $op = 1; $payload = $delta
        }
    }
    $label = if ($op -eq 0) { 'FULL' } else { "DELTA $changed ô" }
    $tag = if ($Mode -eq 'lan') { 'LAN xám' } else { 'BLE 1-bit' }
    $ok = $false; $ms = 0; $errMsg = ''; $wireLen = $payload.Length

    if ($Mode -eq 'ble' -and $null -eq $DataCharacteristic) {
        return 'shot BLE: BLE đã ngắt (agent chạy toàn WiFi). Dùng LAN.'
    }

    if ($Mode -eq 'lan') {
        if (-not $HostIp) { return 'shot LAN: chưa biết host (NET lỗi?)' }
        # Compress: payload = u32 LE uncompressed length + raw-deflate stream.
        $comp = Compress-Deflate $payload
        $cpayload = New-Object byte[] (4 + $comp.Length)
        [BitConverter]::GetBytes([uint32]$payload.Length).CopyTo($cpayload, 0)
        [Array]::Copy($comp, 0, $cpayload, 4, $comp.Length)
        $wireLen = $cpayload.Length
        $kind = 0x80 -bor ($fmt -shl 4) -bor $op   # compressed bit set
        $header = New-FrameHeader -Kind $kind -Width $cur.W -Height $cur.H -Seq $script:Seq -Payload $cpayload
        $frame = New-Object byte[] ($header.Length + $cpayload.Length)
        [Array]::Copy($header, 0, $frame, 0, $header.Length)
        [Array]::Copy($cpayload, 0, $frame, $header.Length, $cpayload.Length)
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $wc = New-Object System.Net.WebClient
            try { $null = $wc.UploadData("http://$HostIp/api/frame/upload?id=$Id", 'POST', $frame) }
            finally { $wc.Dispose() }
            $sw.Stop(); $ms = [int]$sw.Elapsed.TotalMilliseconds; $ok = $true
        } catch { $ok = $false; $errMsg = $_.Exception.Message }
    }
    else {
        $kind = ($fmt -shl 4) -bor $op            # BLE: uncompressed 1-bit
        $header = New-FrameHeader -Kind $kind -Width $cur.W -Height $cur.H -Seq $script:Seq -Payload $payload
        Send-GattData -Characteristic $DataCharacteristic -Data $header -ChunkSize $header.Length
        Send-GattData -Characteristic $DataCharacteristic -Data $payload -ChunkSize $ChunkSize
        $result = Wait-FrameResult -CmdCharacteristic $CmdCharacteristic -Seq $script:Seq -TimeoutSeconds (5 + $payload.Length / 10000)
        if ($null -ne $result -and $result.Ok) { $ok = $true; $ms = $result.Ms }
    }

    if ($ok) {
        $script:Prev = $cur.Bytes; $script:PrevFmt = $fmt
        if ($op -eq 0) { $script:SinceKey = 0 } else { $script:SinceKey++ }
        $out = if ($Mode -eq 'lan') {
            "shot: $tag $label, {0:N0}->{1:N0} byte (nén), {2} ms" -f $payload.Length, $wireLen, $ms
        } else {
            "shot: $tag $label, {0:N0} byte, {1} ms" -f $payload.Length, $ms
        }
    }
    else {
        $script:Prev = $null
        $out = "shot: $tag thất bại ($errMsg), gửi FULL lần sau"
    }
    $script:Seq = if ($script:Seq -ge 65535) { 1 } else { $script:Seq + 1 }
    return $out
}

# --- AI vision screenshot ---------------------------------------------------
# Capture the screen, downscale to a small JPEG, and upload it to the device
# (POST /api/ai/shot), which forwards it to the AI agent. Separate from Send-Frame
# (the gray8 mirror for the browser): the vision model wants a normal image.

function Get-JpegEncoder {
    [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
        Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
}

function Send-AiShot {
    param([string] $HostIp, [string] $Id, [string] $RequestId = '',
          [int] $MaxW = 1280, [int] $Quality = 60)
    if (-not $HostIp) { return 'aishot: chưa biết host (NET lỗi?)' }
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $full = $null; $small = $null; $ms = $null
    try {
        $full = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $g = [System.Drawing.Graphics]::FromImage($full)
        $g.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size,
            [System.Drawing.CopyPixelOperation]::SourceCopy)
        $g.Dispose()

        $scale = [Math]::Min(1.0, $MaxW / [double]$bounds.Width)
        $w = [int]($bounds.Width * $scale); $h = [int]($bounds.Height * $scale)
        $small = New-Object System.Drawing.Bitmap($w, $h)
        $g2 = [System.Drawing.Graphics]::FromImage($small)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.DrawImage($full, 0, 0, $w, $h); $g2.Dispose()

        $enc = Get-JpegEncoder
        $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
            [System.Drawing.Imaging.Encoder]::Quality, [int64]$Quality)
        $ms = New-Object System.IO.MemoryStream
        $small.Save($ms, $enc, $ep)
        $bytes = $ms.ToArray()

        $query = "id=$([uri]::EscapeDataString($Id))"
        if ($RequestId) { $query += "&request_id=$([uri]::EscapeDataString($RequestId))" }
        $wc = New-Object System.Net.WebClient
        try { $null = $wc.UploadData("http://$HostIp/api/ai/shot?$query", 'POST', $bytes) }
        finally { $wc.Dispose() }
        return ("aishot: {0}x{1} JPEG {2:N0} byte" -f $w, $h, $bytes.Length)
    }
    finally {
        if ($null -ne $ms)    { $ms.Dispose() }
        if ($null -ne $small) { $small.Dispose() }
        if ($null -ne $full)  { $full.Dispose() }
    }
}

# --- request execution ------------------------------------------------------

function Get-Vk {
    param([string] $Name)
    switch ($Name.ToLowerInvariant()) {
        'enter'     { 0x0D } 'tab'   { 0x09 } 'esc'    { 0x1B } 'escape' { 0x1B }
        'backspace' { 0x08 } 'delete'{ 0x2E } 'del'    { 0x2E } 'space'  { 0x20 }
        'up'        { 0x26 } 'down'  { 0x28 } 'left'   { 0x25 } 'right'  { 0x27 }
        'home'      { 0x24 } 'end'   { 0x23 } 'win'    { 0x5B }
        default     { -1 }
    }
}

# Resolve one key token (for hotkeys): a single letter/digit -> its VK, else a
# named key via Get-Vk, plus F1..F12.
function Resolve-KeyToken {
    param([string] $Tok)
    $t = $Tok.Trim()
    if ($t.Length -eq 1 -and $t -match '^[a-zA-Z0-9]$') {
        return [int][byte][char]([char]::ToUpper($t[0]))   # 'a'->0x41, '0'->0x30
    }
    if ($t -match '^[fF]([1-9]|1[0-2])$') { return 0x70 + ([int]$Matches[1] - 1) }  # F1=0x70
    return (Get-Vk $t)
}

# Press a combo like "ctrl+shift+s" / "alt+tab" / "win+r".
function Invoke-Hotkey {
    param([string] $Combo)
    $parts = $Combo.Split('+') | Where-Object { $_ -ne '' }
    if ($parts.Count -lt 1) { return "hotkey: rỗng" }
    $modMap = @{ ctrl = 0x11; control = 0x11; alt = 0x12; shift = 0x10; win = 0x5B; meta = 0x5B }
    $mods = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $m = $parts[$i].ToLowerInvariant()
        if (-not $modMap.ContainsKey($m)) { return "hotkey: modifier lạ '$($parts[$i])'" }
        $mods.Add([byte]$modMap[$m])
    }
    $vk = Resolve-KeyToken $parts[$parts.Count - 1]
    if ($vk -lt 0) { return "hotkey: không rõ phím '$($parts[$parts.Count - 1])'" }
    [MomoInput]::Combo($mods.ToArray(), [byte]$vk)
    return "hotkey $Combo"
}

# Lowercase + strip Vietnamese accents, so "Nhắn tin" matches "nhan tin".
function Remove-Diacritics {
    param([string] $s)
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $n = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $n.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
}

# Walk the UI Automation tree of the FOREGROUND window for an INTERACTIVE control
# whose name contains $Query (accent-insensitive) and return its clickable screen
# point, or $null. BFS over the control view, capped by node count + time so a big
# Chrome a11y tree can't stall the command loop. We match only interactive control
# types (so a long feed-post Group/Text can't false-match) and reject points off
# the visible screen (scrolled-away feed items report huge negative coords).
function Find-UiaElement {
    param([string] $CType = 'any', [string] $Area = 'any', [string] $Name = '')
    if (-not $script:UiaOk) { return $null }
    $q = Remove-Diacritics $Name
    # Must pin at least a name or a specific control type.
    if ($q -eq '' -and $CType -eq 'any') { return $null }
    # Map the agent's short token -> UIA ProgrammaticName. 'any' = all interactive.
    $ctMap = @{
        edit = 'ControlType.Edit'; button = 'ControlType.Button'; link = 'ControlType.Hyperlink'
        listitem = 'ControlType.ListItem'; menuitem = 'ControlType.MenuItem'; tab = 'ControlType.TabItem'
        checkbox = 'ControlType.CheckBox'; radio = 'ControlType.RadioButton'; combobox = 'ControlType.ComboBox'
    }
    if ($ctMap.ContainsKey($CType)) { $want = @($ctMap[$CType]) }
    else {
        $want = @('ControlType.Button', 'ControlType.Edit', 'ControlType.Hyperlink',
                  'ControlType.ListItem', 'ControlType.MenuItem', 'ControlType.TabItem',
                  'ControlType.CheckBox', 'ControlType.RadioButton', 'ControlType.ComboBox')
    }
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $hwnd = [MomoFg]::GetForegroundWindow()
    $root = $null
    try { if ($hwnd -ne [IntPtr]::Zero) { $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd) } } catch {}
    if ($null -eq $root) { $root = [System.Windows.Automation.AutomationElement]::RootElement }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $queue = New-Object System.Collections.Generic.Queue[System.Windows.Automation.AutomationElement]
    $queue.Enqueue($root)
    $deadline = [DateTime]::UtcNow.AddSeconds(3.5)
    $seen = 0
    while ($queue.Count -gt 0 -and $seen -lt 4000 -and [DateTime]::UtcNow -lt $deadline) {
        $el = $queue.Dequeue(); $seen++
        $name = ''; $ctype = ''
        try { $name = $el.Current.Name } catch {}
        try { $ctype = $el.Current.ControlType.ProgrammaticName } catch {}
        if ($name -and ($want -contains $ctype) -and ($q -eq '' -or (Remove-Diacritics $name).Contains($q))) {
            $x = -1; $y = -1
            try { $p = $el.GetClickablePoint(); $x = [int]$p.X; $y = [int]$p.Y }
            catch {
                try {
                    $r = $el.Current.BoundingRectangle
                    if ($r.Width -gt 0 -and $r.Height -gt 0) { $x = [int]($r.X + $r.Width / 2); $y = [int]($r.Y + $r.Height / 2) }
                } catch {}
            }
            # Accept only a point inside the visible screen AND in the wanted area
            # (so a name-less control-type query lands in the right region, e.g.
            # the chat Edit on the right, not the address bar up top).
            $onScreen = ($x -ge $vs.Left -and $x -lt ($vs.Left + $vs.Width) -and
                         $y -ge $vs.Top -and $y -lt ($vs.Top + $vs.Height))
            $okArea = $true
            if ($Area -ne 'any' -and $onScreen) {
                $W = $vs.Width; $H = $vs.Height
                switch ($Area) {
                    'left'   { $okArea = $x -lt $W * 0.45 }
                    'right'  { $okArea = $x -gt $W * 0.55 }
                    'top'    { $okArea = $y -lt $H * 0.45 }
                    'bottom' { $okArea = $y -gt $H * 0.55 }
                    'center' { $okArea = ($x -gt $W * 0.25 -and $x -lt $W * 0.75 -and $y -gt $H * 0.25 -and $y -lt $H * 0.75) }
                }
            }
            if ($onScreen -and $okArea) {
                return [pscustomobject]@{ X = $x; Y = $y; Name = $name; Type = $ctype }
            }
        }
        try {
            $child = $walker.GetFirstChild($el)
            while ($null -ne $child) { $queue.Enqueue($child); $child = $walker.GetNextSibling($child) }
        } catch {}
    }
    return $null
}

# Collect interactive UIA controls (Button/Edit/Link/ListItem/...) in the given
# area of the foreground window. Returns an array of {Cx,Cy,X0,Y0,X1,Y1,Name,Type}
# in FULL-resolution screen pixels (deduped, capped). Empty array on any failure.
function Get-UiaInteractive {
    param([string] $Area = 'any', [int] $Max = 40)
    $out = @()
    if (-not $script:UiaOk) { return $out }
    $want = @('ControlType.Button', 'ControlType.Edit', 'ControlType.Hyperlink',
              'ControlType.ListItem', 'ControlType.MenuItem', 'ControlType.TabItem',
              'ControlType.CheckBox', 'ControlType.RadioButton', 'ControlType.ComboBox')
    $vs = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $hwnd = [MomoFg]::GetForegroundWindow()
    $root = $null
    try { if ($hwnd -ne [IntPtr]::Zero) { $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd) } } catch {}
    if ($null -eq $root) { $root = [System.Windows.Automation.AutomationElement]::RootElement }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $queue = New-Object System.Collections.Generic.Queue[System.Windows.Automation.AutomationElement]
    $queue.Enqueue($root)
    $deadline = [DateTime]::UtcNow.AddSeconds(3.5)
    $seen = 0
    while ($queue.Count -gt 0 -and $seen -lt 6000 -and $out.Count -lt $Max -and [DateTime]::UtcNow -lt $deadline) {
        $el = $queue.Dequeue(); $seen++
        $name = ''; $ctype = ''
        try { $name = $el.Current.Name } catch {}
        try { $ctype = $el.Current.ControlType.ProgrammaticName } catch {}
        if ($name -and ($want -contains $ctype)) {
            $r = $null
            try { $r = $el.Current.BoundingRectangle } catch {}
            if ($null -ne $r -and $r.Width -gt 2 -and $r.Height -gt 2) {
                $cx = [int]($r.X + $r.Width / 2); $cy = [int]($r.Y + $r.Height / 2)
                try { $p = $el.GetClickablePoint(); $cx = [int]$p.X; $cy = [int]$p.Y } catch {}
                if ($cx -ge $vs.Left -and $cx -lt ($vs.Left + $vs.Width) -and
                    $cy -ge $vs.Top -and $cy -lt ($vs.Top + $vs.Height)) {
                    $ok = $true
                    switch ($Area) {
                        'left'   { $ok = $cx -lt $vs.Width * 0.45 }
                        'right'  { $ok = $cx -gt $vs.Width * 0.55 }
                        'top'    { $ok = $cy -lt $vs.Height * 0.45 }
                        'bottom' { $ok = $cy -gt $vs.Height * 0.55 }
                        'center' { $ok = ($cx -gt $vs.Width * 0.25 -and $cx -lt $vs.Width * 0.75 -and $cy -gt $vs.Height * 0.25 -and $cy -lt $vs.Height * 0.75) }
                    }
                    if ($ok) {
                        $dup = $false
                        foreach ($o in $out) { if ([Math]::Abs($o.Cx - $cx) -lt 6 -and [Math]::Abs($o.Cy - $cy) -lt 6) { $dup = $true; break } }
                        if (-not $dup) {
                            $out += [pscustomobject]@{ Cx = $cx; Cy = $cy
                                X0 = [int]$r.X; Y0 = [int]$r.Y; X1 = [int]($r.X + $r.Width); Y1 = [int]($r.Y + $r.Height)
                                Name = $name; Type = ($ctype -replace '^ControlType\.', '') }
                        }
                    }
                }
            }
        }
        try {
            $child = $walker.GetFirstChild($el)
            while ($null -ne $child) { $queue.Enqueue($child); $child = $walker.GetNextSibling($child) }
        } catch {}
    }
    return $out
}

# Capture the screen, draw numbered boxes on the interactive controls, upload the
# annotated JPEG (aishot path) for the agent's LLM to pick from, and KEEP the
# number->coords map here. Returns "ok <count>" (or "none").
function Send-UiaMark {
    param([string] $HostIp, [string] $Id, [string] $Area = 'any',
          [string] $RequestId = '', [int] $MaxW = 1280, [int] $Quality = 65)
    if (-not $HostIp) { return 'none' }
    $comps = Get-UiaInteractive -Area $Area
    $script:UiaMap = $comps
    if ($comps.Count -eq 0) { return 'ok 0' }
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $full = $null; $small = $null; $ms = $null
    try {
        $full = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $g = [System.Drawing.Graphics]::FromImage($full)
        $g.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
        $g.Dispose()
        $scale = [Math]::Min(1.0, $MaxW / [double]$bounds.Width)
        $w = [int]($bounds.Width * $scale); $h = [int]($bounds.Height * $scale)
        $small = New-Object System.Drawing.Bitmap($w, $h)
        $g2 = [System.Drawing.Graphics]::FromImage($small)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.DrawImage($full, 0, 0, $w, $h)
        # Draw numbered boxes (scaled to the small image).
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Red), 2
        $font = New-Object System.Drawing.Font 'Arial', 11, ([System.Drawing.FontStyle]::Bold)
        $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Red)
        $fg = [System.Drawing.Brushes]::White
        for ($i = 0; $i -lt $comps.Count; $i++) {
            $c = $comps[$i]; $n = $i + 1
            $x0 = [int]($c.X0 * $scale); $y0 = [int]($c.Y0 * $scale)
            $bw = [int](($c.X1 - $c.X0) * $scale); $bh = [int](($c.Y1 - $c.Y0) * $scale)
            if ($bw -lt 1) { $bw = 1 }; if ($bh -lt 1) { $bh = 1 }
            $g2.DrawRectangle($pen, $x0, $y0, $bw, $bh)
            $tag = "$n"; $tw = 10 * $tag.Length + 6
            $g2.FillRectangle($bg, $x0, $y0, $tw, 16)
            $g2.DrawString($tag, $font, $fg, $x0 + 1, $y0)
        }
        $g2.Dispose(); $pen.Dispose(); $font.Dispose(); $bg.Dispose()
        $enc = Get-JpegEncoder
        $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [int64]$Quality)
        $ms = New-Object System.IO.MemoryStream
        $small.Save($ms, $enc, $ep)
        $bytes = $ms.ToArray()
        $query = "id=$([uri]::EscapeDataString($Id))"
        if ($RequestId) { $query += "&request_id=$([uri]::EscapeDataString($RequestId))" }
        $wc = New-Object System.Net.WebClient
        try { $null = $wc.UploadData("http://$HostIp/api/ai/shot?$query", 'POST', $bytes) } finally { $wc.Dispose() }
        return ("ok {0}" -f $comps.Count)
    } catch {
        return "none"
    } finally {
        if ($ms) { $ms.Dispose() }; if ($small) { $small.Dispose() }; if ($full) { $full.Dispose() }
    }
}

# Parse and carry out one request line; returns a status string (or $null if idle).
function Invoke-Request {
    param([Parameter(Mandatory)] [string] $Req, $CmdCharacteristic = $null,
          $DataCharacteristic = $null, [int] $ChunkSize = 0)
    $t = $Req.Trim()
    if ($t -eq '' -or $t -eq 'none') { return $null }
    $sp = $t.IndexOf(' ')
    $verb = if ($sp -lt 0) { $t } else { $t.Substring(0, $sp) }
    $rest = if ($sp -lt 0) { '' } else { $t.Substring($sp + 1).Trim() }

    switch ($verb.ToLowerInvariant()) {
        'move' {
            $a = $rest -split '\s+'
            if ($a.Count -lt 2) { return "move: thiếu toạ độ" }
            [MomoInput]::MoveTo([int]$a[0], [int]$a[1]); return "move $($a[0]),$($a[1])"
        }
        'click' {
            $a = $rest -split '\s+'
            if ($a.Count -ge 3)      { [MomoInput]::Click([int]$a[0], [int]$a[1], [int]$a[2]); return "click $($a[0]),$($a[1]) nút $($a[2])" }
            $p = [MomoInput]::Get()
            $btn = if ($a.Count -ge 1 -and $a[0] -ne '') { [int]$a[0] } else { 1 }
            [MomoInput]::Click($p.X, $p.Y, $btn); return "click tại chỗ nút $btn"
        }
        'scroll' {
            if ($rest -eq '') { return "scroll: thiếu giá trị" }
            [MomoInput]::Scroll([int]$rest); return "scroll $rest"
        }
        'key' {
            $vk = Get-Vk $rest
            if ($vk -lt 0) { return "key: không rõ '$rest'" }
            [MomoInput]::Key([byte]$vk); return "key $rest"
        }
        'type' {
            if ($rest -eq '') { return "type: rỗng" }
            Set-Clipboard -Value $rest
            Start-Sleep -Milliseconds 30
            [MomoInput]::Paste()
            return "type ($($rest.Length) ký tự)"
        }
        'shot' {
            # "shot [ble] [host=<ip>] [id=<id>] [thr=<n>]". Default = LAN (uses the
            # host/id in the command, or the cached NET values).
            $mode = 'lan'; $hostIp = $script:NetIp; $id = $script:NetId
            foreach ($tok in ($rest -split '\s+')) {
                if ($tok -eq 'ble') { $mode = 'ble' }
                elseif ($tok -match '^host=(.+)$') { $hostIp = $Matches[1] }
                elseif ($tok -match '^id=(.+)$')   { $id = $Matches[1] }
                elseif ($tok -match '^thr=(\d+)$' -or $tok -match '^(\d+)$') {
                    $script:MonoThreshold = [Math]::Max(0, [Math]::Min(255, [int]$Matches[1]))
                }
            }
            return (Send-Frame -Mode $mode -HostIp $hostIp -Id $id `
                -CmdCharacteristic $CmdCharacteristic -DataCharacteristic $DataCharacteristic -ChunkSize $ChunkSize)
        }
        'hotkey' {
            if ($rest -eq '') { return "hotkey: thiếu tổ hợp" }
            return (Invoke-Hotkey $rest)
        }
        'aishot' {
            # Screenshot for the AI agent: small JPEG uploaded to the device.
            $requestId = ''
            foreach ($tok in ($rest -split '\s+')) {
                if ($tok -match '^req=(.+)$') { $requestId = $Matches[1] }
            }
            return (Send-AiShot -HostIp $script:NetIp -Id $script:NetId -RequestId $requestId)
        }
        'uia' {
            # "uia <ctype> <area> <name...>" -> reply "x,y" (real screen coords) or
            # "none". If the first two tokens aren't a known ctype+area (legacy /
            # free-form), treat the whole rest as the Name with ctype/area = any.
            if ($rest -eq '') { return 'none' }
            $validC = @('any', 'edit', 'button', 'link', 'listitem', 'menuitem', 'tab', 'checkbox', 'radio', 'combobox')
            $validA = @('any', 'left', 'right', 'top', 'bottom', 'center')
            $ct = 'any'; $ar = 'any'; $nm = $rest
            $toks = $rest -split '\s+', 3
            if ($toks.Count -ge 2 -and ($validC -contains $toks[0].ToLowerInvariant()) -and ($validA -contains $toks[1].ToLowerInvariant())) {
                $ct = $toks[0].ToLowerInvariant(); $ar = $toks[1].ToLowerInvariant()
                $nm = if ($toks.Count -ge 3) { $toks[2] } else { '' }
            }
            $hit = $null
            try { $hit = Find-UiaElement -CType $ct -Area $ar -Name $nm } catch { $hit = $null }
            if ($null -ne $hit) { return "$($hit.X),$($hit.Y)|$($hit.Name)" }
            return 'none'
        }
        'uiamark' {
            # "uiamark <area>" -> mark interactive controls on a screenshot, upload,
            # keep the map; reply "ok <count>".
            $ar = 'any'; $requestId = ''
            foreach ($tok in ($rest -split '\s+')) {
                if ($tok -match '^req=(.+)$') { $requestId = $Matches[1] }
                elseif ($tok -in @('left', 'right', 'top', 'bottom', 'center')) { $ar = $tok }
            }
            return (Send-UiaMark -HostIp $script:NetIp -Id $script:NetId -Area $ar -RequestId $requestId)
        }
        'uiapt' {
            # "uiapt <n>" -> real screen coords of marked control #n, or "none".
            if ($rest -notmatch '^\d+$') { return 'none' }
            $n = [int]$rest
            if ($null -eq $script:UiaMap -or $n -lt 1 -or $n -gt $script:UiaMap.Count) { return 'none' }
            $c = $script:UiaMap[$n - 1]
            return "$($c.Cx),$($c.Cy)"
        }
        default { return "lệnh lạ: $verb" }
    }
}

# Tiny HTTP helpers over WiFi (keep-alive reused via ServicePointManager).
function Invoke-HttpGet {
    param([Parameter(Mandatory)] [string] $Url)
    $wc = New-Object System.Net.WebClient
    # The ESP serves UTF-8; WebClient defaults to the system ANSI codepage on
    # PowerShell 5.1, which mangles Vietnamese in a `type` command (Trả -> Tráº£).
    $wc.Encoding = [System.Text.Encoding]::UTF8
    try { return $wc.DownloadString($Url) } finally { $wc.Dispose() }
}
function Invoke-HttpPost {
    param([Parameter(Mandatory)] [string] $Url, [Parameter(Mandatory)] [string] $Body)
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=utf-8'
    try { $null = $wc.UploadString($Url, 'POST', $Body) } finally { $wc.Dispose() }
}

# The one loop. Commands and cursor reports now go over WiFi (fast, low latency,
# independent of the BLE connection interval); BLE stays connected only for the
# occasional "shot ble" fallback. Images already go over WiFi.
function Invoke-AgentLoop {
    param($CmdCharacteristic = $null, $DataCharacteristic = $null, [int] $ChunkSize = 0)
    if (-not $script:NetIp -or $script:NetIp -eq '0.0.0.0') {
        throw 'Chưa có IP thiết bị (NET). Không thể dùng lệnh qua WiFi.'
    }
    $base = "http://$($script:NetIp)"
    Write-Host "Agent đang chạy: lệnh + ảnh qua WiFi ($base). Nhấn phím bất kỳ để dừng." -ForegroundColor Cyan
    $mposWatch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ([Console]::KeyAvailable) {
            $null = [Console]::ReadKey($true)
            Write-Host 'Đã dừng agent.' -ForegroundColor DarkGray
            return
        }
        # Report cursor + screen size ~3x/second (WiFi).
        if ($mposWatch.Elapsed.TotalMilliseconds -ge 300) {
            try {
                $c = [MomoInput]::Get()
                $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                Invoke-HttpPost "$base/api/mpos" ("x={0}&y={1}&w={2}&h={3}" -f $c.X, $c.Y, $b.Width, $b.Height)
            } catch {}
            $mposWatch.Restart()
        }
        $req = ''
        try { $req = (Invoke-HttpGet "$base/api/req").Trim() }
        catch { Start-Sleep -Milliseconds 300; continue }
        if ($req -eq '' -or $req -eq 'none') { Start-Sleep -Milliseconds 50; continue }

        # A tracked command is "#<id> <cmd>"; run <cmd>, then report the outcome.
        $cmdId = $null; $cmd = $req
        if ($req -match '^#(\d+)\s+(.*)$') { $cmdId = $Matches[1]; $cmd = $Matches[2] }

        $stamp = Get-Date -Format 'HH:mm:ss'
        $rok = $true; $rmsg = 'ok'
        try {
            $info = Invoke-Request -Req $cmd -CmdCharacteristic $CmdCharacteristic `
                -DataCharacteristic $DataCharacteristic -ChunkSize $ChunkSize
            if ($null -ne $info) { $rmsg = "$info"; Write-Host ("[{0}] {1}" -f $stamp, $info) -ForegroundColor Green }
        }
        catch {
            $rok = $false; $rmsg = $_.Exception.Message
            Write-Host ("[{0}] lỗi xử lý '{1}': {2}" -f $stamp, $cmd, $rmsg) -ForegroundColor Red
        }
        if ($null -ne $cmdId) {
            $short = if ($rmsg.Length -gt 40) { $rmsg.Substring(0, 40) } else { $rmsg }
            try {
                Invoke-HttpPost "$base/api/result" ("id={0}&ok={1}&msg={2}" -f $cmdId, ([int]$rok), [uri]::EscapeDataString($short))
            } catch {}
        }
        # Loop straight back to drain any further queued commands.
    }
}

# --- connect + run ----------------------------------------------------------

$bleDevice = $null
$session = $null
$service = $null

try {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor DarkCyan
    Write-Host '           MOMO BLE AGENT' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor DarkCyan

    Write-Host 'Đang lấy danh sách thiết bị BLE đã pair...' -ForegroundColor Cyan
    $candidates = @(Get-BleDeviceList | Where-Object { $_.Name -and $_.Name -match 'MOMO' })
    if ($candidates.Count -eq 0) {
        throw 'Không tìm thấy thiết bị tên MOMO đã pair. Hãy pair "Momo HID" trong Settings > Bluetooth.'
    }
    $chosen = $candidates[0]
    Write-Host "Thiết bị: $($chosen.Name)" -ForegroundColor Green

    Write-Host 'Đang kết nối BLE...' -ForegroundColor Cyan
    $bleDevice = Wait-WinRT `
        ([Windows.Devices.Bluetooth.BluetoothLEDevice]::FromIdAsync($chosen.Id)) `
        ([Windows.Devices.Bluetooth.BluetoothLEDevice]) 30
    if ($null -eq $bleDevice) { throw 'Windows không tạo được kết nối BLE.' }

    $session = Wait-WinRT `
        ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattSession]::FromDeviceIdAsync($bleDevice.BluetoothDeviceId)) `
        ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattSession]) 30
    $session.MaintainConnection = $true

    $service = Get-GattService -BleDevice $bleDevice -Uuid $script:ServiceUuid
    $cmdChar = Get-GattCharacteristic -Service $service -Uuid $script:CmdUuid -Label 'CMD'
    Write-Host ("ATT MTU: {0}" -f $session.MaxPduSize) -ForegroundColor DarkGray

    # Learn the device's LAN endpoint (IP + id) for frame upload - the only thing
    # BLE is used for now.
    try {
        $net = Invoke-GattCommand -Characteristic $cmdChar -Text 'NET'
        if ($net -match 'ip=([0-9.]+)') { $script:NetIp = $Matches[1] }
        if ($net -match 'id=([^;]+)')   { $script:NetId = $Matches[1] }
    } catch {
        Write-Host 'Firmware chưa hỗ trợ lệnh NET; cần IP thiết bị. Hãy flash firmware mới.' -ForegroundColor Yellow
    }
    if (-not $script:NetIp -or $script:NetIp -eq '0.0.0.0') {
        throw 'Chưa lấy được IP thiết bị (NET). Thiết bị đã lên WiFi chưa?'
    }

    # Disconnect BLE: while BLE stays connected, WiFi throughput is throttled hard
    # (BLE + WiFi share the 2.4 GHz radio). Everything runs over WiFi from here.
    Write-Host "Đã lấy IP $($script:NetIp). Ngắt BLE để nhường toàn bộ sóng cho WiFi..." -ForegroundColor Cyan
    try {
        if ($service) { $service.Dispose() }
        if ($session) { $session.MaintainConnection = $false; $session.Dispose() }
        if ($bleDevice) { $bleDevice.Dispose() }
    } catch {}
    $service = $null; $session = $null; $bleDevice = $null
    [System.GC]::Collect()
    Start-Sleep -Milliseconds 800  # give Windows a moment to drop the link

    Invoke-AgentLoop
}
catch {
    Write-Host ''
    Write-Host ("LỖI: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Kiểm tra Bluetooth, pairing, UUID firmware và quyền Bluetooth của Windows.' -ForegroundColor Yellow
}
finally {
    if ($null -ne $service) { try { $service.Dispose() } catch {} }
    if ($null -ne $session) { try { $session.Dispose() } catch {} }
    if ($null -ne $bleDevice) { try { $bleDevice.Dispose() } catch {} }
    Write-Host 'Đã kết thúc MOMO BLE Agent.' -ForegroundColor DarkGray
}
