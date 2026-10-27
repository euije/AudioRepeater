# Windows에서 AudioRepeater iOS 빌드 및 설치

GitHub Actions가 iPhone용 unsigned IPA를 만듭니다. Windows의 Sideloadly가
개인 Apple 계정으로 IPA를 서명하고 USB로 연결한 iPhone에 설치합니다.
Windows에서 Xcode를 실행할 필요는 없습니다.

## 1. 확인한 프로젝트 설정

| 항목 | 값 |
| --- | --- |
| 저장소 | `euije/AudioRepeater` |
| 프로젝트 | `iOS/AudioRepeaterIOS.xcodeproj` |
| 앱 Target / 공유 Scheme | `AudioRepeaterIOS` / `AudioRepeaterIOS` |
| 별도 UI 테스트 Target / Scheme | `AudioRepeaterVolumeUITests` / `VolumeControl` |
| 빌드 | Release, `iphoneos`, arm64 |
| 최소 OS | iOS 16.0 |
| 언어 / UI | Swift 5 언어 모드, SwiftUI |
| Bundle Identifier | `com.a2m.audiorepeater.ios` |
| 프로젝트 Signing | Automatic, `Apple Development`, Team ID 미설정 |
| CI Signing | `CODE_SIGNING_ALLOWED=NO`, 인증서와 프로비저닝 프로필 미사용 |
| 외부 패키지 | SPM, CocoaPods, Carthage 의존성 없음 |
| Entitlements / 앱 확장 | 없음 |

앱은 AVFoundation, AudioToolbox, MediaPlayer, UIKit 등 Apple 프레임워크를
사용합니다. 기존 `ScreenCaptureAudioRecorder.swift`는 iOS 27의
ScreenCaptureKit API를 사용합니다. `@available`은 실행 시 OS를 검사하므로,
이 소스를 컴파일할 때는 iOS 27 SDK가 필요합니다.

