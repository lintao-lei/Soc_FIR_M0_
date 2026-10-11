$ErrorActionPreference = 'Stop'

$repoDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$errors = New-Object 'System.Collections.Generic.List[string]'

$required = @(
    'README.md',
    'rtl\soc\soc_top.v',
    'rtl\soc\soc_fabric_shell.v',
    'rtl\sram\axi_burst_sram.v',
    'rtl\fir\fir_81tap_core.v',
    'rtl\dma\dma6_core.v',
    'rtl\dma\dma_test.v',
    'rtl\dma\dma_register_config.v',
    'rtl\dma\dma_configured_core.v',
    'rtl\uart\apb_uart.v',
    'sw\apps\dma_six_scenario\main.c',
    'sim\run_competition_acceptance.ps1',
    'verification\results\competition_acceptance_summary.txt'
)

foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoDir $relative))) {
        $errors.Add("Missing required file: $relative")
    }
}

$forbiddenDirectories = @(
    '.Xil', 'xsim.dir', 'Soc_FIR_M0_framework.cache',
    'Soc_FIR_M0_framework.runs', 'Soc_FIR_M0_framework.sim',
    'Soc_FIR_M0_framework.srcs'
)
foreach ($name in $forbiddenDirectories) {
    if (Get-ChildItem -LiteralPath $repoDir -Directory -Recurse -Force |
        Where-Object Name -EQ $name) {
        $errors.Add("Generated directory must not be published: $name")
    }
}

$finalTestbenches = @(Get-ChildItem -LiteralPath (Join-Path $repoDir 'sim') `
    -Recurse -File | Where-Object {
        $_.Name -like 'tb_*.v' -or $_.Name -like 'tb_*.sv'
    })
if ($finalTestbenches.Count -ne 11) {
    $errors.Add("Expected exactly 11 final testbenches, found $($finalTestbenches.Count)")
}

$armRestricted = Get-ChildItem -LiteralPath `
    (Join-Path $repoDir 'rtl\cortex_m0\vendor') -File -Filter '*.v'
if ($armRestricted.Count -ne 0) {
    $errors.Add('License-restricted ARM vendor Verilog is present in the public package.')
}

if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Release check PASS"
Write-Host "Repository: $repoDir"
Write-Host "Final testbenches: $($finalTestbenches.Count)"
Write-Host "Restricted ARM RTL included: no"

