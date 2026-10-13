# heiccy 1.0.0 제3자 소스 제공 기록

앱 1.0.0은 Apple Silicon arm64, macOS 15 이상을 대상으로 하며 첫 배포는
ad-hoc 서명이다. 공개 앱 소스 스냅샷과 별도로 이 문서의 코덱 소스 묶음을
DMG와 같은 공개 Release에 제공한다. 여기서 확인하는 것은 고정 소스의
무결성과 필요한 파일의 존재다. 법률 준수나 upstream wheel의 동일 재빌드를
보증하는 문서가 아니다. 라이선스 조건은 각 소스의 원문을 따른다.

## 고정 소스와 산출물

`packaging/release/collect_codec_sources.py`의 `SOURCES`가 다운로드 전 확정된
URL·SHA-256 허용 목록이다. 인터넷 응답에서 새 해시를 가져와 승인하지 않는다.
기존 캐시도 매 실행 다시 검사하며 해시 불일치는 자동 교체 없이 실패한다.
GitHub 태그 URL의 내용이 바뀌거나 서버가 archive를 재압축해도 실패하므로
고정 해시를 갱신하기 전에 원본·변경점·라이선스를 다시 검토해야 한다.

| 원본 | 공식 다운로드 | SHA-256 |
| --- | --- | --- |
| pillow-heif v1.1.1 전체 저장소 | [태그 archive](https://codeload.github.com/bigcat88/pillow_heif/tar.gz/refs/tags/v1.1.1) | `30002bb1dabc6c020369defcc2dfb5879b0c0621e999668976e232326d3f4452` |
| libheif 1.20.2 | [공식 배포 tarball](https://github.com/strukturag/libheif/releases/download/v1.20.2/libheif-1.20.2.tar.gz) | `68ac9084243004e0ef3633f184eeae85d615fe7e4444373a0a21cebccae9d12a` |
| libde265 1.0.16 | [공식 배포 tarball](https://github.com/strukturag/libde265/releases/download/v1.0.16/libde265-1.0.16.tar.gz) | `b92beb6b53c346db9a8fae968d686ab706240099cdd5aff87777362d668b0de7` |
| x265 exact commit `1d117bed4747758b51bd2c124d738527e30392cb` | [커밋 archive](https://codeload.github.com/Multicorewareinc/x265/tar.gz/1d117bed4747758b51bd2c124d738527e30392cb) | `ddb45be97924ab3d5da78e9c436418a12f812ae856cf3547e29e2bd69edcdf82` |
| x265 upstream 빌드 입력 4.1 | [공식 배포 tarball](https://bitbucket.org/multicoreware/x265_git/downloads/x265_4.1.tar.gz) | `a31699c6a89806b74b0151e5e6a7df65de4b49050482fe5ebf8a4379d7af8f29` |

다운로드는 `dist/macos/build-inputs/codec-sources/`에 저장한다. 거대한 archive를
Git에 vendor하지 않는다. 기본 실행 명령은 다음과 같다.

```sh
.venv-app-build/bin/python packaging/release/collect_codec_sources.py dist/macos --version 1.0.0
# 이미 내려받은 입력만 검사해 다시 묶으려면:
.venv-app-build/bin/python packaging/release/collect_codec_sources.py --offline
```

출력은 `dist/macos/heiccy-codec-sources-1.0.0.tar.gz`, 같은 이름의 `.sha256`,
`heiccy-codec-sources-1.0.0.manifest.json`이다. archive 내부에는
`heiccy-codec-sources-1.0.0/` 아래 `sources-manifest.json`, 이 문서,
수집 스크립트와 `sources/`의 원본 tarball 5개가 들어 있다.
manifest에는 각 입력 URL·해시·크기, archive 항목 수, 필수 파일의 해시와
x265 두 원본의 대조 결과가 기록된다. 원본 tarball은 수정하지 않는다.
외부 tar와 gzip의 타임스탬프·소유자·모드를 고정하므로 같은 스크립트·문서·입력을
같은 Python/zlib 환경에서 다시 묶으면 같은 산출물을 얻는다. 문서나 도구가 바뀌면
산출물 해시도 바뀔 수 있다. 게시된 릴리스 파일은 덮어쓰지 않는다.

CI는 수집기를 실행한 뒤 tar.gz와 `.sha256`을 artifact에 포함하고, 게시 단계에서 DMG와
함께 선택한다. source manifest는 tar 내부에 포함되므로 외부 `.manifest.json`의
별도 업로드는 선택 사항이다. `build-inputs/`는 게시하지 않는다. DMG manifest와 이 manifest의
해시 연결은 릴리스 workflow가 담당한다. 이 수집기는 태그 생성·게시·Git 조작을
수행하지 않는다. 실패 시 소스 검증 완료로 기록하거나 이전 bundle을 새 결과로
게시하면 안 된다.

## 안전검사와 확인 범위

압축 해시를 먼저 확인하고 tar를 읽는다. 경로는 지정된 최상위 디렉터리 아래만
허용한다. 절대 경로, `..`, 역슬래시, 제어문자, 중복 경로, 심볼릭·하드 링크,
장치·FIFO·sparse 파일, 특권 모드를 거부한다. 다운로드·비압축 크기와 항목 수에도
상한을 둔다. 모든 일반 파일 내용을 끝까지 읽어 잘림을 검출하며 추출하거나
소스 안의 코드를 실행하지 않는다.

pillow-heif의 `LICENSE.txt`, `LICENSES_bundled.txt`, `setup.py`, `pyproject.toml`,
`libheif/build_libs.py`, 두 `x265_cmake_*.patch`, macOS wheel workflow와 각 코덱의
라이선스·빌드 파일·공개 헤더가 비어 있지 않은지 검사한다. 전체 archive를 포함하므로
샘플·테스트·기타 라이선스 파일도 보존된다. 이는 파일 존재에 관한 완전성 검사이며
모든 의존성이 오프라인 재빌드 가능한지 증명하는 검사는 아니다.

검토 대상은 `pillow_heif-1.1.1-cp312-cp312-macosx_11_0_arm64.whl`, SHA-256
`9b31fd9b5b3c3f056f98f806e2ffe0f54710700045e28f68568753e56101d2ca`다.
잠금 파일에도 이 해시가 있다. wheel의 Mach-O 연결은 `_pillow_heif` →
`libheif.1.20.2.dylib` → `libx265.215.dylib`·`libde265.dylib`이며, AVIF/libaom은
이 입력에 없었다. 앱에 실제 들어가는 코덱 구성은 기존 `collect_licenses.py`의
`libheif_info()` 대조와 최종 앱 검사도 함께 확인한다.
wheel의 배포 고지는 [pillow-heif 1.1.1 공식 고지](https://github.com/bigcat88/pillow_heif/blob/v1.1.1/LICENSES_bundled.txt)에 있다.

## x265 원본과 재현성 한계

[pillow-heif 공식 빌드 스크립트](https://github.com/bigcat88/pillow_heif/blob/v1.1.1/libheif/build_libs.py)는
위 x265 4.1 배포 tarball을 내려받고 `x265_cmake_1.patch`, `x265_cmake_2.patch`를
차례로 적용한다. 패치는 CMake 정책·버전·AppleClang·ARM assembler 인자를 수정한다.
수집기는 패치와 스크립트를 전체 pillow-heif archive 안에 보존한다.

두 x265 원본의 일반 파일 경로·SHA-256을 루트 이름을 제외하고 대조한 결과,
차이는 `x265Version.txt` 하나다. exact commit archive의 이 파일에는
`6318f22`, `4.0`, 거리 `1`이 남아 있고, 공식 배포 tarball에는 `1d117be`,
`4.1`, 거리 `1`이 있다. 그래서 빌드 입력에는 공식 배포 tarball을 사용하고
exact commit archive는 코드 기준을 함께 추적하기 위해 보존한다.
[커밋의 실제 버전 파일](https://github.com/Multicorewareinc/x265/blob/1d117bed4747758b51bd2c124d738527e30392cb/x265Version.txt)도 참고한다.
수집기는 이 차이가 여전히 파일 하나인지 확인하지만 컴파일 결과는 비교하지 않는다.

upstream macOS arm64 workflow는 macOS 14, Python 3.12, cibuildwheel 3.1.3,
`MACOSX_DEPLOYMENT_TARGET=11.0`, `PH_FULL_ACTION=1`을 사용한다.
`pyproject.toml`은 `delocate-listdeps`와 `delocate-wheel --require-archs`로 wheel을
repair한다. 참조: [공식 workflow](https://github.com/bigcat88/pillow_heif/blob/v1.1.1/.github/workflows/wheels-pillow_heif.yml),
[repair 설정](https://github.com/bigcat88/pillow_heif/blob/v1.1.1/pyproject.toml).
현재 수집 작업은 코덱 컴파일·패치 적용·wheel 재빌드를 수행하지 않는다.
원래 빌드의 정확한 Xcode/SDK·Clang·CMake·setuptools·delocate 버전과 로그,
wheel ZIP 메타데이터, Mach-O 서명·UUID까지 일치한다고 확인하지 않았다.
이 자료를 제공했다는 사실과 PyPI wheel을 바이트 단위로 재현했다는 주장은 별개다.

## 수정 라이브러리 재빌드와 앱 교체 절차

아래는 공개 소스와 기존 패키징 코드에 근거한 작업 절차다. 수정 라이브러리를 실제로
재링크·교체하고 앱이 실행되는지 확인한 결과는 아직 없다. 별도 작업 환경과 앱
복사본에서 진행하고 배포 앱·원본 잠금 환경을 직접 덮어쓰지 않는다.

1. source bundle의 `.sha256`을 확인하고 원본별 해시를 manifest와 대조한다.
   자료를 별도 디렉터리에 추출한다. 코덱 빌드에는 x265 4.1 배포 tarball과
   libheif/libde265 배포 tarball을 사용한다.
2. 복사한 pillow-heif `libheif/build_libs.py`의 세 다운로드 URL을 검증한 로컬
   원본 archive로 대체한다. 수정 내역과 날짜를 보존한다. 이 스크립트는 과거의
   `wget --no-check-certificate` 경로를 포함하므로 고정 입력을 검증한 후 별도
   작업 복사본에서 사용한다. 전체 배포 스크립트를 검증 없이 실행하지 않는다.
3. 기존 `/usr/local`·Homebrew 라이브러리를 우연히 사용하는 것을 피하도록 별도
   prefix와 깨끗한 빌드 디렉터리를 지정한다. `BUILD_DIR`에는 스크립트가 `x265/`,
   `libde265/build/`, `libheif/build/`를 생성할 수 있어야 한다. 미리 소스 디렉터리를
   채우면 스크립트가 캐시라고 보고 configure와 패치를 생략할 수 있으므로 주의한다.
   `INSTALL_DIR_LIBS`는 개인 작업 prefix로 지정하고 `sudo`는 사용하지 않는다.
   코덱 빌드 옵션은 upstream 그대로 기록한다. x265 10/12bit 정적 부분 빌드와
   최종 shared lib, libheif의 libde265/x265 활성화·plugin/AVIF 비활성화가 포함된다.
4. 별도 CPython 3.12 arm64 venv에서 `LIBHEIF_ROOT`, `PKG_CONFIG_PATH`, include/link
   경로를 새 prefix로 지정해 pillow-heif 확장을 빌드하고 delocate로 wheel을
   repair한다. `setup.py`는 Homebrew를 자동 검색하므로 실제 compiler/linker 로그와
   `otool -L`에서 수정한 라이브러리를 사용했는지 확인한다. 생성한 wheel을 별도
   패키징 venv에 설치하고 `libheif_info()`와 실제 변환을 검사한다. 수정된 wheel은
   기존 requirements.lock 해시와 다르므로 정식 빌드의 `uv pip sync --require-hashes`를
   실행하면 원본으로 돌아간다. 기존 `build.sh`를 그대로 쓰는 재빌드 절차가 아니다.
5. 그 별도 venv의 Python으로 기존 spec을 실행한다. spec의 `collect_all("pillow_heif")`와
   PyInstaller dependency 분석은 wheel의 코덱과 확장을 모아 onedir worker를 만든다.
   고정된 `pathex`는 공개 프로젝트의 `src/`를 사용한다.

   ```sh
   "$REBUILD_PYTHON" -m PyInstaller --noconfirm --clean \
     --workpath "$REBUILD_ROOT/pyinstaller" \
     --distpath "$REBUILD_ROOT/frozen" packaging/macos/worker.spec
   ```

6. 앱 복사본의 `Contents/Resources/worker`를 이 새 worker로 교체하고 최종
   dependency 경로·arm64·최소 OS를 확인한다. 현재 번들에는 `_internal/`과
   `_internal/pillow_heif/.dylibs/` 양쪽에 코덱 경로가 있다. 하나만 덮어쓰면 실제
   로더가 다른 사본을 사용할 수 있다. 파일 단독 교체보다 worker 전체 재조립을
   우선하며, 단독 교체 시 ABI·install name과 모든 참조 대상·링크를 조사한다.
7. 새 worker 기준 라이선스·버전·소스 고지를 갱신한다. 기존 수집기는 변경된
   `libheif_info()`나 wheel 버전을 거부할 수 있어 재검토가 필요하다.
   `normalize_app.py`는 개발 도구의 절대 RPATH를 제거할 뿐 라이브러리 ABI나
   install name을 자동 교정하지 않는다. 기존 스크립트로 모든 Mach-O·framework·앱을
   안쪽부터 다시 ad-hoc 서명하고 검사한다.

   ```sh
   "$REBUILD_PYTHON" packaging/macos/normalize_app.py "$REBUILD_APP"
   "$REBUILD_PYTHON" packaging/macos/sign_app.py "$REBUILD_APP"
   "$REBUILD_PYTHON" packaging/macos/validate_app.py "$REBUILD_APP"
   "$REBUILD_PYTHON" packaging/macos/smoke_worker.py \
     "$REBUILD_APP/Contents/Resources/worker/heic-worker"
   "$REBUILD_APP/Contents/MacOS/HEICConverter" --smoke-test
   "$REBUILD_PYTHON" packaging/macos/test_panel_startup.py "$REBUILD_APP"
   ```

공개 소스에서 `worker.spec`, `normalize_app.py`, `sign_app.py`, `validate_app.py`와
전체 앱 빌드 코드도 함께 제공한다. ad-hoc 서명에는 개발자 개인 키가 필요하지 않다.
재서명 자체가 Gatekeeper 신뢰나 공증을 제공하지는 않는다.
[LGPLv3 §4](https://github.com/strukturag/libheif/blob/v1.20.2/COPYING)는 수정 라이브러리와의
재결합·재링크 또는 적절한 shared library 방식에 관한 조건을 포함한다.
위 설명만으로 조건 충족을 확정하지 않으며, 수정 라이브러리 교체·앱 실행과
제공할 application code/installation information의 범위 확인은 후속 검증으로 남는다.
[GPLv2 §3](https://github.com/Multicorewareinc/x265/blob/1d117bed4747758b51bd2c124d738527e30392cb/COPYING)의
대응 소스·컴파일 및 설치 스크립트 조건도 검토한다. worker의 동적 연결이나 Swift와의
프로세스 분리만으로 소스 제공 범위를 법률적으로 단정하지 않는다.

## PyInstaller bootloader와 기존 고지의 상태

설치된 PyInstaller 6.16.0 wheel에는 `PyInstaller/bootloader/Darwin-64bit/run` 등
미리 컴파일된 bootloader가 있다. worker spec의 `EXE`가 이를 사용한다.
본 코덱 archive에는 PyInstaller 소스·wheel을 포함하지 않는다. 이는 코덱 원본
묶음이며 앱 전체 런타임의 대응 소스 패키지라는 이름으로 취급하지 않는다.

[PyInstaller 6.16.0 공식 라이선스](https://pyinstaller.org/en/v6.16.0/license.html)와
[COPYING.txt](https://github.com/pyinstaller/pyinstaller/blob/v6.16.0/COPYING.txt)는
GPL-2.0-or-later 및 Bootloader Exception을 명시한다. 예외는 컴파일한 bootloader와
관련 loader를 다른 프로그램에 결합하여 배포하는 경우를 다루며, 의존성인
pillow-heif/x265의 조건을 면제하지 않는다. bootloader 수정분이나 결합되지 않은
배포는 별도 검토가 필요하다. run-time hooks는 Apache-2.0이다.
[bootloader 빌드 문서](https://pyinstaller.org/en/v6.16.0/bootloader-building.html)에 따르면
소스의 `bootloader/`에서 arm64용으로 `CC='clang -arch arm64' python waf --no-universal2 all`을
사용할 수 있다. 이를 실제 수행하거나 wheel bootloader와 비교한 결과는 없다.

2026-10-13 로컬 설치본·기존 산출물을 읽기 전용으로 확인한 결과는 다음과 같다.

- `collect_licenses.py`는 pyinstaller distribution을 포함하며 wheel의
  `pyinstaller-6.16.0.dist-info/licenses/COPYING.txt`를 찾는다. 실제 앱에도
  `Contents/Resources/Licenses/pyinstaller-0-COPYING.txt`가 있다. PyInstaller
  GPL 전문·예외 고지가 빠졌다고 보고할 근거는 없다.
- PyInstaller `collect_all`은 package metadata까지 복사한다.
  기존 worker에는 보정 전 `pillow_heif-1.1.1.dist-info/licenses/LICENSES_bundled.txt`가
  그대로 남고, 앱의 `Licenses/`에는 보정본이 있다. 원본 고지를 보존하되 별도
  정정 안내·실제 source bundle 위치를 두 경로에서 일관되게 연결하는 후속 작업이
  필요하다. 이 소스 수집기는 앱 고지를 수정하지 않는다.
- 기존 고지 수집기는 고정된 distribution 목록을 순회한다. 앱의
  `Analysis-00.toc`에는 Apache-2.0인 `pyi_rth_inspect`가 포함된다. hooks-contrib는
  목록 밖이므로 실제 번들에 그 runtime hook이 추가되면 해당 저작권·고지도 확인해야
  한다. 모든 설치 패키지가 런타임에 포함되는 것은 아니므로 전체 venv를 기준으로
  라이선스를 단정하지 않는다. 최종 TOC·Mach-O·런타임 파일 목록과 고지를 대조해야 한다.

Python/Pillow의 다른 네이티브 의존성, PyObjC, 수정 bootloader 등 전체 런타임 고지의
완전성은 이 네 코덱 소스 검사로 입증되지 않는다. 앱 공개 소스 archive, 최종 앱의
라이선스 파일, 이 코덱 source bundle, 재빌드 및 LGPL 교체 검증 결과를 함께
검토한 뒤 배포 준비 상태를 판단한다.

## 실행 검증 기록

2026-10-13, CPython 3.12.12 및 기존 `.venv-app-build` 환경에서 다음을 확인했다.

- 빈 캐시 `dist/macos/source-download-verification/`에서 수집기를 실행해 공식
  원본 5개를 실제 다운로드했다. 고정 해시, tar 안전검사, 필수 파일 존재, x265
  파일 대조를 모두 통과해 bundle과 체크섬·manifest를 생성했다.
- 기본 게시 위치 `dist/macos/`에서도 같은 검증과 bundle 생성을 완료했다.
  `.sha256`과 실제 archive 해시, 내부·외부 manifest 일치 여부를 확인한다.
- `pytest tests/test_codec_sources.py -q`: 32개 통과. 해시 불일치 시 tar 파싱 차단,
  잘못된 다운로드의 캐시 게시 차단, 경로 이탈·링크·장치·중복·필수 파일 누락·
  크기 제한, 출력 경로 링크, source bundle 재생성 일치 등을 검증했다.
- Ruff 0.14.4로 새 수집 스크립트와 테스트의 검사를 통과했다.
  Python sdist에서 packaging 코드가 없을 때 테스트 모듈은 collection 오류 없이 skip한다.

이 기록은 source bundle 생성 결과이며 정식 게시 완료, upstream wheel 동일 재빌드,
수정 코덱의 LGPL 교체·재링크·앱 실행 검증 결과를 뜻하지 않는다.
