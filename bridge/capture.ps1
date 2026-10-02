# Screen-captures the top-left corner of the WoW client window and decodes the
# WoWAI pixel strip (see Codec.lua in the addon). Prints one JSON line per
# new message to stdout. Started by bridge.js; can also be run by hand.
#
#   capture.ps1 -TestImage strip.png    decode a PNG once and exit (used by tests)
#   capture.ps1 -Shot out.png           save the whole game window once and exit (the strip
#                                       blanked out; -ShotMaxWidth scales it down)

param(
  [int]$Cell = 4,
  [int]$Cells = 200,
  [int]$MaxRows = 48,
  [int]$IntervalMs = 250,
  [string]$ProcessName = "WowB",
  [string]$TestImage = "",
  [string]$Shot = "",
  [int]$ShotMaxWidth = 1920
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class CapWin {
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@
[void][CapWin]::SetProcessDPIAware()

function Emit($obj) {
  [Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject $obj))
  [Console]::Out.Flush()
}

# Each channel is either fully on or off, so anything past mid-grey counts as on.
function CellValue($bmp, [int]$c, [int]$r) {
  $px = $bmp.GetPixel($c * $Cell + [int]($Cell / 2), $r * $Cell + [int]($Cell / 2))
  $v = 0
  if ($px.R -ge 128) { $v += 4 }
  if ($px.G -ge 128) { $v += 2 }
  if ($px.B -ge 128) { $v += 1 }
  return $v
}

function Decode($bmp) {
  $acc = 0; $nbits = 0
  $bytes = New-Object System.Collections.Generic.List[int]
  $needed = 6
  $total = $Cells * $MaxRows
  for ($i = 0; $i -lt $total; $i++) {
    $c = $i % $Cells
    $r = [int][Math]::Floor($i / $Cells)
    $v = CellValue $bmp $c $r
    $acc = ($acc -shl 3) -bor $v
    $nbits += 3
    while ($nbits -ge 8) {
      $b = ($acc -shr ($nbits - 8)) -band 0xFF
      $bytes.Add($b)
      $nbits -= 8
      $acc = $acc -band ((1 -shl $nbits) - 1)
      if ($bytes.Count -eq 2) {
        if ($bytes[0] -ne 0xC7 -or $bytes[1] -ne 0x1A) { return $null }
      }
      if ($bytes.Count -eq 6) {
        $len = ($bytes[4] * 256) + $bytes[5]
        $needed = 8 + $len
        if ($needed -gt [int]($total * 3 / 8)) { return @{ error = "length" } }
      }
      if ($bytes.Count -ge $needed) { break }
    }
    if ($bytes.Count -ge $needed) { break }
  }
  if ($bytes.Count -lt $needed) { return @{ error = "truncated" } }
  $len = ($bytes[4] * 256) + $bytes[5]
  $s1 = 0; $s2 = 0
  for ($k = 2; $k -lt (6 + $len); $k++) {
    $s1 = ($s1 + $bytes[$k]) % 255
    $s2 = ($s2 + $s1) % 255
  }
  if ($bytes[6 + $len] -ne $s1 -or $bytes[7 + $len] -ne $s2) { return @{ error = "checksum" } }
  $payload = New-Object byte[] $len
  for ($k = 0; $k -lt $len; $k++) { $payload[$k] = [byte]$bytes[6 + $k] }
  return @{ id = (($bytes[2] * 256) + $bytes[3]); text = [Text.Encoding]::UTF8.GetString($payload) }
}

if ($TestImage -ne "") {
  $bmp = [System.Drawing.Bitmap]::FromFile($TestImage)
  $msg = Decode $bmp
  $bmp.Dispose()
  if ($msg) { Emit $msg } else { Emit @{ error = "no valid strip in image" } }
  exit 0
}

if ($Shot) {
  $p = Get-Process $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { Emit @{ error = "no game window found" }; exit 1 }
  $hwnd = $p.MainWindowHandle
  if ([CapWin]::IsIconic($hwnd)) { Emit @{ error = "the game window is minimized" }; exit 1 }
  $rc = New-Object CapWin+RECT
  [void][CapWin]::GetClientRect($hwnd, [ref]$rc)
  $pt = New-Object CapWin+POINT
  [void][CapWin]::ClientToScreen($hwnd, [ref]$pt)
  $cw = $rc.Right - $rc.Left; $ch = $rc.Bottom - $rc.Top
  if ($cw -le 0 -or $ch -le 0) { Emit @{ error = "empty game window" }; exit 1 }
  $bmp = New-Object System.Drawing.Bitmap $cw, $ch
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try { $g.CopyFromScreen($pt.X, $pt.Y, 0, 0, $bmp.Size) } catch { Emit @{ error = "capture failed: $_" }; exit 1 }
  # The strip is there while a message waits for its ack: black it out.
  $masked = $false
  $m = Decode $bmp
  if ($m) {
    $g.FillRectangle([System.Drawing.Brushes]::Black, 0, 0, [Math]::Min($cw, $Cells * $Cell + 8), [Math]::Min($ch, $MaxRows * $Cell + 8))
    $masked = $true
  }
  $g.Dispose()
  if ($ShotMaxWidth -gt 0 -and $cw -gt $ShotMaxWidth) {
    $nh = [int]($ch * $ShotMaxWidth / $cw)
    $small = New-Object System.Drawing.Bitmap $bmp, $ShotMaxWidth, $nh
    $bmp.Dispose(); $bmp = $small
  }
  $bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
  Emit @{ info = "shot $($bmp.Width)x$($bmp.Height)"; path = $Shot; masked = $masked }
  $bmp.Dispose()
  exit 0
}

$lastId = -1
$lastWarn = [DateTime]::MinValue
$proc = $null
$w = $Cells * $Cell
$h = $MaxRows * $Cell
while ($true) {
  if (-not $proc -or $proc.HasExited) {
    $proc = Get-Process $ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $proc) {
      Emit @{ info = "waiting for $ProcessName window" }
      Start-Sleep -Seconds 3
      continue
    }
    Emit @{ info = "attached to '$($proc.MainWindowTitle)' (pid $($proc.Id))" }
  }
  $hwnd = $proc.MainWindowHandle
  if ([CapWin]::IsIconic($hwnd)) { Start-Sleep -Milliseconds 1000; continue }
  $pt = New-Object CapWin+POINT
  [void][CapWin]::ClientToScreen($hwnd, [ref]$pt)
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $ok = $true
  try { $g.CopyFromScreen($pt.X, $pt.Y, 0, 0, $bmp.Size) } catch { $ok = $false }
  $g.Dispose()
  if ($ok) {
    $msg = Decode $bmp
    if ($msg -and $msg.error) {
      # Magic matched but the frame didn't validate: say so, at most every 5 s.
      if (([DateTime]::Now - $lastWarn).TotalSeconds -ge 5) {
        $lastWarn = [DateTime]::Now
        Emit @{ warn = "strip seen but rejected: $($msg.error)" }
      }
    } elseif ($msg) {
      $key = "$($msg.id):$($msg.text)"
      if ($key -ne $lastId) {
        $lastId = $key
        Emit $msg
      }
    }
  }
  $bmp.Dispose()
  Start-Sleep -Milliseconds $IntervalMs
}
