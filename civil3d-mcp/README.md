# civil3d-mcp Windows 설치 패키지

[barbosaihan/civil3d-mcp](https://github.com/barbosaihan/civil3d-mcp) @ `344ad15`를 미리 빌드해 둔 패키지입니다. 대상은 Civil 3D 2025/2026이고, PC에는 **Node.js만 있으면 됩니다**. .NET SDK, git, Autodesk DLL 복사는 필요 없습니다.

## 설치

1. `civil3d-mcp-win.zip`을 통째로 압축 해제합니다. zip은 git에 넣지 않았으니, 세션에서 받은 파일을 쓰거나 아래 "직접 빌드" 절차로 만드세요.
2. Civil 3D를 종료한 상태에서 실행합니다.
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```
3. Civil 3D를 켜고 도면을 연 뒤 연결을 확인합니다.
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Verify
   ```

| 옵션 | 용도 |
|---|---|
| `-Port 18080` | 8080 충돌 시. 사용자 환경변수 `CIVIL3D_PORT`와 MCP 서버 env를 함께 설정 |
| `-Verify` | 플러그인에 직접 JSON-RPC로 접속해 도면 파일명, 서피스·선형 개수를 조회 |
| `-Uninstall` | 서버, 번들, 환경변수, Claude Code/Desktop 등록을 모두 제거 |
| `-SkipClaudeCode` / `-SkipClaudeDesktop` | 해당 클라이언트 등록을 건너뜀 |

## 업스트림 대비 변경 (`patches.diff`)

- **스킬 파서 CRLF/BOM 허용**: Windows 기본 git 설정으로 체크아웃하면 `civil3d_skills`가 0개를 반환하는 버그를 고쳤습니다.
- **플러그인 포트**: 하드코딩된 `8080` 대신 환경변수 `CIVIL3D_PORT`를 읽습니다. 기본값은 8080입니다.
- **등록 시 `CIVIL3D_HOST=127.0.0.1` 명시**: Windows에서 `localhost`는 `::1`로 먼저 풀리는데, 플러그인은 IPv4 루프백에만 바인딩합니다.
- **autoload 번들 배포** (`PackageContents.xml`): NETLOAD가 필요 없습니다.

## 검증 범위

- 플러그인을 Autodesk 공식 NuGet 참조(`AutoCAD.NET*` 25.0.0, `Civil3D.NET` 13.7.1175 = Civil 3D 2025.2)로 빌드했고, 경고·오류 모두 0입니다.
- Node MCP 서버와 컴파일된 플러그인의 `RpcTcpServer` 사이에서 20KB 요청과 50KB 응답이 왕복하는 것까지 확인했습니다.
- `install.ps1`의 설치·제거 흐름은 Windows cmdlet을 stub으로 대체해 시뮬레이션했습니다.
- **Civil 3D 안에서 실제로 로드되는지는 아직 확인하지 못했습니다** (Roslyn 실행, `Platform="Civil3D"` autoload).

## 직접 빌드

```bash
# 참조 DLL: Civil 3D 설치 경로에서 복사하거나 NuGet(autocad.net.core/model 25.0.0, autocad.net 25.0.1, civil3d.net 13.7.1175)에서 받음
git clone https://github.com/barbosaihan/civil3d-mcp && cd civil3d-mcp && git checkout 344ad15
git apply ../patches.diff
npm ci && npm run build
dotnet build plugin/Civil3dMcpPlugin/Civil3dMcpPlugin.csproj -c Release -o plugin/out -p:EnableWindowsTargeting=true
```

## 주의

- `civil3d_query`의 "read-only"는 커밋하지 않는다는 뜻일 뿐입니다. `SaveAs`나 파일 쓰기 같은 부작용은 그대로 실행됩니다.
- 샌드박스는 정규식 매칭이라 우회가 쉽습니다. 사실상 Civil 3D 프로세스 권한으로 임의 코드가 실행됩니다.
- 스크립트 타임아웃으로 무한 루프는 끊기지 않습니다. 작업 전에 도면을 저장하세요.
