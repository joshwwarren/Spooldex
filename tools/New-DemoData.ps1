<#
.SYNOPSIS
    Writes a made-up Spooldex inventory (spools + ~2 months of prints) for demos and screenshots.
    Dates are relative to today so the demo always looks current.
#>
param([Parameter(Mandatory)][string]$Path)

$ErrorActionPreference = 'Stop'
$now = Get-Date

$spools = @(
    @{ id = 'demo1'; brand = 'Polymaker'; material = 'PLA';  colorName = 'Charcoal';     colorHex = '2B2B2B'; price = 19.99; key = 'PLA|2B2B2B'; spares = 2 }
    @{ id = 'demo2'; brand = 'Inland';    material = 'PLA+'; colorName = 'Neon Green';   colorHex = 'CCFF00'; price = 16.99; key = 'PLA|CCFF00'; spares = 1
       weighed = @{ grams = 330; at = $now.AddDays(-14).ToString('o') } }
    @{ id = 'demo3'; brand = 'eSun';      material = 'PETG'; colorName = 'Cool White';   colorHex = 'F4F4F4'; price = 18.99; key = 'PETG|F4F4F4' }
    @{ id = 'demo4'; brand = 'Inland';    material = 'Matte PLA'; colorName = 'Rainbow'; colorHex = 'D4B1DD'; price = 23.99; key = 'PLA|D4B1DD' }
    @{ id = 'demo5'; brand = 'Elegoo';    material = 'PLA';  colorName = 'Red';          colorHex = 'CC3333'; price = 15.99; key = 'PLA|CC3333' }
    @{ id = 'demo6'; brand = 'Polymaker'; material = 'Silk PLA'; colorName = 'Gold';     colorHex = 'D4AF37'; price = 24.99; key = 'PLA|D4AF37' }
) | ForEach-Object {
    $s = [ordered]@{
        id = $_.id; brand = $_.brand; material = $_.material; colorName = $_.colorName; colorHex = $_.colorHex
        startGrams = 1000; adjustGrams = 0; price = $_.price; matchKeys = @($_.key); status = 'active'
    }
    if ($_.weighed) { $s.weighed = $_.weighed }
    if ($_.spares) { $s.spares = $_.spares }
    [pscustomobject]$s
}

# days ago, title, filaments as "type|color|slot|grams", optional: failed after this fraction of the estimate
$plan = @(
    ,@(58, 'Calibration cube',    'PLA|2B2B2B|1|12')
    ,@(55, 'Cable clips x12',     'PLA|CC3333|3|18')
    ,@(52, 'Headphone stand',     'PLA|D4AF37|1|96')
    ,@(49, 'Filament swatch set', 'PLA|3B82F6|2|22')
    ,@(46, 'Desk organizer',      'PLA|2B2B2B|1|142')
    ,@(44, 'Spiral vase',         'PLA|D4AF37|1|61')
    ,@(41, 'Drawer labels',       'PLA|CC3333|3|9', 'PLA|2B2B2B|1|3')
    ,@(38, 'Self-watering pot',   'PLA|CCFF00|2|188')
    ,@(35, 'Hex bit holder',      'PLA|2B2B2B|1|54')
    ,@(33, 'Planter saucer',      'PLA|CCFF00|2|97')
    ,@(30, 'Dice tower',          'PLA|D4B1DD|4|118')
    ,@(27, 'Wall hooks x4',       'PETG|F4F4F4|3|36')
    ,@(25, 'Phone stand',         'PLA|CCFF00|2|71')
    ,@(22, 'Cable chain',         'PETG|F4F4F4|3|83')
    ,@(20, 'Keychain tags',       'PLA|D4B1DD|4|14', 'PLA|2B2B2B|1|5')
    ,@(17, 'Wrench holder',       'PLA|2B2B2B|1|110')
    ,@(15, 'Spool holder',        'PETG|F4F4F4|3|140')
    ,@(12, 'Pencil cup',          'PLA|D4B1DD|4|92')
    ,@(10, 'Name plate',          'PLA|CCFF00|2|38', 'PLA|2B2B2B|1|12')
    ,@(8,  'Socket tray',         'PLA|2B2B2B|1|126')
    ,@(6,  'Shelf bracket',       'PETG|F4F4F4|3|64', 0.25)
    ,@(4,  'Lamp shade',          'PLA|CCFF00|2|164')
    ,@(2,  'Mini planter',        'PLA|D4B1DD|4|45')
    ,@(1,  'Gridfinity bins',     'PLA|2B2B2B|1|98')
)

$prints = @()
$n = 0
foreach ($p in $plan) {
    $n++
    $failAt = ($p | Where-Object { $_ -is [double] }) | Select-Object -First 1
    $usages = @($p | Where-Object { $_ -is [string] -and $_ -match '\|' } | ForEach-Object {
        $type, $color, $slot, $grams = $_ -split '\|'
        [pscustomobject]@{ slot = [int]$slot; tray = [int]$slot - 1; type = $type; color = "${color}FF"; grams = [double]$grams }
    })
    $planned = ($usages | Measure-Object grams -Sum).Sum
    $est = [int]($planned * 55 + 600)                       # rough seconds for that much filament
    $start = $now.Date.AddDays(-$p[0]).AddHours(9 + ($n % 9))
    $ran = if ($failAt) { $est * $failAt } else { $est }
    $prints += [pscustomobject]@{
        id = "demo-print-$n"; title = $p[1]; device = 'A1 mini'
        start = $start.ToUniversalTime().ToString('o'); end = $start.AddSeconds($ran).ToUniversalTime().ToString('o')
        status = $(if ($failAt) { 'failed' } else { 'finished' }); statusRaw = $(if ($failAt) { 3 } else { 2 })
        plannedGrams = $planned; estSeconds = $est; usages = $usages; reviewed = $false
    }
}
[array]::Reverse($prints)

$db = [pscustomobject]@{
    version = 1; spools = @($spools); prints = @($prints); slotOverrides = [pscustomobject]@{}
    settings = [pscustomobject]@{ lowGrams = 150 }; lastSync = $now.ToString('o')
    lastSyncResult = [pscustomobject]@{ at = $now.ToString('o'); ok = $true; fetched = 0; added = 0; message = 'Demo data' }
}
[IO.File]::WriteAllText($Path, ($db | ConvertTo-Json -Depth 30 -Compress), (New-Object System.Text.UTF8Encoding $false))
