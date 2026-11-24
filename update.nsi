Unicode True
!include "MUI2.nsh"
Name "胶片边框更新"
OutFile "dist/FilmBorder-Update.exe"
InstallDir "$LOCALAPPDATA\FilmBorder"
RequestExecutionLevel user
ShowInstDetails show
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_LANGUAGE "SimpChinese"
Section "更新胶片边框"
  IfFileExists "$INSTDIR\runtime\spektralab-host.exe" +3 0
    MessageBox MB_ICONSTOP "没有找到已安装的胶片边框，请选择原来的安装目录。"
    Abort
  SetOutPath "$INSTDIR\app"
  SetOverwrite on
  File "app\index.html"
  File "app\server.js"
SectionEnd
