> Historical handoff README, preserved before GitHub publication. For the implemented app and current verification, see the root README and PROJECT_STATE.md.

# WorshipCue · Codex Handoff v1.0
**2026-10-07 | Korean-first native iPad pilot | Product decisions + engineering specification + reference tests**

> 악보와 필기는 각자 편하게. 곡 안내와 팀 필기는 함께.

## 바로 시작
1. 이 폴더의 전체 내용을 새 `worshipcue` 저장소에 넣습니다. 기존 저장소라면 기존 파일을 덮어쓰지 말고 Codex가 먼저 차이를 확인하게 합니다.
2. macOS의 Codex에서 해당 저장소를 열고 `CODEX_START_HERE.md`를 읽고 실행하도록 지시합니다.
3. 첫 구현 대상은 `docs/12_BUILD_PLAN.md`의 M0입니다. PDF 위 필기, 저장/복구, 페이지 재사용, 버전 간 선택 복사를 먼저 검증합니다.
4. 마일스톤마다 테스트와 증거를 남깁니다. 서버 키나 Apple 서명이 없으면 로컬 작업을 계속하고 필요한 설정을 정확히 보고합니다.

**이 패키지는 완성된 앱이 아닙니다.** 실제 Swift 순수 도메인 참조 코드와 테스트, SQLite 로컬 저장 스키마, 계약/테스트용 PDF, 상세 구현 명세가 포함됩니다. iPad UI, PencilKit/PDFKit 연결, Supabase 서버/RLS, TestFlight 빌드는 Codex가 구현하고 별도로 검증해야 합니다. `verification/REPORT.md`에서 실제 실행한 검증과 미검증 범위를 확인합니다.

## 문서 우선순위
`docs/02_DECISIONS.md` → 해당 기능의 상세 명세 → 계약/테스트 → 이전 대화/이전 한 페이지 소개서.

이 패키지는 이전 소개서의 **웹 우선, 자동 곡 전환, 페이지 동기화, 개인 필기 자동 병합** 제안을 대체합니다. 사용자 승인 없이 이 동작을 되살리지 않습니다.

## 가장 중요한 제품 규칙
- iPad 우선. Android, 웹 악보장, 결제 구현은 첫 파일럿에서 제외합니다.
- 밴드마스터가 곡을 보내도 연주자의 현재 악보는 바뀌지 않습니다. **연주자가 눌러야 열립니다.**
- 알림은 화면으로만 표시합니다. 소리, 진동, 강제 페이지 전환은 없습니다.
- 새 안내가 쌓이면 가장 최근 안내 하나만 표시합니다. 최근 10개 이력은 별도 화면에서 봅니다.
- v1/v2/v3 PDF는 변경 불가 원본입니다. 개인 필기는 버전별로 보존하고 선택 복사/붙여넣기/이동을 제공합니다.
- 팀 필기는 **해당 예배의 해당 곡 순서 항목 + 정확한 PDF 버전 + 페이지**에 연결합니다. 다른 버전에는 덮어 그리지 않고 팀 악보 미리보기를 제공합니다.
- 끊겨도 다운로드된 악보와 로컬 필기는 유지됩니다. 실시간 안내만 중단됩니다.

## 문서 지도
| 파일 | 용도 |
|---|---|
| `CODEX_START_HERE.md` | Codex 최초 실행 지시 |
| `AGENTS.md` | 저장소에 상시 적용할 개발 규칙 |
| `PROJECT_STATE.md` | 현재 상태와 다음 작업 |
| `docs/01_PRODUCT_BRIEF_KO.md` | 수정된 한국어 제품 소개 |
| `docs/02_DECISIONS.md` | 확정 사항, 기본값, 과거 제안의 대체 기록 |
| `docs/03_PRD_KO.md` | 범위, 사용자, 기능/수용 기준 |
| `docs/04_UX_SPEC_KO.md` | iPad 화면, 동선, 한국어 문구 |
| `docs/05_ARCHITECTURE.md` | 네이티브/서버/저장 구조와 대안 |
| `docs/06_DATA_AND_API.md` | 엔티티, RPC, 트랜잭션, 권한 |
| `docs/07_LIVE_STATE_MACHINE.md` | 곡 안내/확인/재연결/경합 처리 |
| `docs/08_ANNOTATIONS_AND_VERSIONS.md` | 필기 레이어, 좌표, 복사, 충돌 |
| `docs/09_OFFLINE_AND_RECOVERY.md` | 저장, 다운로드, 손상/중단 복구 |
| `docs/10_SECURITY_AND_RIGHTS.md` | 접근 제어, 게스트, 저작권, 개인정보 |
| `docs/11_TEST_PLAN.md` | 자동/실기기/다중 기기/장애 테스트 |
| `docs/12_BUILD_PLAN.md` | 구현 순서, 완료 조건, Codex 작업 단위 |
| `docs/13_PILOT_AND_PRICING.md` | 첫 교회 파일럿, 가치와 구매 검증 |
| `docs/14_SOURCES.md` | 공식 참고 자료 및 설계 판단과의 구분 |
| `docs/15_RISK_REGISTER.md` | 위험과 대응 |
| `docs/16_RELEASE_RUNBOOK.md` | 배포/백업/복원/롤백 |
| `contracts/` | JSON Schema, 한국어 문구, RPC/권한 계약 |
| `db/local_cache_v1.sql` | 참조용 로컬 SQLite 스키마 |
| `reference/WorshipCueCore/` | UI/서버와 분리된 Swift 도메인 참조 구현 |
| `fixtures/` | 저작권 문제 없는 합성 악보/오류 테스트 자료 |
| `scripts/` | 패키지 자체 검증 |
| `verification/` | 실행 증거와 제한 사항 |

## 패키지 검증
```sh
swift test --package-path reference/WorshipCueCore
# Python 검증 의존성이 없는 환경에서 한 번 실행:
python3 -m pip install -r scripts/requirements.txt
python3 scripts/verify_package.py
```
두 명령은 **패키지 참조 모델**을 검증합니다. 실제 앱, 실시간 서버, Apple Pencil 정확도, 보안 정책을 검증한 것으로 간주하지 않습니다.

## 산출물 언어
사용자 화면/제품 문서는 한국어 우선, 코드 식별자/기술 문서는 영어 중심입니다. 번역 문자열은 코드에 흩뿌리지 말고 String Catalog로 관리합니다.
