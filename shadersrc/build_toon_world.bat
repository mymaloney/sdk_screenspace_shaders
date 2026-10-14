@echo off
REM Builds the toon_world shaders as Shader Model 3.0
bin\ShaderCompile.exe /O 3 -ver 30 -shaderpath "%cd%" toon_sundepth_vs30.hlsl
bin\ShaderCompile.exe /O 3 -ver 30 -shaderpath "%cd%" toon_sundepth_ps30.hlsl
bin\ShaderCompile.exe /O 3 -ver 30 -shaderpath "%cd%" toon_world_ps30.hlsl
pause
