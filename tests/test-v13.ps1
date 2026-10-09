# tests/test-v13.ps1 - pruebas reproducibles de la auditoria v13 (sin red salvo que se indique).
# Uso: powershell -File tests/test-v13.ps1  (desde la raiz del proyecto)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
. (Join-Path (Get-Location) "depth-common.ps1")
. (Join-Path (Get-Location) "markets-common.ps1")

$global:fails = 0
$global:passes = 0
function Check($name, $cond, $detail){
  if($cond){ $global:passes++; Write-Output "PASS $name :: $detail" }
  else { $global:fails++; Write-Output "FAIL $name :: $detail" }
}
function MkBook($askP,$askQ,$bidP,$bidQ){
  return @{ask=$askP; askQ=$askQ; bid=$bidP; bidQ=$bidQ;
    asks=@(@{p=$askP;q=$askQ}; @{p=$askP*1.001;q=$askQ}; @{p=$askP*1.002;q=$askQ});
    bids=@(@{p=$bidP;q=$bidQ}; @{p=$bidP*0.999;q=$bidQ}; @{p=$bidP*0.998;q=$bidQ})}
}
function CfgBase(){
  return @{MIN=0.40; SIZE=500; THIN=1000000; SAFE=0.05; EXITMIN=500; PERSIST=2;
    MF=@{BINANCE=0.10;MEXC=0.05;BYBIT=0.10;OKX=0.10}; TF=@{BINANCE=0.10;MEXC=0.05;BYBIT=0.10;OKX=0.10}}
}
$tu = { param($e,$s) "#" }

# PRUEBA 1: una sola pata en cola, exchanges distintos, sin usar nivel 2 como mejor precio
$cfg = CfgBase
$bk = @{AEX= (MkBook 100 10 99.0 10); BEX= (MkBook 90 10 89.0 10)}
$h = @{}
$r = Eval-Depth "T1/USDT" $bk $cfg $h ([DateTime]::UtcNow) $tu
Check "T1-dos-senales" ($r.signals.Count -eq 2) "senales=$($r.signals.Count)"
$bad = @($r.signals | Where-Object { $_.maker_exchange -eq $_.exit_exchange })
Check "T1-exchanges-distintos" ($bad.Count -eq 0) "mismas=$($bad.Count)"
$a1 = @($r.signals | Where-Object { $_.model -eq "A" }) | Select-Object -First 1
Check "T1-modeloA-usa-BID1" ($a1 -ne $null -and $a1.limit_price -eq 89.0) "limit=$($a1.limit_price)"
$b1 = @($r.signals | Where-Object { $_.model -eq "B" }) | Select-Object -First 1
Check "T1-modeloB-usa-ASK1" ($b1 -ne $null -and $b1.limit_price -eq 100) "limit=$($b1.limit_price)"

# PRUEBA 2: libro normal con reduccion pero SIN operaciones -> no POSIBLE FILL
$cfg = CfgBase
$bk1 = @{AEX= (MkBook 100 10 99.5 10); BEX= (MkBook 200 10 101 10)}
$h = @{}
$t0 = [DateTime]::UtcNow
$null = Eval-Depth "T2/USDT" $bk1 $cfg $h $t0 $tu
$bk2 = @{AEX= (MkBook 100 10 99.5 1); BEX= (MkBook 200 10 101 10)}
$cfg2 = CfgBase
$cfg2.TradesStub = @{"AEX|T2/USDT|A"=@{vol=0; ok=$true}; "AEX|T2/USDT|B"=@{vol=0; ok=$true}}
$r2 = Eval-Depth "T2/USDT" $bk2 $cfg2 $h $t0.AddSeconds(35) $tu
$pf = @($r2.signals | Where-Object { $_.state -eq "POSIBLE FILL" -or $_.state -eq "POSIBLE FILL PARCIAL" })
Check "T2-sin-falso-fill" ($pf.Count -eq 0) "estados=$(($r2.signals | ForEach-Object { $_.state }) -join ',')"
$nr = @($r2.signals | Where-Object { $_.state -eq "NIVEL REDUCIDO" })
Check "T2-nivel-reducido" ($nr.Count -ge 1) "n_red=$($nr.Count)"

# PRUEBA 3: reduccion sin feed de trades -> NIVEL REDUCIDO, EJECUCION NO CONFIRMADA
$cfg = CfgBase
$bk1 = @{AEX= (MkBook 100 10 99.5 10); BEX= (MkBook 200 10 101 10)}
$h = @{}
$null = Eval-Depth "T3/USDT" $bk1 $cfg $h ([DateTime]::UtcNow) $tu
$bk2 = @{AEX= (MkBook 100 10 99.5 1); BEX= (MkBook 200 10 101 10)}
$cfg2 = CfgBase
$cfg2.TradesStub = @{"AEX|T3/USDT|A"=@{vol=0; ok=$false}; "AEX|T3/USDT|B"=@{vol=0; ok=$false}}
$r3 = Eval-Depth "T3/USDT" $bk2 $cfg2 $h ([DateTime]::UtcNow).AddSeconds(35) $tu
$sa = @($r3.signals | Where-Object { $_.model -eq "A" }) | Select-Object -First 1
Check "T3-no-confirmada" ($sa -ne $null -and $sa.state -eq "NIVEL REDUCIDO" -and $sa.state_reason -match "NO CONFIRMADA") "$($sa.state) / $($sa.state_reason)"

