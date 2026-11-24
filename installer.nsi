Unicode True
!include "MUI2.nsh"
!include "LogicLib.nsh"

Name "胶片边框"
OutFile "dist/FilmBorder-Offline-Setup.exe"
InstallDir "$LOCALAPPDATA\FilmBorder"
RequestExecutionLevel user
ShowInstDetails show

!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "胶片边框" Main
  IfFileExists "$INSTDIR\runtime\*.*" 0 +3
    MessageBox MB_ICONSTOP "此目录已有 runtime 文件夹。请选择一个新目录，避免覆盖已有文件。"
    Abort
  IfFileExists "$INSTDIR\app\*.*" 0 +3
    MessageBox MB_ICONSTOP "此目录已有 app 文件夹。请选择一个新目录，避免覆盖已有文件。"
    Abort
  IfFileExists "$INSTDIR\install.ps1" 0 +3
    MessageBox MB_ICONSTOP "此目录已有 install.ps1 文件。请选择一个新目录，避免覆盖已有文件。"
    Abort
  SetOutPath "$INSTDIR\app"
  File "app\index.html"
  File "app\server.js"
  SetOutPath "$INSTDIR"
  File "install.ps1"
  DetailPrint "正在准备内置的 SpektraLab 引擎，无需联网。"
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  File /oname=spektralab-offline.zip "vendor\spektralab-windows-v2.zip"
  IfFileExists "$PLUGINSDIR\spektralab-offline.zip" +3 0
    MessageBox MB_ICONSTOP "无法读取内置引擎，安装已停止。"
    Abort
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\install.ps1" -InstallDir "$INSTDIR" -SourceApp "$INSTDIR\app" -Archive "$PLUGINSDIR\spektralab-offline.zip"' $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "引擎安装失败（错误代码 $0）。请检查磁盘空间或选择新的安装目录后重试。"
    Abort
  ${EndIf}
  CreateDirectory "$SMPROGRAMS\胶片边框"
  CreateShortCut "$DESKTOP\胶片边框.lnk" "$INSTDIR\runtime\agents\node.exe" '"$INSTDIR\app\server.js"' "$INSTDIR\runtime\spektralab-v2.exe" 0
  CreateShortCut "$SMPROGRAMS\胶片边框\胶片边框.lnk" "$INSTDIR\runtime\agents\node.exe" '"$INSTDIR\app\server.js"' "$INSTDIR\runtime\spektralab-v2.exe" 0
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FilmBorder" "DisplayName" "胶片边框"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FilmBorder" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FilmBorder" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FilmBorder" "NoRepair" 1
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\胶片边框.lnk"
  Delete "$SMPROGRAMS\胶片边框\胶片边框.lnk"
  RMDir "$SMPROGRAMS\胶片边框"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\FilmBorder"
  RMDir /r "$INSTDIR\app"
  RMDir /r "$INSTDIR\runtime"
  Delete "$INSTDIR\install.ps1"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
SectionEnd
