$ErrorActionPreference = 'Stop'

$projectDir = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $projectDir 'build\acceptance_logs'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$tests = @(
    [pscustomobject]@{
        Name = 'AXI SRAM single/4/8/16-beat and backpressure'
        Script = 'sim\sram\run_axi_burst_sram_acceptance.bat'
        Marker = 'TEST PASS'
    },
    [pscustomobject]@{
        Name = 'AXI SRAM invalid requests, WLAST errors and reset recovery'
        Script = 'sim\sram\run_axi_burst_sram_protocol_errors.bat'
        Marker = 'TEST PASS: AXI burst SRAM negative protocol cases'
    },
    [pscustomobject]@{
        Name = '81-tap FIR coefficients, random vectors, FIFO/backpressure'
        Script = 'sim\fir\run_fir_verification.bat'
        Marker = 'FIR VALIDATION RESULT: PASS'
    },
    [pscustomobject]@{
        Name = 'APB UART TX/RX FIFO full/empty behavior'
        Script = 'sim\uart\run_apb_uart_fifo.bat'
        Marker = 'TEST PASS: APB UART dual FIFO'
    },
    [pscustomobject]@{
        Name = 'Cortex-M0 polling UART echo'
        Script = 'sim\cortex_m0\run_soc_top_cpu_uart_echo.bat'
        Marker = 'TEST PASS: Cortex-M0 polling UART full echo regression'
    },
    [pscustomobject]@{
        Name = 'Six-channel DMA AXI register slave'
        Script = 'sim\dma\run_axi_dma6_reg_slave.bat'
        Marker = 'TEST PASS: six-channel AXI DMA register slave works'
    },
    [pscustomobject]@{
        Name = 'DMA INCR Burst, random backpressure, 4KiB split and errors'
        Script = 'sim\dma\run_dma_config_integration.bat'
        Marker = 'TEST PASS: DMA register-config integration'
    },
    [pscustomobject]@{
        Name = 'DMA 16-beat FIXED/INCR and UART beat conversion'
        Script = 'sim\dma\run_dma6_mixed_burst_16.bat'
        Marker = 'TEST PASS: DMA mixed Burst and UART beat conversion are correct'
    },
    [pscustomobject]@{
        Name = 'CPU/DMA continuous read contention fairness'
        Script = 'sim\interconnect\run_arbiter_fairness_stress.bat'
        Marker = 'TEST PASS:'
    },
    [pscustomobject]@{
        Name = 'CPU/DMA continuous write contention fairness'
        Script = 'sim\interconnect\run_arbiter_write_fairness_stress.bat'
        Marker = 'TEST PASS:'
    },
    [pscustomobject]@{
        Name = 'Full Cortex-M0 six-channel DMA/FIR/UART/SRAM IRQ scenario'
        Script = 'sim\cortex_m0\run_soc_top_cpu_dma6_scenario.bat'
        Marker = 'TEST PASS: Cortex-M0 completed the six-channel DMA scenario'
    }
)

$results = New-Object 'System.Collections.Generic.List[object]'
$index = 0

foreach ($test in $tests) {
    $index++
    $scriptPath = Join-Path $projectDir $test.Script
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Missing acceptance runner: $scriptPath"
    }

    $safeName = ('{0:d2}_{1}' -f $index,
                 ($test.Name -replace '[^A-Za-z0-9]+', '_').Trim('_'))
    $logPath = Join-Path $logDir ($safeName + '.log')

    Write-Host ("[{0}/{1}] RUN  {2}" -f $index, $tests.Count, $test.Name)
    $startTime = Get-Date
    $output = & cmd.exe /d /c ('"{0}"' -f $scriptPath) 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ($output | Out-String)
    [System.IO.File]::WriteAllText($logPath, $outputText,
                                   [System.Text.Encoding]::UTF8)
    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
    $markerFound = $outputText.Contains($test.Marker)
    $passed = ($exitCode -eq 0) -and $markerFound

    $results.Add([pscustomobject]@{
        Name = $test.Name
        Passed = $passed
        ExitCode = $exitCode
        MarkerFound = $markerFound
        Seconds = $elapsed
        Log = $logPath
    })

    if ($passed) {
        Write-Host ("[{0}/{1}] PASS {2} ({3}s)" -f
                    $index, $tests.Count, $test.Name, $elapsed)
    } else {
        Write-Host ("[{0}/{1}] FAIL {2}; exit={3}, marker={4}, log={5}" -f
                    $index, $tests.Count, $test.Name,
                    $exitCode, $markerFound, $logPath)
    }
}

$passedCount = @($results | Where-Object Passed).Count
$failedCount = $results.Count - $passedCount
$reportPath = Join-Path $logDir 'competition_acceptance_summary.txt'
$reportLines = New-Object 'System.Collections.Generic.List[string]'
$reportLines.Add('SoC FIR Cortex-M0 competition behavioral acceptance')
$reportLines.Add(('Generated: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
$reportLines.Add(('Passed: {0}/{1}' -f $passedCount, $results.Count))
$reportLines.Add('')

foreach ($result in $results) {
    $status = if ($result.Passed) { 'PASS' } else { 'FAIL' }
    $reportLines.Add(('[{0}] {1} ({2}s)' -f
                     $status, $result.Name, $result.Seconds))
    $reportLines.Add(('      log: {0}' -f $result.Log))
}

$reportLines.Add('')
$reportLines.Add('Not provable by behavioral simulation: FPGA timing >=25 MHz,')
$reportLines.Add('post-route timing closure, physical pin constraints, and board I/O.')
[System.IO.File]::WriteAllLines($reportPath, $reportLines,
                                [System.Text.Encoding]::UTF8)

Write-Host '------------------------------------------------------------'
Write-Host ("ACCEPTANCE SUMMARY: {0}/{1} PASS" -f
            $passedCount, $results.Count)
Write-Host ("Report: {0}" -f $reportPath)

if ($failedCount -ne 0) {
    exit 1
}
exit 0
