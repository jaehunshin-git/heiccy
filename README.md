# heiccy

<img
  src="docs/assets/branding/heiccy-app-icon.png"
  alt="heiccy 앱 아이콘"
  width="96"
  height="96"
/>

[한국어](README.md) · [English](README.en.md)

![macOS](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-555555)
![로컬 처리](https://img.shields.io/badge/Processing-Local%20only-2E8B57)
[![라이선스](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

> HEIC를 JPEG·PNG로, 알아서.
>
> 변환은 헤이키에게.

**heiccy**(헤이키)는 복사한 HEIC를 JPEG·PNG로 자동 변환해 **⌘V**로 붙여넣을 수
있도록 준비하는 macOS 메뉴바 앱입니다. 사진은 내 컴퓨터에서 처리하고 원본 파일은
변경하지 않습니다. 앱에 Python 런타임과 코덱이 포함되어 있어 Python을 따로 설치할
필요가 없습니다.

같은 저장소에서 폴더 변환과 스크립트 자동화를 위한 CLI·방향키 TUI도 제공합니다.
Python 패키지 설치는 [CLI/TUI](#clitui)를 참고하세요.

**배포 상태:** 앱 `1.0.0` 배포를 준비 중입니다. 공식 다운로드 진입점은
[heiccy Releases](https://github.com/jaehunshin-git/heiccy/releases)입니다.
릴리스가 공개된 뒤 해당 버전의 DMG를 받을 수 있습니다.

## macOS 앱 설치

### 요구 사항

- Apple Silicon Mac(arm64), macOS 15 이상
- 패키징된 앱 실행 시 별도 Python 설치 불필요

### DMG 다운로드와 설치

앱 배포 경로는 [GitHub Releases](https://github.com/jaehunshin-git/heiccy/releases)입니다.
같은 공개 릴리스에서 DMG와 체크섬을 받습니다. 공개 릴리스가 준비되기 전에는
아래 절차를 소스에서 빌드한 앱·DMG에 적용할 수 있습니다.

1. 같은 빌드나 릴리스에서 DMG와 해당 `.sha256` 파일을 받습니다.
2. 두 파일이 있는 디렉터리에서 체크섬을 확인합니다.

   ```bash
   shasum -a 256 -c heiccy-1.0.0-arm64.dmg.sha256
   ```

3. DMG를 열고 **heiccy.app**을 **Applications**로 드래그합니다.
4. Applications에서 **heiccy**를 실행하면 메뉴바에 아이콘이 나타납니다.

현재 빌드는 ad-hoc 서명을 사용하며 공증하지 않습니다. 첫 실행이 차단되면
[Apple 공식 안내](https://support.apple.com/ko-kr/102445)를 따르세요.

### 기존 앱 빌드 교체

파일 이름이 달라 기존 `HEIC Converter.app`이 자동으로 교체되지는 않습니다.
이전 앱의 메뉴바 메뉴에서 먼저 종료해 앱이 게시한 클립보드를 복구할 수 있도록
합니다. 이전 앱 번들은 Applications 밖에 백업해 둔 뒤 `heiccy.app`을 설치하고
해당 앱을 직접 실행하세요. 두 앱을 함께 실행하지 마세요. 이전 빌드로 돌아갈 때도
heiccy를 먼저 종료합니다.

번들 ID와 설정 키를 유지하므로 저장한 변환 옵션과 레거시 출력 경로를 계속 읽습니다.
일시정지는 실행 중에만 유지하고 다음 실행에서는 자동 변환이 다시 켜집니다.

### 소스에서 앱 빌드

소스에서 앱을 빌드하려면 [앱 빌드·배포 안내](docs/build.md)를 참고하세요.

## heiccy 사용법

1. Finder에서 지원하는 로컬 HEIC 파일을 복사하거나 지원하는 raw HEIC 이미지
   데이터를 복사합니다.
2. 변환 완료 알림을 기다립니다. 완료 전에 붙여넣으면 원본이 전달될 수 있습니다.
3. 대상 앱에서 **⌘V**로 붙여넣습니다.

| 조작 | 동작 |
| --- | --- |
| 메뉴바 아이콘 왼쪽 클릭 | 현재 클립보드 파일의 이름·썸네일·변환 상태를 표시하거나 숨깁니다. |
| 메뉴바 아이콘 오른쪽 클릭 | 자동 변환 일시정지·다시 시작, 설정 열기, 앱 종료를 제공합니다. |
| 설정 | JPEG·PNG 형식, 품질, 압축 수준과 메타데이터 정책을 고릅니다. |
| 실행 중인 앱을 Finder·Spotlight에서 다시 열기 | 클립보드 패널을 표시합니다. |

자동 변환은 앱을 실행할 때마다 켜집니다. 일시정지는 해당 실행에만 유지하고 변환
옵션은 저장합니다. 패널은 포커스가 다른 곳으로 이동하면 닫힙니다. 복사 감지만으로
패널을 열지 않으며 클립보드 이력은 저장하지 않습니다.

기본 출력은 JPEG·품질 90입니다. PNG 압축 수준은 6, 메타데이터 정책은 GPS·XMP를
제거하는 `safe`입니다. macOS 15 이상에서 지원하는 Apple HDR 게인 맵이 있으면
PNG를 16비트 HDR로 변환할 수 있습니다. JPEG는 SDR이며, HDR 적용 여부는 원본과
ImageIO 지원에 따라 달라집니다.

### 지원 입력과 클립보드 보호

- 읽을 수 있는 로컬 일반 `.heic` 파일 URL과 raw `public.heic` 데이터를 지원합니다.
- 비HEIC 항목의 순서와 보존 가능한 클립보드 표현을 유지합니다. 모든 HEIC 변환이
  성공하고 같은 복사 내용이 유지될 때만 결과를 게시합니다. 새 복사가 감지되면
  이전 변환 결과를 게시하지 않습니다.
- 변환 항목이 참조하는 파일은 임시 파일이며 원본은 변경하지 않습니다. 정상 종료 시
  클립보드가 앱의 결과를 유지하고 있으면 원본을 복구합니다. 비정상 종료 후 복구는
  보장하지 않습니다.
- 파일 약속, 오프라인 파일, Photos 자산 참조와 `.photoslibrary` 내부 파일 URL이
  함께 있는 입력은 지원하지 않습니다. 파일 변환이 필요하면 수정하지 않은 원본을
  내보내 Finder에서 복사하세요. 동영상은 변환 대상에서 제외합니다.
- 수신 앱마다 지원하는 클립보드 표현이 달라 모든 앱에서 모든 항목을 붙여넣을 수
  있다고 보장하지 않습니다.

지원 입력과 수신 앱의 제한은 [클립보드 호환성](docs/compatibility.md)을 참고하세요.
사용 중 발견한 문제는 [heiccy 이슈](https://github.com/jaehunshin-git/heiccy/issues)에
접수할 수 있습니다.

## CLI/TUI

[![PyPI](https://img.shields.io/pypi/v/heic-converter-tui?logo=pypi&logoColor=white)](https://pypi.org/project/heic-converter-tui/)
[![Python 패키지 다운로드](https://api.pepy.tech/personalized-badge/heic-converter-tui?period=month&units=none&left_color=grey&right_color=blue&left_text=downloads%2Fmonth)](https://pepy.tech/projects/heic-converter-tui)
[![Python](https://img.shields.io/badge/Python-%E2%89%A53.11-3776AB?logo=python&logoColor=white)](https://www.python.org/)

[PyPI 패키지](https://pypi.org/project/heic-converter-tui/)는 터미널에서 폴더를 변환할 때
사용합니다. 배포 이름은 `heic-converter-tui`, 실행 명령은 `heic-converter`를 유지합니다.
이 패키지 설치로 macOS 독립 앱이 설치되지는 않습니다.

### CLI/TUI 요구 사항

- Python 3.11 이상
- macOS 우선 지원
- `uv` 또는 `pipx`

런타임 의존성인 Pillow와 pillow-heif는 설치 명령이 함께 설치합니다.

### 설치

`uv`를 사용하면 다음과 같이 설치합니다.

```bash
uv tool install heic-converter-tui
```

`pipx`를 사용할 수도 있습니다.

```bash
pipx install heic-converter-tui
```

설치된 배포 패키지 이름은 `heic-converter-tui`, 실행 명령은
`heic-converter`입니다. 다음 명령으로 설치를 확인할 수 있습니다.

```bash
heic-converter --help
```

### TUI로 실행

인수 없이 실제 터미널에서 실행합니다.

```bash
heic-converter
```

먼저 `한국어` 또는 `English`를 고릅니다. 이후 질문, 검증 오류, 선택지, 요약과
취소 안내는 선택한 언어로 표시됩니다. 선택 항목은 `↑`/`↓` 방향키로 이동하고
Enter로 확정합니다. 경로는 직접 입력합니다.

```text
HEIC Converter TUI

? 언어 / Language 한국어

HEIC 이미지 변환 설정

? 입력 디렉터리 경로 ./input
? 출력 디렉터리 경로 ./output
? 출력 형식 JPEG
? JPEG 품질 높음 (90)
? 하위 디렉터리도 변환할까요? 아니요 — 현재 디렉터리만
? 메타데이터 처리 안전하게 유지 (권장) — GPS 등 민감 정보는 제거
? 같은 이름의 출력 파일이 있을 때 이름 변경 (권장) — 번호를 붙여 새 파일 생성

설정 요약
  입력 디렉터리: input
  출력 디렉터리: output
  출력 형식: JPEG (JPEG 품질 90)
  하위 디렉터리 포함: 아니요
  메타데이터: safe
  파일 충돌 처리: rename

? 이 설정으로 변환을 시작할까요? 시작
```

`Ctrl+C`를 누르거나 마지막 단계에서 `취소`를 선택하면 변환하지 않고 종료 코드
`130`으로 끝납니다.

### 명령어로 실행

스크립트나 자동화 환경에서는 출력 형식을 명시합니다.

```bash
# input 디렉터리의 HEIC를 JPEG로 변환
heic-converter --input ./input --output ./output --format jpeg

# photos 디렉터리의 HEIC를 PNG로 변환
heic-converter --input ./photos --output ./converted --format png

# 하위 디렉터리까지 검색하고 기존 결과가 있으면 새 이름으로 저장
heic-converter \
  --input ./photos \
  --output ./converted \
  --format jpeg \
  --recursive \
  --on-conflict rename
```

TTY가 아닌 환경에서 `--format`을 생략하면 사용법 오류로 종료합니다.

### 업데이트와 삭제

`uv`로 설치한 패키지는 다음과 같이 관리합니다.

```bash
uv tool upgrade heic-converter-tui
uv tool uninstall heic-converter-tui
```

`pipx`를 사용했다면 다음 명령을 실행합니다.

```bash
pipx upgrade heic-converter-tui
pipx uninstall heic-converter-tui
```

## 📚 동작 및 옵션

### 명령 형식

```text
heic-converter --input INPUT --output OUTPUT --format {jpeg,png} [옵션]
```

`--input`과 `--output`은 디렉터리 경로입니다. 기본값은 각각 `./input`과
`./output`입니다. 두 디렉터리에 같은 경로를 지정할 수 없으며 단일 파일 입력은
지원하지 않습니다.

| 옵션 | 설명 | 기본값 |
| --- | --- | --- |
| `-i, --input PATH` | 입력 HEIC 디렉터리 | `./input` |
| `-o, --output PATH` | 출력 디렉터리 | `./output` |
| `-f, --format {jpeg,png}` | 출력 형식 | 비대화형 실행에서 필수 |
| `--jpeg-quality N` | JPEG 품질, 1~100 | `90` |
| `--png-compression N` | PNG 압축 수준, 0~9 | `6` |
| `--recursive` | 하위 디렉터리까지 검색 | 꺼짐 |
| `--metadata {safe,preserve,strip}` | 메타데이터 처리 정책 | `safe` |
| `--on-conflict {rename,skip,overwrite,error}` | 출력 파일 충돌 정책 | `rename` |

JPEG 출력은 `.jpeg`, PNG 출력은 `.png` 확장자를 사용합니다.
TUI에서는 자주 쓰는 품질·압축 사전 설정을 고르며, CLI에서는 위 범위 안의 값을
직접 지정할 수 있습니다.

### 메타데이터와 이미지 처리

| 정책 | 동작 |
| --- | --- |
| `safe` | GPS와 XMP를 제거하고 나머지 EXIF와 ICC 프로파일을 가능한 범위에서 보존합니다. |
| `preserve` | EXIF, XMP, ICC 프로파일을 가능한 범위에서 보존합니다. |
| `strip` | 출력 이미지에서 EXIF와 XMP를 제거합니다. HDR PNG의 색 재현에 필요한 ICC 프로파일 또는 CICP 색상 정보는 유지합니다. |

변환 시 이미지 방향을 픽셀에 반영하고, 메타데이터를 저장하는 경우 출력 EXIF 방향
값을 `1`로 정규화합니다. JPEG는 알파 채널을 지원하지 않으므로 투명 영역을 흰색
배경과 합성합니다. PNG는 알파 채널을 유지합니다.

macOS 15 이상에서는 Apple HDR 게인 맵이 포함된 HEIC를 16비트 HDR PNG로
변환합니다. 네이티브 HDR 경로는 대표 이미지의 인덱스가 0이 아니어도 해당 이미지를
선택합니다. 실제 생성한 합성 다중 HEIC로 대표 인덱스 1, 16비트·PQ 출력과 메타데이터
정책을 검증했습니다. HDR 화면에서 원본의 밝기와 색 표현을 유지하기 위해 PNG에 HDR
색상 프로파일을 기록합니다. 다른 환경에서는 HEIC의 기본 SDR 이미지를 PNG로
저장하므로 HDR 화면에서 원본과 다르게 보일 수 있습니다. JPEG 출력은 SDR입니다.
앱의 파일별 결과에는 HDR 적용 여부와 SDR 처리 사유를 표시합니다. HDR 처리는
원본 게인 맵과 ImageIO API 지원에 따라 달라지며 모든 HEIC의 HDR 보존을 보장하지
않습니다. PNG 압축 설정은 Pillow SDR 경로에 적용하고 네이티브 HDR 인코더는 자체
압축을 사용합니다.

### 파일 검색과 충돌 처리

- 확장자가 `.heic`인 파일만 처리하며 대소문자를 구분하지 않습니다. `.heif`는
  지원하지 않습니다.
- 기본적으로 입력 디렉터리 바로 아래만 검색합니다. `--recursive`를 사용하면 하위
  디렉터리까지 검색하고 상대 디렉터리 구조를 출력에 유지합니다.
- 출력 디렉터리가 입력 디렉터리 안에 있어도 출력 트리는 검색 대상에서 제외합니다.
- `rename`은 `photo.jpeg`, `photo-2.jpeg`, `photo-3.jpeg`처럼 사용 가능한 이름을
  자동으로 선택합니다.
- `skip`은 기존 파일을 유지하고 해당 입력을 건너뜁니다.
- `overwrite`는 기존 출력 파일을 교체합니다.
- `error`는 충돌한 파일을 실패로 기록하고 다음 입력을 계속 처리합니다.
- 완성된 결과만 나타나도록 출력 디렉터리의 임시 파일에 먼저 저장합니다.

### 지원 범위

HEIC의 기본 정지 이미지 한 장만 JPEG 또는 PNG로 변환합니다. 다음 기능은 지원하지
않습니다.

- PDF 또는 HWP/HWPX 변환
- OCR 및 텍스트 추출
- Live Photo의 동영상 처리
- 기본 정지 이미지 이외의 보조 이미지, 시퀀스 또는 동영상 추출
- CLI의 단일 파일 입력(앱은 클립보드 입력을 사용)

### 종료 코드

| 코드 | 의미 |
| --- | --- |
| `0` | 모든 입력을 성공적으로 처리함 |
| `1` | 하나 이상의 파일을 읽거나 변환하거나 저장하는 중 오류가 발생함 |
| `2` | 인수·경로·옵션이 잘못됐거나 변환할 `.heic` 파일이 없음 |
| `130` | 대화형 화면에서 `Ctrl+C`를 누르거나 변환을 취소함 |

## 배포와 문서

macOS 앱은 [GitHub Releases](https://github.com/jaehunshin-git/heiccy/releases),
CLI/TUI는 [PyPI](https://pypi.org/project/heic-converter-tui/)에서 배포합니다.
두 제품의 버전과 배포 시점은 독립적입니다.

- [클립보드 호환성과 지원 범위](docs/compatibility.md)
- [앱 빌드·배포 안내](docs/build.md)
- [릴리스 노트](docs/releases/v1.0.0.md)
- [제3자 구성 요소와 대응 소스](docs/third-party-sources.md)
- [버그 신고·기능 제안](https://github.com/jaehunshin-git/heiccy/issues)

앱 자동 업데이트, Intel 지원, Homebrew Cask와 Mac App Store 배포는 제공하지 않습니다.
업데이트할 때 앱을 정상 종료한 뒤 새 DMG로 교체하세요.

## 라이선스

이 프로젝트는 [MIT 라이선스](LICENSE)를 따릅니다. 저작권 표시와 라이선스 전문을
포함하는 조건으로 사용, 복사, 수정, 배포 및 상업적 이용을 허용합니다. 소프트웨어는
어떠한 보증도 없이 제공되며, 자세한 조건은 [LICENSE](LICENSE)를 참고하세요.
앱에 포함된 제3자 구성 요소는 각각의 라이선스를 따릅니다. pillow-heif에 포함된
코덱 고지 등 Python 런타임과 라이브러리 이용 조건은 앱의
`Contents/Resources/Licenses`에서 확인할 수 있습니다.
