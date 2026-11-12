# 앱 구성과 제3자 소스

현재 macOS 앱은 Swift 네이티브 앱과 Swift worker로 구성합니다.
이미지 디코딩·인코딩은 macOS Image I/O·Core Image, PNG 압축은 시스템 zlib을 사용합니다.
Python 런타임·Pillow·pillow-heif·libheif·libde265·x265를 앱에 포함하지 않습니다.

앱에는 프로젝트의 MIT 전문과 구성 고지만 `Contents/Resources/Licenses`에 포함합니다.
빌드·검증용 Python 환경은 아이콘 생성·합성 HEIC fixture·회귀 검사에 사용하며
앱이나 DMG로 복사하지 않습니다. 별도 PyPI CLI/TUI는 기존 Python 의존성을 유지하고
해당 의존성의 이용 조건을 따릅니다.

## 과거 배포 기록

Python worker를 포함하던 앱의 코덱 고지·대응 소스 수집 방식은 과거 Git 기록에 남습니다.
기존 공개 `SOURCE.json`과 초기 baseline은 변경하지 않습니다.
네이티브 앱에서는 코덱 소스 수집 도구와 코덱 소스 archive를 사용하지 않으며
새 빌드 manifest 스키마 2는 DMG·체크섬과 동일 공개 커밋의 출처를 검증합니다.
과거 산출물을 새 네이티브 릴리스에 혼합하지 않습니다.

## 검증

`packaging/macos/validate_app.py`는 앱·worker 두 arm64 Mach-O, macOS 기본 라이브러리
의존성, ad-hoc 서명, 파일·고지 허용 목록을 검사합니다.
Python 런타임·외부 코덱이나 임의 파일이 앱 번들에 들어가면 검증이 실패합니다.
빌드·서명·DMG 설치본 검증은 [빌드 안내](build.md)를 따릅니다.