워크플로는 GitHub의 [`xcode-27` Runner](https://github.com/actions/runner-images/issues/14404)를
사용합니다. Runner는 preview로 안내되어 있으므로 배정 지연이나 이미지 변경이
발생할 수 있습니다. 워크플로는 Xcode와 SDK 버전을 로그에 남기며, SDK가 27보다
낮으면 중단합니다. 일반 재생의 최소 OS는 iOS 16으로 유지합니다.
시스템 오디오 캡처는 기존 코드에 따라 iOS 27 이상에서만 사용할 수 있습니다.

무료 계정으로 서명할 때 문제가 될 수 있는 Push Notifications, iCloud,
App Groups 등의 Entitlements는 프로젝트에 없습니다. 파일 선택기로 Google Drive의
파일을 가져오는 기능은 이 앱의 iCloud Entitlement를 요구하지 않습니다.
IPA 구조 검증과 실제 설치·재생 검증은 서로 다른 단계입니다.

## 2. GitHub 웹에서 빌드하고 IPA 다운로드

1. [iOS unsigned IPA](https://github.com/euije/AudioRepeater/actions/workflows/ios-ipa.yml)를 엽니다.
2. **Run workflow**에서 `main` 또는 빌드할 브랜치를 선택합니다.
   **run_ui_tests**를 켜면 시뮬레이터 UI 검사와 화면 캡처도 실행합니다.
   일반 IPA 빌드에서는 이 옵션을 꺼 두면 됩니다.
3. **Run workflow**를 누릅니다.
4. 새 실행을 열고 `build` 작업의 성공 여부를 확인합니다.
5. 실행 화면의 **Artifacts**에서 `AudioRepeaterIOS-unsigned`를 다운로드합니다.
6. 다운로드한 ZIP을 풉니다. 내부의 `AudioRepeaterIOS-unsigned.ipa`를 사용합니다.

Artifact에는 `SHA256SUMS.txt`와 `build-info.txt`도 들어 있습니다.
IPA 자체는 ZIP 형식이지만, IPA 내부의 `Payload`를 풀어서 Sideloadly에 넣지 마세요.
빌드 로그와 `.xcresult`는 별도 `AudioRepeaterIOS-build-logs` Artifact에 있습니다.
워크플로의 Artifact 보관 기간은 14일입니다.

## 3. PowerShell에서 빌드 및 다운로드 자동화

[GitHub CLI](https://cli.github.com/)를 설치합니다. 새 PowerShell을 열고
`gh auth login`으로 저장소에 접근할 계정에 로그인합니다.
필요하면 `gh auth refresh -h github.com -s workflow`로 workflow 권한을 추가합니다.
이 인증은 GitHub용이며 Apple 계정과는 관계가 없습니다.

저장소 루트에서 실행합니다.

```powershell
.\iOS\scripts\build_download_ipa.ps1
```

스크립트가 수동 빌드를 요청하고 완료를 기다립니다. 성공하면
`iOS\build\ipa\RUN_ID`로 Artifact를 내려받고 IPA의 SHA-256을 검사합니다.
이미 실행한 빌드를 받으려면 실행 URL의 숫자를 지정합니다.

```powershell
.\iOS\scripts\build_download_ipa.ps1 -RunId RUN_ID
```

`-Ref BRANCH`로 브랜치를 선택할 수 있습니다. `-OutputDirectory PATH`로
다운로드 폴더를 바꿀 수 있습니다. 같은 브랜치에서 여러 수동 빌드가 동시에
생기면 스크립트는 잘못된 실행을 고르지 않도록 중단합니다. 이때 `-RunId`를 사용합니다.

## 4. Windows 설치 환경 준비

1. [Sideloadly 공식 사이트](https://sideloadly.io/)에서 Windows 64비트 설치 파일을 받습니다.
2. Sideloadly를 설치합니다.
3. Sideloadly 공식 사이트가 안내하는 **웹 설치판 iTunes와 iCloud**를 설치합니다.
   Microsoft Store 버전 대신 공식 안내의 다운로드 링크를 사용합니다.
   iTunes 설치 구성요소인 Apple Mobile Device Support가 USB 통신을 담당합니다.
4. 설치 프로그램이 재부팅을 요청하면 Windows를 재부팅합니다.
5. iPhone을 데이터 전송이 가능한 USB 케이블로 연결합니다.
6. iPhone 잠금을 풉니다. **이 컴퓨터를 신뢰하겠습니까?**가 나오면 **신뢰**를 누릅니다.
7. iTunes에서 iPhone이 보이는지 확인합니다. Sideloadly의 **iDevice**에서도
   설치할 iPhone을 선택합니다.

Windows 장치 관리자에 `Apple iPhone`이 보여도 Sideloadly 통신까지 확인된 것은
아닙니다. Sideloadly에서 장치를 선택할 수 있어야 다음 단계로 진행합니다.
드라이버 설치에는 Windows 관리자 권한이 필요할 수 있습니다.

## 5. Apple 계정으로 서명하고 설치

1. Sideloadly에 `AudioRepeaterIOS-unsigned.ipa`를 끌어 놓습니다.
2. **iDevice**에서 USB로 연결한 iPhone을 선택합니다.
3. **Apple ID**에 개인 Apple 계정을 입력합니다.
4. 기본 Apple ID 서명 모드를 사용합니다. Tweak 주입, Bundle ID 변경,
   최소 iOS 버전 변경 등의 옵션은 기본값으로 둡니다.
5. **Start**를 누릅니다. 비밀번호와 2단계 인증 코드를 요청하면
   Sideloadly에 직접 입력합니다.
6. 설치 완료 로그를 확인합니다.

Apple 비밀번호와 인증 코드를 GitHub Secrets, 소스 파일, PowerShell 인수 또는
채팅에 입력하지 마세요. CI는 Apple 인증 정보를 사용하지 않습니다.
계정 인증 및 기기에서의 확인은 사용자가 직접 진행합니다.

같은 Bundle ID의 앱이 다른 서명으로 이미 설치되어 있으면 업데이트가 거부될 수
있습니다. 기존 앱을 삭제하면 가져온 WAV와 앱 데이터도 삭제될 수 있으므로
필요한 파일을 먼저 내보냅니다. Bundle ID를 바꾸면 별도 앱으로 설치될 수 있습니다.

## 6. iPhone에서 실행 허용

1. **설정 > 개인정보 보호 및 보안 > 개발자 모드**를 켭니다.
2. iPhone을 재시동합니다. 재시동 후 개발자 모드 확인을 완료합니다.
3. **설정 > 일반 > VPN 및 기기 관리**에서 서명에 사용한 Apple 계정을 엽니다.
4. 개발자 신뢰를 승인한 뒤 AudioRepeater를 실행합니다.

개발자 모드 항목이 없으면 먼저 Sideloadly로 설치를 시도한 뒤 설정을 다시
확인합니다. 앱을 처음 실행한 후 WAV 가져오기와 짧은 재생을 확인합니다.
OS가 iOS 27보다 낮으면 시스템 오디오 캡처 옵션을 사용하지 않습니다.

## 7. 무료 계정의 유효기간과 재서명

무료 계정의 프로비저닝 프로필은 발급 후 7일이면 만료됩니다.
기기당 동시 설치 가능한 개인 테스트 앱은 최대 3개입니다.
Apple은 무료 Personal Team에 App ID 10개와 기기 3개의 제한도 안내합니다.
자세한 조건은 [Apple 계정 안내](https://developer.apple.com/help/account/basics/about-your-developer-account)를 확인합니다.

만료 전에 같은 IPA를 Sideloadly에서 같은 계정으로 다시 서명하고 설치합니다.
앱 소스가 바뀌지 않았다면 GitHub에서 IPA를 다시 빌드할 필요는 없습니다.
Sideloadly의 자동 갱신을 사용할 수도 있습니다. PC와 iPhone이 통신할 수 있어야
갱신이 이루어집니다. 처음에는 USB 연결로 갱신을 확인합니다.

## 8. 오류 확인

| 증상 | 확인할 사항 |
| --- | --- |
| Actions가 queued에 머묾 | `xcode-27` preview Runner의 배정 상태를 확인합니다. |
| `No such module ScreenCaptureKit` 또는 API를 찾지 못함 | environment 로그에서 iOS SDK가 27 이상인지 확인합니다. 낮은 SDK에서는 기존 캡처 소스를 빌드할 수 없습니다. |
| Scheme을 찾지 못함 | 빌드한 커밋에 `AudioRepeaterIOS.xcscheme`이 `xcshareddata/xcschemes` 아래 있는지 확인합니다. |
| Signing Team 또는 프로필을 요구함 | `Build unsigned Release app for iPhone` 단계에서 `CODE_SIGNING_ALLOWED=NO`가 전달되었는지 확인합니다. |
| 빌드 실패, IPA 없음 | `build` 작업의 실패 단계와 `AudioRepeaterIOS-build-logs`를 확인합니다. 실패한 실행은 설치용 IPA를 제공하지 않을 수 있습니다. |
| Sideloadly에서 iPhone이 보이지 않음 | 잠금 해제, 컴퓨터 신뢰, 데이터 케이블, USB 포트, Apple Mobile Device 서비스, 웹 설치판 iTunes를 확인합니다. |
| Anisette 또는 Apple 로그인 오류 | 웹 설치판 iTunes와 iCloud를 확인하고 Sideloadly 공식 FAQ의 해당 오류 안내를 따릅니다. Apple 계정 자체의 로그인 상태와 2단계 인증도 확인합니다. |
| `Untrusted Developer` | iPhone의 VPN 및 기기 관리에서 해당 개발자를 신뢰합니다. |
| `Developer Mode Required` | 개발자 모드를 켜고 재시동과 기기 확인을 완료합니다. |
| 앱 수 또는 App ID 제한 | 무료 계정의 설치 수와 App ID 제한을 확인합니다. App ID 제한은 앱 삭제만으로 즉시 해제되지 않을 수 있습니다. |
| 서명·프로필 만료 | 같은 IPA를 Sideloadly에서 재서명하고 다시 설치합니다. |
| 기존 앱과 서명이 맞지 않음 | 기존 데이터 보존 방법을 확인한 뒤 동일한 서명 계정을 사용합니다. |

설치 오류별 설명은 [Sideloadly 공식 FAQ](https://sideloadly.io/faq.html)에 있습니다.
개발자 모드 절차는 [Apple 문서](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)도 참고합니다.

## 9. 검증 기록: 2026-10-27

- [Actions 실행 40493058395](https://github.com/euije/AudioRepeater/actions/runs/40493058395): 성공.
- 빌드 커밋: `5d6acfdf490f53dfbb804c96c1c3b3509e567463`.
- 실제 환경: Xcode 27.1 (`27A9275`), iPhoneOS SDK 27.1.
- 실제 결과: Release 앱 및 unsigned IPA 생성. arm64 Mach-O, iPhoneOS 플랫폼,
  최소 iOS 16.0, 실행 파일 권한, 서명·프로필 없음, ZIP 구조를 확인했습니다.
- ScreenCaptureKit의 weak linkage를 확인했습니다. 낮은 OS에서의 실행과 재생은
  별도의 기기 검증이 필요합니다.
- Windows 다운로드 후 IPA의 SHA-256이 Artifact의 체크섬과 일치했습니다.
  PowerShell 스크립트의 기존 실행 다운로드 경로도 같은 결과를 확인했습니다.
- 기존 Swift 5 소스에서 미사용 변수와 동시 실행 캡처 경고가 발생했습니다.
  빌드 오류는 없으며, 이 작업은 앱 소스나 Swift 언어 모드를 변경하지 않았습니다.
- Sideloadly의 실제 재서명, iPhone 설치 및 앱 실행은 이 빌드 검증에 포함되지 않습니다.
