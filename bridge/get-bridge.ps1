# Downloads the latest k8s-bridge release for Windows, checks its SHA256
# against the release's SHA256SUMS.txt and runs it. Extra args go to the bridge:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/jairoFernandez/kubiverse/main/bridge/get-bridge.ps1))) --allow-origin https://jairofernandez.github.io
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = 'jairoFernandez/kubiverse'
$name = 'k8s-bridge-windows-amd64.exe'
$base = "https://github.com/$repo/releases/latest/download"
$dir = Join-Path $HOME '.kubecraft\bin'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$exe = Join-Path $dir 'k8s-bridge.exe'
$tmp = "$exe.tmp"

Write-Host "Downloading $name (latest release of $repo)..."
Invoke-WebRequest "$base/$name" -OutFile $tmp -UseBasicParsing
$sums = (Invoke-WebRequest "$base/SHA256SUMS.txt" -UseBasicParsing).Content
if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }

$want = ''
foreach ($line in ($sums -split "`n")) {
  $f = $line.Trim() -split '\s+'
  if ($f.Count -eq 2 -and $f[1] -eq $name) { $want = $f[0].ToLower() }
}
$got = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
if (-not $want -or $want -ne $got) {
  Remove-Item $tmp
  throw "checksum mismatch for ${name}: not running it"
}
Move-Item -Force $tmp $exe
Write-Host "Checksum OK. Starting $exe (Ctrl+C stops it)."
& $exe @args
