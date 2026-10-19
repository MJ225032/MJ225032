#Requires -Version 5.1
<#
.SYNOPSIS
  barbosaihan/civil3d-mcp 원클릭 설치 (Windows + Civil 3D 2025 이상)

.DESCRIPTION
  1. 선행 조건 확인/설치 (git, Node 18+, .NET 8 SDK — 없으면 winget)
  2. Civil 3D 설치 경로 자동 탐지 (2025+ / .NET 8 기반만 지원)
  3. 검증된 커밋으로 clone (core.autocrlf=false → 스킬 파서 CRLF 버그 회피)
  4. MCP 서버(Node) 빌드, 플러그인(C#) 빌드
  5. Autoload 번들로 배포 → Civil 3D 시작 시 자동 로드 (매번 NETLOAD 불필요)
  6. Claude Code / Claude Desktop 에 MCP 서버 등록

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Port 18080
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Verify      # Civil 3D 켜고 도면 연 상태에서
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
  [string]$InstallDir = (Join-Path $env:USERPROFILE 'civil3d-mcp'),
  [string]$Civil3DPath,                                         # 예: 'C:\Program Files\Autodesk\AutoCAD 2025'
  [string]$Ref = '344ad15ff517a19232fdf4eda2685292bdf723cf',    # 검토한 커밋. 최신을 원하면 -Ref main
  [ValidateRange(1024, 65535)][int]$Port = 8080,
  [switch]$SkipClaudeCode,
  [switch]$SkipClaudeDesktop,
  [switch]$Verify,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$RepoUrl    = 'https://github.com/barbosaihan/civil3d-mcp.git'
$ServerName = 'civil3d'
$BundleDir  = Join-Path $env:APPDATA 'Autodesk\ApplicationPlugins\Civil3dMcp.bundle'
$RefDlls    = 'accoremgd.dll', 'AcDbMgd.dll', 'acmgd.dll', 'AecBaseMgd.dll', 'AeccDbMgd.dll'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    [!]  $msg" -ForegroundColor Yellow }

# 네이티브 명령은 $ErrorActionPreference 로 안 잡히므로 exit code 를 직접 검사
function Exec([scriptblock]$Block, [string]$What) {
  & $Block
  if ($LASTEXITCODE -ne 0) { throw "$What 실패 (exit $LASTEXITCODE)" }
}

# 실패해도 되는 네이티브 명령 (PS 5.1 은 stderr 리다이렉트 시 EAP=Stop 이면 예외를 던짐)
function TryExec([scriptblock]$Block) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & $Block 2>&1 | Out-Null } catch { } finally { $ErrorActionPreference = $prev }
}

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Ensure-Tool([string]$Cmd, [string]$WingetId, [scriptblock]$IsOk) {
  $found = Get-Command $Cmd -ErrorAction SilentlyContinue
  if ($found -and (& $IsOk)) { Ok "$Cmd 확인"; return }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "$Cmd 이(가) 없거나 버전이 낮습니다. 수동 설치 후 다시 실행하세요 (winget id: $WingetId)."
  }
  Warn "$Cmd 설치/업그레이드 중 (winget $WingetId)"
  Exec { winget install --id $WingetId -e --silent --accept-source-agreements --accept-package-agreements } "winget $WingetId"
  Refresh-Path
  if (-not ((Get-Command $Cmd -ErrorAction SilentlyContinue) -and (& $IsOk))) {
    throw "$Cmd 설치 후에도 인식되지 않습니다. 새 PowerShell 창에서 다시 실행하세요."
  }
  Ok "$Cmd 설치됨"
}

function Find-Civil3D {
  $roots = if ($Civil3DPath) { @(Get-Item -LiteralPath $Civil3DPath) } else {
    Get-ChildItem (Join-Path $env:ProgramFiles 'Autodesk') -Directory -Filter 'AutoCAD 20*' -ErrorAction SilentlyContinue
  }
  $hits = foreach ($r in $roots) {
    $aecc = Get-ChildItem -LiteralPath $r.FullName -Filter 'AeccDbMgd.dll' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if (-not $aecc) { continue }
    $year = if ($r.Name -match '(20\d\d)') { [int]$Matches[1] } else { 0 }
    [pscustomobject]@{ Root = $r.FullName; Year = $year }
  }
  $hits = @($hits | Sort-Object Year -Descending)
  if (-not $hits) { throw 'Civil 3D(AeccDbMgd.dll)를 찾지 못했습니다. -Civil3DPath "C:\Program Files\Autodesk\AutoCAD 20xx" 로 지정하세요.' }
  if ($hits.Count -gt 1) { Warn ("여러 버전 발견: " + (($hits | ForEach-Object Year) -join ', ') + " → 최신 사용. 다른 버전은 -Civil3DPath 로 지정.") }
  $pick = $hits[0]
  if ($pick.Year -and $pick.Year -lt 2025) {
    throw "Civil 3D $($pick.Year) 는 .NET Framework 기반이라 이 플러그인(net8.0-windows)을 로드할 수 없습니다. 2025 이상 필요."
  }
  return $pick
}

