Unicode true
!include "MUI2.nsh"

!ifndef APP_FILE
  !error "APP_FILE is required"
!endif
!ifndef OUTPUT_DIR
  !error "OUTPUT_DIR is required"
!endif
!ifndef APP_VERSION
  !error "APP_VERSION is required"
!endif

Name "KEYI 可译"
OutFile "${OUTPUT_DIR}/HanYi-Setup.exe"
VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_VERSION}.0"
VIAddVersionKey /LANG=2052 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "ProductName" "KEYI 可译"
VIAddVersionKey /LANG=2052 "CompanyName" "KEYI"
VIAddVersionKey /LANG=2052 "FileDescription" "KEYI 可译 Windows Installer"
VIAddVersionKey /LANG=2052 "LegalCopyright" "Copyright (c) 2026 KEYI"
InstallDir "$LOCALAPPDATA\Programs\HanYi"
InstallDirRegKey HKCU "Software\HanYi" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\HanYi.exe"
!define MUI_FINISHPAGE_RUN_TEXT "启动 KEYI 可译"

Var WelcomeTextFont

!define MUI_PAGE_CUSTOMFUNCTION_SHOW WelcomePageShow
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Function WelcomePageShow
  CreateFont $WelcomeTextFont "$(^Font)" "8"
  SendMessage $mui.WelcomePage.Text ${WM_SETFONT} $WelcomeTextFont 0
FunctionEnd

Section "KEYI 可译" MainSection
  SetShellVarContext current
  nsExec::ExecToLog 'taskkill /IM HanYi.exe /F'
  Pop $0
  Sleep 500
  SetOutPath "$INSTDIR"
  File "${APP_FILE}"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\HanYi" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HanYi" "DisplayName" "KEYI 可译"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HanYi" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HanYi" "Publisher" "KEYI"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HanYi" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HanYi" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  CreateDirectory "$SMPROGRAMS\HanYi"
  CreateShortcut "$SMPROGRAMS\HanYi\KEYI 可译.lnk" "$INSTDIR\HanYi.exe"
  CreateShortcut "$SMPROGRAMS\HanYi\卸载 KEYI 可译.lnk" "$INSTDIR\Uninstall.exe"
SectionEnd

Function .onInstSuccess
  IfSilent 0 notSilent
  Exec '"$INSTDIR\HanYi.exe"'
notSilent:
FunctionEnd

Section "Uninstall"
  SetShellVarContext current
  ExecWait 'taskkill /IM HanYi.exe /F'
  Delete "$INSTDIR\HanYi.exe"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\HanYi\KEYI 可译.lnk"
  Delete "$SMPROGRAMS\HanYi\卸载 KEYI 可译.lnk"
  RMDir "$SMPROGRAMS\HanYi"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\HanYi"
  DeleteRegKey HKCU "Software\HanYi"
SectionEnd
