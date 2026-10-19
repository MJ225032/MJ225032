# civil3d-mcp 설치 스크립트

[barbosaihan/civil3d-mcp](https://github.com/barbosaihan/civil3d-mcp)를 Windows + Civil 3D 2025 이상 환경에 한 번에 설치합니다.

## 실행

Civil 3D를 **종료한 상태**에서 PowerShell을 열고:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

| 옵션 | 용도 |
|---|---|
| `-Port 18080` | 8080을 다른 프로그램이 쓰고 있을 때. 플러그인 C# 상수와 MCP 서버 env를 함께 바꿉니다 |
| `-Civil3DPath "C:\Program Files\Autodesk\AutoCAD 2026"` | 여러 버전이 설치돼 있을 때 (기본값: 최신 버전) |
| `-Ref main` | 검토한 커밋(`344ad15`) 대신 업스트림 최신을 받을 때 |
| `-Verify` | Civil 3D를 켜고 도면을 연 상태에서 플러그인 연결을 확인 |
| `-Uninstall` | 번들 삭제, Claude Code/Desktop 등록 해제 |
| `-SkipClaudeCode` / `-SkipClaudeDesktop` | 해당 클라이언트 등록을 건너뜀 |

## 업스트림 README 대비 달라진 점

- **CRLF 회피**: `core.autocrlf=false`로 clone합니다. 업스트림 스킬 파서는 LF만 인식하기 때문에, Windows 기본 git 설정으로 받으면 `civil3d_skills`가 0개를 반환합니다.
- **NETLOAD 불필요**: `%APPDATA%\Autodesk\ApplicationPlugins\Civil3dMcp.bundle`에 autoload 번들로 배포해서 Civil 3D가 시작될 때 자동으로 로드됩니다.
- **참조 DLL 자동 복사**: `AeccDbMgd.dll` 등 5개 DLL을 Civil 3D 설치 경로에서 찾아 복사합니다.
- **node 절대경로로 등록**: Claude Desktop이 PATH를 못 읽는 경우에 대비합니다. 기존 `claude_desktop_config.json`은 `.bak`으로 백업한 뒤 병합합니다.

## 주의

- `civil3d_query`의 "read-only"는 트랜잭션을 커밋하지 않는다는 뜻일 뿐입니다. `SaveAs`, `SendStringToExecute`, 파일 쓰기 같은 부작용은 그대로 실행됩니다.
- 샌드박스는 정규식 문자열 매칭이라 우회가 쉽습니다. 사실상 Civil 3D 프로세스 권한으로 임의 코드가 실행된다고 보세요.
- 스크립트 타임아웃으로 무한 루프는 끊기지 않습니다. 작업 전에 도면을 저장하세요.
