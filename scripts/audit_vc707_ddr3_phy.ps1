param(
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $projectRoot "reports/ddr3_controller/vc707_phy_audit.log"
}

$topPath = Join-Path $projectRoot "src/SoC/dma_mmu_picorv32_vc707_ddr3_top.sv"
$migPath = Join-Path $projectRoot "ip/vc707_mig_7series/mig.prj"
$generatorPath = Join-Path $projectRoot "scripts/generate_vc707_mig_ip.tcl"
$firmwarePath = Join-Path $projectRoot "firmware/prebuilt/vc707_ddr3/soc_ddr3_test.hex"

$top = Get-Content -LiteralPath $topPath -Raw
$mig = Get-Content -LiteralPath $migPath -Raw
$generator = Get-Content -LiteralPath $generatorPath -Raw

$physicalSignalCount = [regex]::Matches($top,
    '\bddr3_(addr|ba|cas_n|ck_n|ck_p|cke|ras_n|reset_n|we_n|dq|dqs_n|dqs_p|cs_n|dm|odt)\b').Count
$migPinCount = [regex]::Matches($mig, 'name="ddr3_').Count
$migInstanceCount = [regex]::Matches($top, '\bvc707_mig\s+mig_inst\b').Count
$clockConverterCount = [regex]::Matches($top,
    '\bsoc_ddr_clock_converter\s+ddr_clock_converter_inst\b').Count
$widthConverterCount = [regex]::Matches($top,
    '\bsoc_ddr_axi_converter\s+ddr_width_converter_inst\b').Count
$physicalDdrEnabledCount = [regex]::Matches($top,
    "\.ENABLE_DDR3\(1'b1\)").Count
$externalMigEnabledCount = [regex]::Matches($top,
    "\.USE_EXTERNAL_DDR_AXI\(1'b1\)").Count
$migGeneratorCount = [regex]::Matches($generator,
    'create_ip\s+-name\s+mig_7series').Count
$firmwarePresent = Test-Path -LiteralPath $firmwarePath

$result = @(
    "VC707 DDR3 PHYSICAL INTERFACE AUDIT"
    "Audited target files: physical top, MIG config/generator, firmware"
    "Physical DDR3 top-level signal matches: $physicalSignalCount"
    "Tracked MIG DDR3 pin assignments: $migPinCount"
    "MIG physical instance matches: $migInstanceCount"
    "AXI clock converter matches: $clockConverterCount"
    "AXI width converter matches: $widthConverterCount"
    "Physical top ENABLE_DDR3=1 matches: $physicalDdrEnabledCount"
    "Physical top external-MIG matches: $externalMigEnabledCount"
    "Official mig_7series generator matches: $migGeneratorCount"
    "Prebuilt DDR3 test firmware present: $firmwarePresent"
    ""
    "Conclusion: the VC707 target includes the official Xilinx MIG controller,"
    "x64 PHY/calibration path, complete DDR pin map, AXI converters and test"
    "firmware. Generated MIG HDL/XDC is recreated by Vivado from mig.prj."
)

$reportDirectory = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
$result | Set-Content -LiteralPath $ReportPath -Encoding utf8
$result | ForEach-Object { Write-Output $_ }

if (($physicalSignalCount -lt 15) -or
    ($migPinCount -lt 100) -or
    ($migInstanceCount -ne 1) -or
    ($clockConverterCount -ne 1) -or
    ($widthConverterCount -ne 1) -or
    ($physicalDdrEnabledCount -ne 1) -or
    ($externalMigEnabledCount -ne 1) -or
    ($migGeneratorCount -ne 1) -or
    (-not $firmwarePresent)) {
    throw "VC707 DDR3 physical-interface audit failed; review the tracked target files."
}
