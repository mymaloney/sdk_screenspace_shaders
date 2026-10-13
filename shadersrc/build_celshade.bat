@echo off
REM Builds the GMod cel-shading shader as Shader Model 3.0 (required for VPOS and GShader's pp_vs30)
bin\ShaderCompile.exe /O 3 -ver 30 -shaderpath "%cd%" example_celshade_ps2x.hlsl
pause