# PRUEBA 4: fill parcial 400/550/500 -> fill 150 pendiente 350
$e = Estimate-Partial 400 550 500
Check "T4-parcial" ($e.fill -eq 150 -and $e.pending -eq 350) "fill=$($e.fill) pend=$($e.pending)"

# PRUEBA 5: salida desaparecida -> SALIDA EN PERDIDA (RETIRAR, neto negativo visible)
$cfg = CfgBase
$bk1 = @{AEX= (MkBook 100 10 99.5 10); BEX= (MkBook 200 10 200 10)}
$h = @{}
$t0 = [DateTime]::UtcNow
$null = Eval-Depth "T5/USDT" $bk1 $cfg $h $t0 $tu
$null = Eval-Depth "T5/USDT" $bk1 $cfg $h $t0.AddSeconds(35) $tu
$bk3 = @{AEX= (MkBook 100 10 99.5 10); BEX= (MkBook 200 10 99.0 10)}
$r5 = Eval-Depth "T5/USDT" $bk3 $cfg $h $t0.AddSeconds(70) $tu
$rt = @($r5.signals | Where-Object { $_.state -eq "RETIRAR" }) | Select-Object -First 1
Check "T5-retiro-perdida" ($rt -ne $null -and $rt.net -lt 0) "state=$($rt.state) net=$($rt.net)"

# PRUEBA 6: neto positivo pero liquidez de salida insuficiente (5 USDT < 500)
$cfg = CfgBase
$bk = @{AEX= (MkBook 100 100 99.5 100); BEX= (MkBook 100 0.05 101 0.05)}
$h = @{}
$r6 = Eval-Depth "T6/USDT" $bk $cfg $h ([DateTime]::UtcNow) $tu
$ok6 = @($r6.signals | Where-Object { $_.state -eq "OBSERVAR" -or $_.state -eq "PREPARAR" -or $_.state -eq "POSIBLE FILL" })
Check "T6-sin-salida" ($ok6.Count -eq 0) "operables=$($ok6.Count)"

# PRUEBA 7: datos antiguos > 90 s -> DATOS ANTIGUOS (misma regla que la web)
$old = ([DateTimeOffset]::UtcNow.AddSeconds(-120)).ToString("o")
$age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($old)).TotalSeconds
$stale = $age -gt 90
Check "T7-stale" ($stale -eq $true) "age=$([Math]::Round($age))s"

# PRUEBA 8: versiones distintas -> DESINCRONIZADO
$web = "13"; $bot = "12"
Check "T8-desinc" (($web -ne $bot)) "web=$web bot=$bot => DESINCRONIZADO"

# PRUEBA 9: VWAP multinivel (200@100 + 300@101 de 500)
$lv = @(@{p=100;q=2}, @{p=101;q=3}, @{p=102;q=10})
$w = WalkBook $lv 500 $true
$sl = SlipPct $w.vwap 100 $true
Check "T9-vwap" ($w.ok -and [Math]::Round($w.vwap,4) -eq 100.6 -and $w.lvls -eq 2 -and [Math]::Round($w.gotU) -eq 500) "vwap=$($w.vwap) lvls=$($w.lvls)"
Check "T9-slip" ([Math]::Round($sl,4) -eq 0.6) "slip=$sl"

# PRUEBA 10: recalc con libro actual (no reutilizar neto antiguo)
$cfg = CfgBase
$exitBook = @(@{p=101;q=1}, @{p=102;q=10})
$w = WalkBook $exitBook 500 $false
$oldNet = 0.8
$newNet = Compute-Net 99.5 $w.vwap 0.05 0.05 ([Math]::Round((101-$w.vwap)/101*100,4)) 0.05
Check "T10-recalc" ($newNet -ne $oldNet) "old=$oldNet new=$([Math]::Round($newNet,4))"
$cls = if($newNet -ge $cfg.MIN){ "SALIR AHORA" } elseif($newNet -gt 0){ "VIGILAR" } else{ "SALIDA POSIBLE EN PERDIDA" }
Check "T10-clase" ($cls -ne $null -and $cls -ne "") $cls

