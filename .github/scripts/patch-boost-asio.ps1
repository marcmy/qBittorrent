param([Parameter(Mandatory)][string] $BoostRoot)

$ErrorActionPreference = 'Stop'
$patch = Join-Path $PSScriptRoot '../../dist/windows/boost-asio-shutdown.patch'
& git -C $BoostRoot apply --reverse --check $patch 2>$null
if ($LASTEXITCODE -eq 0)
{
    Write-Host 'Boost.Asio shutdown patch already applied.'
    exit 0
}
& git -C $BoostRoot apply --check $patch
if ($LASTEXITCODE -ne 0)
{
    throw 'Boost.Asio source does not match the shutdown patch. Review the dependency update.'
}
& git -C $BoostRoot apply $patch
if ($LASTEXITCODE -ne 0)
{
    throw 'Failed to apply Boost.Asio shutdown patch.'
}
