#Requires -Version 5.1
<#
.SYNOPSIS
  civil3d-mcp 사전 빌드 패키지 설치 (Windows + Civil 3D 2025/2026)

.DESCRIPTION
  이 폴더에는 이미 빌드된 MCP 서버(server\)와 Civil 3D 플러그인 번들(Civil3dMcp.bundle\)이 들어 있습니다.
  이 스크립트는 복사 + 등록만 합니다. 필요한 것은 Node.js 18+ 뿐 (없으면 winget 으로 설치).

  1. server\            → %LOCALAPPDATA%\civil3d-mcp
  2. Civil3dMcp.bundle\ → %APPDATA%\Autodesk\ApplicationPlugins  (Civil 3D 시작 시 자동 로드)
  3. Claude Code / Claude Desktop 에 MCP 서버 등록

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Port 18080
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Verify       # Civil 3D 켜고 도면 연 상태에서
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
  [ValidateRange(1024, 65535)][int]$Port = 8080,
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'civil3d-mcp'),
  [switch]$SkipClaudeCode,
  [switch]$SkipClaudeDesktop,
  [switch]$Verify,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$Here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ServerName = 'civil3d'
$BundleDir  = Join-Path $env:APPDATA 'Autodesk\ApplicationPlugins\Civil3dMcp.bundle'
$Entry      = Join-Path $InstallDir 'build\index.js'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    [!]  $msg" -ForegroundColor Yellow }

function Exec([scriptblock]$Block, [string]$What) {
  & $Block
  if ($LASTEXITCODE -ne 0) { throw "$What 실패 (exit $LASTEXITCODE)" }
}

# 실패해도 되는 네이티브 명령 (PS 5.1 은 stderr 리다이렉트 시 EAP=Stop 이면 예외를 던짐)
function TryExec([scriptblock]$Block) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & $Block 2>&1 | Out-Null } catch { } finally { $ErrorActionPreference = $prev }
}

function Assert-Civil3DClosed {
  if (Get-Process acad -ErrorAction SilentlyContinue) { throw 'Civil 3D(acad.exe)가 실행 중입니다. 종료 후 다시 실행하세요 (플러그인 DLL 잠금).' }
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
      Warn "연결 실패. Civil 3D 명령줄에 'Civil3D MCP plugin initialized.' 가 떴는지, C3DMCPSTATUS 결과가 running: True 인지 확인하세요."
      return $false
    }
    $stream = $client.GetStream(); $stream.ReadTimeout = 60000
    $bytes = [Text.Encoding]::UTF8.GetBytes($req)
    $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
    $resp = (New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)).ReadToEnd()   # 서버가 응답 후 연결을 닫음
    $json = $resp | ConvertFrom-Json
    if ($json.error) { Warn ("플러그인은 응답했지만 오류: " + ($json.error | ConvertTo-Json -Compress)); return $false }
    Ok ("Civil 3D 응답: " + ($json.result | ConvertTo-Json -Compress -Depth 5))
    return $true
  } finally { $client.Close() }
}

# ───────────────────────────── Verify / Uninstall ─────────────────────────────
if ($Verify) {
  $envPort = [Environment]::GetEnvironmentVariable('CIVIL3D_PORT', 'User')
  if (-not $PSBoundParameters.ContainsKey('Port') -and $envPort) { $Port = [int]$envPort }
  if (Test-Plugin) { exit 0 } else { exit 1 }
}

if ($Uninstall) {
  Step '제거'
  Assert-Civil3DClosed
  if (Test-Path $BundleDir)  { Remove-Item $BundleDir -Recurse -Force; Ok "번들 삭제: $BundleDir" }
  if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force; Ok "서버 삭제: $InstallDir" }
  [Environment]::SetEnvironmentVariable('CIVIL3D_PORT', $null, 'User')
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
  exit 0
}

# ───────────────────────────────── Install ─────────────────────────────────
foreach ($need in 'server\build\index.js', 'server\node_modules', 'Civil3dMcp.bundle\PackageContents.xml', 'Civil3dMcp.bundle\Contents\Civil3dMcpPlugin.dll') {
  if (-not (Test-Path (Join-Path $Here $need))) { throw "패키지가 불완전합니다: $need 없음. zip 을 통째로 압축 해제했는지 확인하세요." }
}

Step 'Node.js'
$node = Get-Command node -ErrorAction SilentlyContinue
$nodeOk = $node -and ([int]((& node --version) -replace '^v(\d+).*', '$1') -ge 18)
if (-not $nodeOk) {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'Node.js 18+ 가 필요합니다. https://nodejs.org 에서 LTS 설치 후 다시 실행하세요.' }
  Warn 'Node.js LTS 설치 중 (winget)'
  Exec { winget install --id OpenJS.NodeJS.LTS -e --silent --accept-source-agreements --accept-package-agreements } 'winget Node.js'
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { throw 'Node.js 설치 후에도 인식되지 않습니다. 새 PowerShell 창에서 다시 실행하세요.' }
}
$NodeExe = $node.Source
Ok "$NodeExe ($(& node --version))"

