param(
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $projectRoot "reports/ddr3_controller/vc707_phy_audit.log"
}

$sourceFiles = Get-ChildItem -LiteralPath (Join-Path $projectRoot "src"), (Join-Path $projectRoot "constraints") `
    -Recurse -File | Where-Object { $_.Extension -in ".sv", ".v", ".xdc" }
$primitivePattern = '\b(OSERDESE2|ISERDESE2|IDELAYE2|ODELAYE2|IDELAYCTRL)\b'
$physicalPortPattern = '\bddr3_(dq|dqs|ck|addr|ba|ras|cas|we|cke|odt|reset|dm)\w*\b'

$primitiveMatches = @($sourceFiles | Select-String -Pattern $primitivePattern -CaseSensitive:$false)
$physicalPortMatches = @($sourceFiles | Select-String -Pattern $physicalPortPattern -CaseSensitive:$false)
$xdcPath = Join-Path $projectRoot "constraints/dma_mmu_picorv32_vc707.xdc"
$xdcDdrMatches = @(Select-String -LiteralPath $xdcPath -Pattern $physicalPortPattern -CaseSensitive:$false)
$socPath = Join-Path $projectRoot "src/SoC/dma_mmu_picorv32_soc.sv"
$disabledDefault = @(Select-String -LiteralPath $socPath `
    -Pattern "parameter\s+bit\s+ENABLE_DDR3\s*=\s*1'b0")

$result = @(
    "VC707 DDR3 PHYSICAL INTERFACE AUDIT"
    "Source roots: src, constraints"
    "PHY primitive matches: $($primitiveMatches.Count)"
    "Physical DDR3 signal matches: $($physicalPortMatches.Count)"
    "VC707 XDC DDR3 constraint matches: $($xdcDdrMatches.Count)"
    "ENABLE_DDR3 disabled-default matches: $($disabledDefault.Count)"
    ""
    "Conclusion: the custom AXI DDR3 digital controller is present, but the"
    "VC707 x64 DDR3 pin PHY, calibration/training datapath and DDR pin XDC are"
    "not present. A physical-SODIMM bitstream is therefore not demonstrated."
)

$reportDirectory = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
$result | Set-Content -LiteralPath $ReportPath -Encoding utf8
$result | ForEach-Object { Write-Output $_ }

if (($primitiveMatches.Count -ne 0) -or
    ($physicalPortMatches.Count -ne 0) -or
    ($xdcDdrMatches.Count -ne 0) -or
    ($disabledDefault.Count -ne 1)) {
    throw "The VC707 DDR3 physical-interface status changed; review this audit and documentation."
}