function Get-DesktopConfigPaths {
  $paths = @()
  if (Test-Path (Join-Path $env:APPDATA 'Claude')) { $paths += Join-Path $env:APPDATA 'Claude\claude_desktop_config.json' }
  # MSIX(Store) 설치본은 가상화된 경로를 씀
  Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue | ForEach-Object {
    $d = Join-Path $_.FullName 'LocalCache\Roaming\Claude'
    if (Test-Path $d) { $paths += Join-Path $d 'claude_desktop_config.json' }
  }
  return $paths
}

function Read-JsonObject([string]$Path) {
  if (-not (Test-Path $Path)) { return [pscustomobject]@{} }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]@{} }
  return $raw | ConvertFrom-Json
}

function Write-JsonNoBom([string]$Path, $Obj) {
  # PS 5.1 의 -Encoding UTF8 은 BOM 을 붙임 → Claude Desktop JSON 파싱 실패 가능
  [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding $false))
}

function Test-Plugin {
  Step "플러그인 연결 테스트 (127.0.0.1:$Port)"
  $code = 'return new { File = Database.Filename, Surfaces = CivilDoc.GetSurfaceIds().Count, Alignments = CivilDoc.GetAlignmentIds().Count };'
  $req  = @{ jsonrpc = '2.0'; id = 'verify'; method = 'executeCode'; params = @{ code = $code; readOnly = $true } } | ConvertTo-Json -Compress -Depth 5
  $client = New-Object Net.Sockets.TcpClient
  try {
    try { $client.Connect('127.0.0.1', $Port) } catch {
      Warn "연결 실패. Civil 3D 가 실행 중인지, 명령줄에 'Civil3D MCP plugin initialized.' 가 떴는지 확인하세요 (C3DMCPSTATUS)."
      return $false
    }
    $stream = $client.GetStream(); $stream.ReadTimeout = 60000
    $bytes = [Text.Encoding]::UTF8.GetBytes($req)
    $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
    $resp = (New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)).ReadToEnd()   # 서버가 응답 후 연결을 닫음
    $json = $resp | ConvertFrom-Json
    if ($json.error) { Warn ("플러그인은 응답했지만 오류: " + ($json.error | ConvertTo-Json -Compress)); return $false }
    Ok ("응답: " + ($json.result | ConvertTo-Json -Compress -Depth 5))
    return $true
  } finally { $client.Close() }
}

# ───────────────────────────── Verify / Uninstall ─────────────────────────────
if ($Verify) { if (Test-Plugin) { exit 0 } else { exit 1 } }

if ($Uninstall) {
  Step '제거'
  if (Get-Process acad -ErrorAction SilentlyContinue) { throw 'Civil 3D 를 먼저 종료하세요 (DLL 잠금).' }
  if (Test-Path $BundleDir) { Remove-Item $BundleDir -Recurse -Force; Ok "번들 삭제: $BundleDir" }
  if (Get-Command claude -ErrorAction SilentlyContinue) { TryExec { claude mcp remove $ServerName -s user }; Ok 'Claude Code 등록 해제' }
  foreach ($p in Get-DesktopConfigPaths) {
    if (-not (Test-Path $p)) { continue }
    $cfg = Read-JsonObject $p
    if ($cfg.mcpServers -and ($cfg.mcpServers.PSObject.Properties.Name -contains $ServerName)) {
      Copy-Item $p "$p.bak" -Force
      $cfg.mcpServers.PSObject.Properties.Remove($ServerName)
      Write-JsonNoBom $p $cfg; Ok "Claude Desktop 등록 해제: $p"
    }
  }
  Warn "소스 폴더는 남겨둠: $InstallDir (원하면 직접 삭제)"
  exit 0
}

