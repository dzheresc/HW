# Runs the openXC7 flow in Docker. Usage: .\build.ps1 [make target]
param([string]$Target = "all", [string]$Image = "openxc7-2:latest")
docker run --rm -v "${PSScriptRoot}:/work" -w /work $Image make $Target
exit $LASTEXITCODE
