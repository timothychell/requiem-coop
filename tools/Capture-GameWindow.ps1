param([string]$OutputPath = (Join-Path $PSScriptRoot 'model-after.png'))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('CoopWindowCapture' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class CoopWindowCapture {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd,out RECT rect);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd,IntPtr hdc,uint flags);
}
'@
}
$window=(Get-Process re9).MainWindowHandle
$rect=New-Object CoopWindowCapture+RECT
if (-not [CoopWindowCapture]::GetWindowRect($window,[ref]$rect)) { throw 'Game window unavailable' }
$bitmap=New-Object Drawing.Bitmap ($rect.Right-$rect.Left),($rect.Bottom-$rect.Top)
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$dc=$graphics.GetHdc()
try { $captured=[CoopWindowCapture]::PrintWindow($window,$dc,2) } finally { $graphics.ReleaseHdc($dc) }
try {
    if (-not $captured) { throw 'Game window capture failed' }
    $bitmap.Save($OutputPath,[Drawing.Imaging.ImageFormat]::Png)
} finally { $graphics.Dispose(); $bitmap.Dispose() }
Write-Output $OutputPath