# ───────────────────────────────── Install ─────────────────────────────────
Step '선행 조건'
Ensure-Tool git    'Git.Git'               { $true }
Ensure-Tool node   'OpenJS.NodeJS.LTS'     { [int]((node --version) -replace '^v(\d+).*', '$1') -ge 18 }
Ensure-Tool dotnet 'Microsoft.DotNet.SDK.8' { @(dotnet --list-sdks | Where-Object { $_ -match '^(\d+)\.' -and [int]$Matches[1] -ge 8 }).Count -gt 0 }
$NodeExe = (Get-Command node).Source

Step 'Civil 3D 탐지'
$c3d = Find-Civil3D
Ok "Civil 3D $($c3d.Year): $($c3d.Root)"
if (Get-Process acad -ErrorAction SilentlyContinue) { throw 'Civil 3D 가 실행 중입니다. 종료 후 다시 실행하세요 (번들 DLL 덮어쓰기 불가).' }

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
  $owner = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
  Warn "포트 $Port 를 이미 '$owner' 가 사용 중 → 플러그인이 바인딩 실패합니다. -Port 18080 같은 값으로 다시 실행 권장."
}

Step "소스 받기 → $InstallDir  (ref $Ref)"
if (Test-Path (Join-Path $InstallDir '.git')) {
  Exec { git -C $InstallDir fetch --quiet origin } 'git fetch'
} else {
  Exec { git -c core.autocrlf=false clone --quiet $RepoUrl $InstallDir } 'git clone'
}
Exec { git -C $InstallDir config core.autocrlf false } 'git config'
Exec { git -C $InstallDir checkout --quiet --force $Ref } 'git checkout'
# 기존 clone 이 CRLF 로 체크아웃돼 있었다면 LF 로 재정규화
TryExec { git -C $InstallDir rm --cached -r -q . }
Exec { git -C $InstallDir reset --quiet --hard } 'git reset'

$skill = Get-ChildItem (Join-Path $InstallDir 'skills') -Filter '*.skill.md' -Recurse | Select-Object -First 1
if ($skill -and ([IO.File]::ReadAllText($skill.FullName) -match "`r`n")) {
  Warn '스킬 파일이 여전히 CRLF 입니다 → civil3d_skills 가 0개를 반환합니다. 전역 git 설정(core.autocrlf / .gitattributes)을 확인하세요.'
} else { Ok '스킬 파일 LF 확인' }

if ($Port -ne 8080) {
  $rt = Join-Path $InstallDir 'plugin\Civil3dMcpPlugin\PluginRuntime.cs'
  $src = [IO.File]::ReadAllText($rt)
  if ($src -notmatch 'public const int Port = 8080;') { throw "PluginRuntime.cs 에서 포트 상수를 찾지 못했습니다 (업스트림 변경). -Ref 를 확인하세요." }
  [IO.File]::WriteAllText($rt, ($src -replace 'public const int Port = 8080;', "public const int Port = $Port;"), (New-Object Text.UTF8Encoding $false))
  Ok "플러그인 포트 → $Port"
}

Step 'Autodesk 참조 DLL 복사 → C_References'
$refDir = Join-Path $InstallDir 'C_References'
foreach ($dll in $RefDlls) {
  $f = Get-ChildItem -LiteralPath $c3d.Root -Filter $dll -Recurse -Depth 2 -ErrorAction SilentlyContinue |
       Sort-Object { $_.FullName.Length } | Select-Object -First 1
  if (-not $f) { throw "$dll 을(를) $($c3d.Root) 에서 찾지 못했습니다." }
  Copy-Item $f.FullName $refDir -Force
  Ok "$dll  ←  $($f.DirectoryName)"
}

Step 'MCP 서버 빌드 (Node)'
Push-Location $InstallDir
try {
  Exec { npm ci --no-audit --no-fund --loglevel=error } 'npm ci'
  Exec { npm run build --silent } 'npm run build'
} finally { Pop-Location }
$Entry = Join-Path $InstallDir 'build\index.js'
if (-not (Test-Path $Entry)) { throw "빌드 산출물 없음: $Entry" }
Ok $Entry