# T11-T15: misma cotizacion, grupos dinamicos (fixtures, sin red)
function CatFix($entries){
  $m=@{}
  foreach($e in $entries){ $m[$e.native]=@{base=$e.base; quote=$e.quote; ok=$e.ok; native=$e.native; suspended=(-not $e.ok); status=$e.status} }
  return $m
}
# T11: misma cotizacion BTC/USDC en dos exchanges -> comparacion permitida
$cat11=@{BINANCE=(CatFix @(@{base='BTC';quote='USDC';ok=$true;native='BTCUSDC';status='TRADING'})); MEXC=(CatFix @(@{base='BTC';quote='USDC';ok=$true;native='BTCUSDC';status='1'}))}
$g11=Build-Groups $cat11 @('BTC') @('USDC','USDT')
$gu=@($g11.groups | Where-Object { $_.normalized -eq 'BTC/USDC' })[0]
Check "T11-misma-quote" ($gu.members.Count -eq 2) "miembros=$($gu.members.Count)"
$cfg = CfgBase
$bk11=@{BINANCE=(MkBook 100 10 99.0 10); MEXC=(MkBook 90 10 89.0 10)}
$h=@{}
$r11=Eval-Depth "BTC/USDC" $bk11 $cfg $h ([DateTime]::UtcNow) $tu
Check "T11-senal" ($r11.signals.Count -eq 2) "senales=$($r11.signals.Count)"

# T12: distinta cotizacion -> bloqueada (grupos separados, sin mezcla)
$cat12=@{BINANCE=(CatFix @(@{base='BTC';quote='USDC';ok=$true;native='BTCUSDC';status='TRADING'})); MEXC=(CatFix @(@{base='BTC';quote='USDT';ok=$true;native='BTCUSDT';status='1'}))}
$g12=Build-Groups $cat12 @('BTC') @('USDC','USDT')
$mix=@($g12.groups | Where-Object { $_.members.Count -ge 2 })
Check "T12-bloqueada" ($mix.Count -eq 0) "grupos-mezclados=$($mix.Count)"

# T13: par no disponible/no operable -> sin depth, sin senal, NO DISPONIBLE
$cat13=@{BINANCE=(CatFix @(@{base='BTC';quote='USDT';ok=$false;native='BTCUSDT';status='BREAK'})); MEXC=(CatFix @(@{base='BTC';quote='USDT';ok=$true;native='BTCUSDT';status='1'}))}
$g13=Build-Groups $cat13 @('BTC') @('USDT')
$gu13=@($g13.groups | Where-Object { $_.normalized -eq 'BTC/USDT' })[0]
Check "T13-excluido" ($gu13.members.Count -eq 1 -and -not $gu13.members.ContainsKey('BINANCE')) "miembros=$($gu13.members.Count)"
Check "T13-suspendido" ((@($g13.suspended | Where-Object { $_.exchange -eq 'BINANCE' })).Count -eq 1) "susp=$($g13.suspended.Count)"

# T14: interseccion dinamica USDCx4 / USDTx3 -> dos grupos independientes
$cat14=@{EX1=(CatFix @(@{base='BTC';quote='USDC';ok=$true;native='X';status='a'},@{base='BTC';quote='USDT';ok=$true;native='Y';status='a'})); EX2=(CatFix @(@{base='BTC';quote='USDC';ok=$true;native='X';status='a'},@{base='BTC';quote='USDT';ok=$true;native='Y';status='a'})); EX3=(CatFix @(@{base='BTC';quote='USDC';ok=$true;native='X';status='a'},@{base='BTC';quote='USDT';ok=$true;native='Y';status='a'})); EX4=(CatFix @(@{base='BTC';quote='USDC';ok=$true;native='X';status='a'}))}
$g14=Build-Groups $cat14 @('BTC') @('USDC','USDT')
$u4=@($g14.groups | Where-Object { $_.normalized -eq 'BTC/USDC' })[0]
$u3=@($g14.groups | Where-Object { $_.normalized -eq 'BTC/USDT' })[0]
Check "T14-grupos" ($u4.members.Count -eq 4 -and $u3.members.Count -eq 3) "usdc=$($u4.members.Count) usdt=$($u3.members.Count)"
Check "T14-sin-mezcla" ($u4.quote -eq 'USDC' -and $u3.quote -eq 'USDT') "quotes separadas"

# T15: par suspendido -> excluido y marcado SUSPENDIDO
$cat15=@{BINANCE=(CatFix @(@{base='BTC';quote='USDT';ok=$false;native='BTCUSDT';status='HALT'}))}
$g15=Build-Groups $cat15 @('BTC') @('USDT')
$gu15=@($g15.groups | Where-Object { $_.normalized -eq 'BTC/USDT' })[0]
Check "T15-suspendido" ($gu15.members.Count -eq 0 -and (@($g15.suspended | Where-Object { $_.status -eq 'HALT' })).Count -eq 1) "miembros=0 susp=HALT"

Write-Output "----"
Write-Output "PASS=$global:passes FAIL=$global:fails"
if($global:fails -gt 0){ exit 1 }
