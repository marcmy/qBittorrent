param([Parameter(Mandatory)][string] $BoostRoot)

$ErrorActionPreference = 'Stop'
$work = Join-Path $env:RUNNER_TEMP 'asio-shutdown-test'
New-Item -ItemType Directory -Force $work | Out-Null
$source = Join-Path $PSScriptRoot '../../test/asio_shutdown.cpp'
$reactorRelative = 'boost/asio/detail/impl/select_reactor.ipp'
$interrupterRelative = 'boost/asio/detail/impl/socket_select_interrupter.ipp'
$patch = Join-Path $PSScriptRoot '../../dist/windows/boost-asio-shutdown.patch'

function Build-Harness([string] $Name, [string] $Overlay)
{
    $exe = Join-Path $work "$Name.exe"
    & cl.exe /nologo /EHsc /std:c++20 /O2 /W4 /WX "/I$Overlay" "/I$BoostRoot" $source "/Fe:$exe" "/Fo:$work/$Name.obj" ws2_32.lib mswsock.lib | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "Failed to compile $Name" }
    return $exe
}

function Run-Harness([string] $Exe, [string] $Mode, [int] $Timeout, [bool] $MustTimeout = $false)
{
    $out = Join-Path $work 'stdout.txt'
    $err = Join-Path $work 'stderr.txt'
    $process = Start-Process -FilePath $Exe -ArgumentList $Mode -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    $finished = $process.WaitForExit($Timeout)
    if (!$finished)
    {
        $process.Kill()
        $process.WaitForExit()
        if (!$MustTimeout) { throw "$Mode exceeded $Timeout ms" }
        Write-Host 'Unpatched dropped-wakeup shutdown remained blocked, as expected.'
    }
    else
    {
        if ($MustTimeout) { throw 'Unpatched fault harness unexpectedly finished; regression was not reproduced.' }
        if ($process.ExitCode -ne 0) { throw "$Mode failed: $(Get-Content $err -Raw)" }
        Get-Content $out
    }
}

# Overlay only the two affected headers; never inject faults into production headers.
$faultOverlay = Join-Path $work 'fault'
New-Item -ItemType Directory -Force (Join-Path $faultOverlay 'boost/asio/detail/impl') | Out-Null
$interrupter = [IO.File]::ReadAllText((Join-Path $BoostRoot $interrupterRelative))
$send = 'socket_ops::send(write_descriptor_, &b, 1, 0, ec);'
if (!$interrupter.Contains($send)) { throw 'Interrupter fault injection no longer matches Boost.' }
[IO.File]::WriteAllText((Join-Path $faultOverlay $interrupterRelative), $interrupter.Replace($send, '(void)byte; (void)b; (void)ec; // Fault injection: drop the wake-up.'))
Copy-Item (Join-Path $BoostRoot $reactorRelative) (Join-Path $faultOverlay $reactorRelative)
& git -C $faultOverlay apply --reverse $patch
if ($LASTEXITCODE -ne 0) { throw 'Cannot construct unpatched baseline.' }
$baseline = Build-Harness 'baseline-fault' $faultOverlay
Run-Harness $baseline 'fault' 3000 $true

Copy-Item (Join-Path $BoostRoot $reactorRelative) (Join-Path $faultOverlay $reactorRelative) -Force
$fixed = Build-Harness 'patched-fault' $faultOverlay
1..5 | ForEach-Object { Run-Harness $fixed 'fault' 2000 }
$normal = Build-Harness 'patched-normal' $BoostRoot
1..5 | ForEach-Object { Run-Harness $normal 'normal' 2000 }
Run-Harness $normal 'idle' 5000
