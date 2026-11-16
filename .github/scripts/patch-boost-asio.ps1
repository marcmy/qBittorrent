param([Parameter(Mandatory)][string] $BoostRoot)

$ErrorActionPreference = 'Stop'
$patch = Join-Path $PSScriptRoot '../../dist/windows/boost-asio-shutdown.patch'
# Boost is nested below the application checkout in CI. Prevent git apply
# from treating header paths as filters relative to that enclosing repository.
$previousCeiling = $env:GIT_CEILING_DIRECTORIES
$env:GIT_CEILING_DIRECTORIES = Split-Path ([IO.Path]::GetFullPath($BoostRoot)) -Parent
try
{
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
}
finally
{
    $env:GIT_CEILING_DIRECTORIES = $previousCeiling
}