Step 'Civil 3D 확인'
$c3d = Get-ChildItem (Join-Path $env:ProgramFiles 'Autodesk') -Directory -Filter 'AutoCAD 20*' -ErrorAction SilentlyContinue |
  Where-Object { Get-ChildItem -LiteralPath $_.FullName -Filter 'AeccDbMgd.dll' -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1 } |
  ForEach-Object { if ($_.Name -match '(20\d\d)') { [int]$Matches[1] } } | Sort-Object -Descending
if (-not $c3d) { Warn 'Civil 3D 설치 경로를 찾지 못했습니다 (비표준 경로면 무시해도 됨).' }
else {
  Ok ("발견: Civil 3D " + ($c3d -join ', '))
  if (-not ($c3d | Where-Object { $_ -in 2025, 2026 })) {
    Warn "이 패키지는 Civil 3D 2025/2026(.NET 8, R25.x)용으로 빌드됐습니다. $($c3d -join ', ') 에서는 자동 로드되지 않습니다."
  }
}
Assert-Civil3DClosed

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
  $owner = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
  Warn "포트 $Port 를 '$owner' 가 이미 사용 중 → 플러그인이 바인딩 실패합니다. -Port 18080 처럼 다른 값으로 다시 실행하세요."
}

Step "MCP 서버 복사 → $InstallDir"
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
Copy-Item (Join-Path $Here 'server') $InstallDir -Recurse -Force
Ok $Entry

Step "플러그인 번들 복사 → $BundleDir"
if (Test-Path $BundleDir) { Remove-Item $BundleDir -Recurse -Force }
New-Item (Split-Path $BundleDir) -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $Here 'Civil3dMcp.bundle') $BundleDir -Recurse -Force
# 인터넷에서 받은 zip 의 DLL 은 Zone.Identifier(MOTW) 가 붙어 .NET 로드가 막힐 수 있음
Get-ChildItem $BundleDir, $InstallDir -Recurse -File | Unblock-File
Ok '번들 배포 완료 (Civil 3D 시작 시 자동 로드)'

# 플러그인은 acad.exe 의 환경변수 CIVIL3D_PORT 를 읽음 (없으면 8080)
if ($Port -ne 8080) { [Environment]::SetEnvironmentVariable('CIVIL3D_PORT', "$Port", 'User'); Ok "사용자 환경변수 CIVIL3D_PORT=$Port" }
else { [Environment]::SetEnvironmentVariable('CIVIL3D_PORT', $null, 'User') }

if (-not $SkipClaudeCode) {
  Step 'Claude Code 등록'
  if (Get-Command claude -ErrorAction SilentlyContinue) {
    TryExec { claude mcp remove $ServerName -s user }
    # 127.0.0.1 명시: Windows 에서 localhost 는 ::1 로 먼저 풀리는데 플러그인은 IPv4 루프백에만 바인딩
    # '--' 는 반드시 따옴표: PowerShell 은 맨 -- 를 자기 인자 종료 토큰으로 삼켜서 claude.ps1 shim 에 전달하지 않음
    # → 가변 인자 -e 가 node 경로까지 먹어 'missing required argument commandOrUrl' 발생
    Exec { claude mcp add $ServerName -s user -e CIVIL3D_HOST=127.0.0.1 -e "CIVIL3D_PORT=$Port" '--' $NodeExe $Entry } 'claude mcp add'
    Ok "user 스코프에 '$ServerName' 등록 (확인: claude mcp list)"
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
    $server = [pscustomobject]@{
      command = $NodeExe
      args    = @($Entry)
      env     = [pscustomobject]@{ CIVIL3D_HOST = '127.0.0.1'; CIVIL3D_PORT = "$Port" }
    }
    $cfg.mcpServers | Add-Member -NotePropertyName $ServerName -NotePropertyValue $server -Force
    Write-JsonNoBom $p $cfg
    Ok "$p  (백업: .bak) — Claude Desktop 완전 종료 후 재시작"
  }
}

Step '완료'
Write-Host @"
    1) Civil 3D 실행 → 도면 열기 → 명령줄에 'Civil3D MCP plugin initialized.' 확인
       안 뜨면: NETLOAD → $BundleDir\Contents\Civil3dMcpPlugin.dll
       '보안 - 로드되지 않은 실행 파일' 경고가 뜨면 [항상 로드]
    2) 연결 테스트:  powershell -ExecutionPolicy Bypass -File "$PSCommandPath" -Verify
    3) Claude 에서:  "civil3d_skills 로 스킬 목록 보여주고, 도면의 서피스 나열해줘"
    ⚠ civil3d_execute 는 도면을 수정합니다. 작업 전 저장, 사본 도면에서 먼저 검증하세요.
"@