Step '플러그인 빌드 (.NET 8)'
$proj = Join-Path $InstallDir 'plugin\Civil3dMcpPlugin\Civil3dMcpPlugin.csproj'
$out  = Join-Path $InstallDir 'plugin\out'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
Exec { dotnet build $proj -c Release -o $out --nologo -v quiet "-p:Civil3DReferencesPath=$refDir" } 'dotnet build'
Ok (Join-Path $out 'Civil3dMcpPlugin.dll')

Step "Autoload 번들 배포 → $BundleDir"
if (Test-Path $BundleDir) { Remove-Item $BundleDir -Recurse -Force }
$contents = Join-Path $BundleDir 'Contents'
New-Item $contents -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $out '*') $contents -Recurse -Force
# Autodesk DLL 은 Civil 3D 가 이미 로드하므로 번들에 넣지 않음 (Private=False 지만 방어적으로 제거)
$RefDlls | ForEach-Object { Remove-Item (Join-Path $contents $_) -ErrorAction SilentlyContinue }
@'
<?xml version="1.0" encoding="utf-8"?>
<ApplicationPackage SchemaVersion="1.0" AutodeskProduct="AutoCAD" ProductType="Application"
  Name="Civil3dMcp" Description="Civil 3D MCP bridge (localhost JSON-RPC + Roslyn)" AppVersion="1.0.0"
  Author="local" ProductCode="{5B0F7C2E-3D1A-4E8B-9C6F-2A7D4E1B8C30}" UpgradeCode="{9E4A1D6B-7C2F-4B3E-8A5D-1F6C9B2E7A41}">
  <CompanyDetails Name="local" />
  <RuntimeRequirements OS="Win64" Platform="Civil3D" SeriesMin="R25.0" />
  <Components Description="Civil 3D MCP plugin">
    <RuntimeRequirements OS="Win64" Platform="Civil3D" SeriesMin="R25.0" />
    <ComponentEntry AppName="Civil3dMcp" ModuleName="./Contents/Civil3dMcpPlugin.dll"
      AppDescription="Starts the MCP JSON-RPC listener on Civil 3D startup" LoadOnAutoCADStartup="True" />
  </Components>
</ApplicationPackage>
'@ | Set-Content -LiteralPath (Join-Path $BundleDir 'PackageContents.xml') -Encoding UTF8
Ok '번들 배포 완료 (Civil 3D 시작 시 자동 로드)'

if (-not $SkipClaudeCode) {
  Step 'Claude Code 등록'
  if (Get-Command claude -ErrorAction SilentlyContinue) {
    TryExec { claude mcp remove $ServerName -s user }
    Exec { claude mcp add $ServerName -s user -e "CIVIL3D_PORT=$Port" -- $NodeExe $Entry } 'claude mcp add'
    Ok "user 스코프에 '$ServerName' 등록 (claude mcp list 로 확인)"
  } else { Warn 'claude CLI 없음 → 건너뜀' }
}

if (-not $SkipClaudeDesktop) {
  Step 'Claude Desktop 등록'
  $paths = @(Get-DesktopConfigPaths)
  if (-not $paths) { Warn 'Claude Desktop 설정 폴더 없음 → 건너뜀' }
  foreach ($p in $paths) {
    $cfg = Read-JsonObject $p
    if (Test-Path $p) { Copy-Item $p "$p.bak" -Force }
    if (-not ($cfg.PSObject.Properties.Name -contains 'mcpServers')) {
      $cfg | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{})
    }
    $server = [pscustomobject]@{ command = $NodeExe; args = @($Entry); env = [pscustomobject]@{ CIVIL3D_PORT = "$Port" } }
    $cfg.mcpServers | Add-Member -NotePropertyName $ServerName -NotePropertyValue $server -Force
    Write-JsonNoBom $p $cfg
    Ok "$p  (백업: .bak) — Claude Desktop 재시작 필요"
  }
}

Step '완료'
Write-Host @"
    1) Civil 3D 실행 → 도면 열기. 명령줄에 'Civil3D MCP plugin initialized.' 확인
       (안 뜨면: NETLOAD → $contents\Civil3dMcpPlugin.dll)
    2) 연결 테스트:  powershell -ExecutionPolicy Bypass -File "$PSCommandPath" -Verify$(if ($Port -ne 8080) { " -Port $Port" })
    3) Claude 에서:  "civil3d_skills 로 스킬 목록 보여주고, 도면의 서피스 나열해줘"
    ⚠ civil3d_execute 는 도면을 수정합니다. 작업 전 저장, 사본 도면에서 먼저 검증하세요.
"@
