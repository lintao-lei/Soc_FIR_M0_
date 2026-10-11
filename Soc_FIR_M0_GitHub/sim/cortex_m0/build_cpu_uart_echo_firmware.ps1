$ErrorActionPreference = 'Stop'

$taskDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent (Split-Path -Parent $taskDir)
if ($env:ARM_GNU_BIN) {
    $toolDir = $env:ARM_GNU_BIN
} else {
    $gccCommand = Get-Command 'arm-none-eabi-gcc.exe' -ErrorAction SilentlyContinue
    if ($null -eq $gccCommand) {
        throw 'Arm GNU Toolchain not found. Set ARM_GNU_BIN or add arm-none-eabi-gcc.exe to PATH.'
    }
    $toolDir = Split-Path -Parent $gccCommand.Source
}
$compiler = Join-Path $toolDir 'arm-none-eabi-gcc.exe'
$objcopy = Join-Path $toolDir 'arm-none-eabi-objcopy.exe'
$objdump = Join-Path $toolDir 'arm-none-eabi-objdump.exe'
$linker = Join-Path $projectDir 'sw\linker\soc_cm0.ld'
$includeDir = Join-Path $projectDir 'sw\include'
$source = Join-Path $projectDir 'sw\apps\uart_echo\main.c'
$uartDriver = Join-Path $projectDir 'sw\drivers\uart.c'
$outputDir = $taskDir
$elf = Join-Path $outputDir 'cpu_uart_echo.elf'
$binary = Join-Path $outputDir 'cpu_uart_echo.bin'
$hex = Join-Path $outputDir 'uart_echo_firmware.hex'
$disassembly = Join-Path $outputDir 'cpu_uart_echo.dis'

foreach ($needed in @($compiler, $objcopy, $objdump, $linker,
                       $source, $uartDriver)) {
    if (-not (Test-Path -LiteralPath $needed)) {
        throw "Missing build input: $needed"
    }
}

& $compiler -mcpu=cortex-m0 -mthumb -Os -ffreestanding -fno-builtin `
    -fno-stack-protector -fno-lto -fno-use-linker-plugin `
    -nostdlib -nostartfiles "-I$includeDir" `
    '-Wl,--gc-sections' "-Wl,-T,$linker" -o $elf $source $uartDriver
if ($LASTEXITCODE -ne 0) { throw 'ARM C compile/link failed.' }

& $objcopy -O binary $elf $binary
if ($LASTEXITCODE -ne 0) { throw 'objcopy binary conversion failed.' }
& $objdump -d $elf | Out-File -LiteralPath $disassembly -Encoding ascii
if ($LASTEXITCODE -ne 0) { throw 'objdump failed.' }

[byte[]]$bytes = [System.IO.File]::ReadAllBytes($binary)
if ($bytes.Length -lt 8) { throw 'Firmware does not contain a vector table.' }
$words = New-Object 'System.Collections.Generic.List[string]'
for ($offset = 0; $offset -lt $bytes.Length; $offset += 4) {
    [uint32]$word = 0
    for ($lane = 0; $lane -lt 4; $lane++) {
        if (($offset + $lane) -lt $bytes.Length) {
            $word = $word -bor ([uint32]$bytes[$offset + $lane] -shl (8 * $lane))
        }
    }
    $words.Add($word.ToString('X8'))
}
[System.IO.File]::WriteAllLines($hex, $words, [System.Text.Encoding]::ASCII)

if ($words[0] -ne '20010000') { throw 'Unexpected initial stack pointer.' }
if (([Convert]::ToUInt32($words[1], 16) -band 1) -eq 0) {
    throw 'Reset vector Thumb bit is not set.'
}

Write-Output "Built $hex ($($words.Count) 32-bit words)"
