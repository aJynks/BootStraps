@echo off

rem Show Windows version (same as ConEmu default)
rem cmd /d /c ver | "%windir%\system32\find.exe" "Windows"

rem Disable User@PC
set "ConEmuPromptNames=NO"

rem Colored prompt
set "ConEmuPrompt1=$E[m$E[92m$P$E[90m"
set "ConEmuPrompt2=$_$E[90m$G$S"
set "ConEmuPrompt3=$E[m$E]9;12$E\"

PROMPT %ConEmuPrompt1%%ConEmuPrompt2%%ConEmuPrompt3%
