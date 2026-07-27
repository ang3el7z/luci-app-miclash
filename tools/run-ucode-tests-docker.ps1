[CmdletBinding()]
param(
	[Parameter(Position = 0, ValueFromRemainingArguments = $true)]
	[string[]] $TestPath = @()
)

$ErrorActionPreference = 'Stop'
$image = if ($env:MICLASH_UCODE_IMAGE) {
	$env:MICLASH_UCODE_IMAGE
} else {
	'miclash-ucode-tests:openwrt-24.10'
}
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dockerfile = Join-Path $PSScriptRoot 'docker\ucode-tests.Dockerfile'

& docker info --format '{{.ServerVersion}}' *> $null
if ($LASTEXITCODE -ne 0) {
	throw 'Docker is unavailable. Start Docker Desktop and retry.'
}

& docker image inspect $image *> $null
if ($LASTEXITCODE -ne 0) {
	Write-Host "Building pinned host-ucode image: $image"
	& docker build --file $dockerfile --tag $image (Split-Path $dockerfile)
	if ($LASTEXITCODE -ne 0) {
		throw "Failed to build Docker image: $image"
	}
}

$arguments = @(
	'run', '--rm',
	'--mount', "type=bind,source=$repoRoot,target=/workspace",
	'-w', '/workspace',
	$image,
	'sh', 'tools/run-ucode-tests.sh'
) + $TestPath

& docker @arguments
if ($LASTEXITCODE -ne 0) {
	exit $LASTEXITCODE
}
