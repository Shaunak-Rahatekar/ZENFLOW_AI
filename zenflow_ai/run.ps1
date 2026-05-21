# run.ps1 — ZenFlow AI launcher
# Usage:
#   .\run.ps1                          # debug on first android device/emulator
#   .\run.ps1 -Mode profile
#   .\run.ps1 -Platform windows        # run on Windows desktop
#   .\run.ps1 -Device "emulator-5554"  # specific device

param(
  [string]$Mode     = "debug",
  [string]$Platform = "android",   # android | windows
  [string]$Device   = ""
)

# ── 1. Read .env ─────────────────────────────────────────────
$envFile = Join-Path $PSScriptRoot ".env"
$envVars = @{}
if (Test-Path $envFile) {
  Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+)=(.+)$') {
      $envVars[$matches[1].Trim()] = $matches[2].Trim()
    }
  }
} else {
  Write-Warning ".env file not found at $envFile"
}

$supabaseUrl = $envVars["SUPABASE_URL"]
$supabaseKey = $envVars["SUPABASE_ANON_KEY"]
$geminiKey   = $envVars["GEMINI_API_KEY"]

if (-not $supabaseUrl) {
  Write-Error "SUPABASE_URL is empty. Check your .env file."
  exit 1
}

# ── 2. If targeting android, boot emulator if nothing is connected ────
if ($Platform -eq "android" -and $Device -eq "") {
  $devices = flutter devices 2>&1 | Select-String "android"
  if (-not $devices) {
    Write-Host "⚡ No Android device found. Launching emulator 'Small_Phone'..." -ForegroundColor Yellow
    Start-Process "flutter" -ArgumentList "emulators --launch Small_Phone" -NoNewWindow
    Write-Host "   Waiting 20 s for emulator to boot..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 20
  }
}

# ── 3. Build arg list ─────────────────────────────────────────
$dartDefines = @(
  "--dart-define=SUPABASE_URL=$supabaseUrl",
  "--dart-define=SUPABASE_ANON_KEY=$supabaseKey",
  "--dart-define=GEMINI_API_KEY=$geminiKey"
)

$flutterArgs = @("run", "--$Mode") + $dartDefines

if ($Device -ne "") {
  $flutterArgs += @("-d", $Device)
} elseif ($Platform -eq "windows") {
  $flutterArgs += @("-d", "windows")
} else {
  $flutterArgs += @("-d", "android")
}

Write-Host ""
Write-Host "🚀 ZenFlow AI  [$Mode | $Platform]" -ForegroundColor Cyan
Write-Host "   URL : $supabaseUrl" -ForegroundColor DarkGray
Write-Host ""
flutter @flutterArgs
