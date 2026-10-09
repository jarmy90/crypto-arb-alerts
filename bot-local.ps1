# Bot local: escanea Binance+MEXC+Bybit+OKX y guarda en data/alerts.json + data/live.json. Sin GitHub.
param([switch]$Once)
Set-Location $PSScriptRoot
function Get-Cfg($map,$k,$d){ if($map.ContainsKey($k)-and $map[$k]){return $map[$k]} else{return $d} }
$map=@{}
if(Test-Path ".env"){ Get-Content ".env" | ForEach-Object { $l=$_.Trim(); if($l -and -not $l.StartsWith("#") -and $l.Contains("=")){ $k,$v=$l.Split("=",2); $map[$k.Trim()]=$v.Trim() } } }
$MIN=[double](Get-Cfg $map "MIN_NET_SPREAD" "0.40"); $SIZE=[double](Get-Cfg $map "TRADE_SIZE_USDT" "500")
$FB=[double](Get-Cfg $map "FEE_BINANCE" "0.10"); $FM=[double](Get-Cfg $map "FEE_MEXC" "0.05"); $FY=[double](Get-Cfg $map "FEE_BYBIT" "0.10"); $FO=[double](Get-Cfg $map "FEE_OKX" "0.10")
$WAIT=[int](Get-Cfg $map "CHECK_INTERVAL" "8"); $COOL=[int](Get-Cfg $map "COOLDOWN_SECONDS" "90")
$MAXA=[int](Get-Cfg $map "MAX_ALERTS" "50")
$THIN=[double](Get-Cfg $map "THIN_BOOK_USDT" "1000")
$DINT=[int](Get-Cfg $map "DEPTH_INTERVAL" "30")
$MFB=[double](Get-Cfg $map "FEE_MAKER_BINANCE" "0.10"); $MFM=[double](Get-Cfg $map "FEE_MAKER_MEXC" "0.05"); $MFY=[double](Get-Cfg $map "FEE_MAKER_BYBIT" "0.10"); $MFO=[double](Get-Cfg $map "FEE_MAKER_OKX" "0.10")
$SAFE=[double](Get-Cfg $map "SAFETY_MARGIN" "0.05")
$EXITMIN=[double](Get-Cfg $map "EXIT_MIN_USDT" "500")
$PERSIST=[int](Get-Cfg $map "PERSIST_READS" "2")
$MAXAGE=[int](Get-Cfg $map "MAX_DATA_AGE_S" "90")
$LAT=[double](Get-Cfg $map "LATENCY_RISK" "0.05")
$PRISK=[double](Get-Cfg $map "PARTIAL_FILL_RISK" "0.05")
$EVOLK=[double](Get-Cfg $map "EXITVOL_K" "1.0")
$SIZES=((Get-Cfg $map "TRADE_SIZES" "25,50,100,250,500,1000").Split(",") | ForEach-Object { [double]$_.Trim() })
$PRESIG_MS=[int](Get-Cfg $map "PRE_SIGNAL_MIN_MS" "2000")
$PREP_MS=[int](Get-Cfg $map "PREPARE_MIN_MS" "4000")
$GAP_MS=[int](Get-Cfg $map "MAX_SIGNAL_GAP_MS" "1000")
$GAPSCAN_S=[int](Get-Cfg $map "MAX_SIGNAL_GAP_S" "300")
$NEAR=[double](Get-Cfg $map "NEAR_BAND" "0.10")
$QMAXAGE_MS=[int](Get-Cfg $map "DATA_MAX_AGE_MS" "2000")
$SYNCMAX_MS=[int](Get-Cfg $map "SYNC_MAX_AGE_MS" "1500")
$TFB=[double](Get-Cfg $map "FEE_TAKER_BINANCE" ([string]$FB)); $TFM=[double](Get-Cfg $map "FEE_TAKER_MEXC" ([string]$FM)); $TFY=[double](Get-Cfg $map "FEE_TAKER_BYBIT" ([string]$FY)); $TFO=[double](Get-Cfg $map "FEE_TAKER_OKX" ([string]$FO))
$FVB=[int](Get-Cfg $map "FEE_VERIFIED_BINANCE" "0"); $FVM=[int](Get-Cfg $map "FEE_VERIFIED_MEXC" "0"); $FVY=[int](Get-Cfg $map "FEE_VERIFIED_BYBIT" "0"); $FVO=[int](Get-Cfg $map "FEE_VERIFIED_OKX" "0")
$lastDepth=[DateTime]::MinValue
$hist=@{}
. (Join-Path $PSScriptRoot "depth-common.ps1")
. (Join-Path $PSScriptRoot "markets-common.ps1")
$SYMS=(Get-Cfg $map "SYMBOLS" "BTC/USDT,ETH/USDT,BNB/USDT,SOL/USDT,XRP/USDT,ADA/USDT,DOGE/USDT").Split(",") | ForEach-Object{$_.Trim()}
$BASES=$SYMS | ForEach-Object { $_.Split("/")[0] } | Sort-Object -Unique
$QUOTES=@("USDT","USDC")
$script:markets=$null; $script:marketsTs=[DateTime]::MinValue
function Update-Markets($push){
  $cat=Get-CatalogAll
  $bg=Build-Groups $cat $BASES $QUOTES
  $pr=Select-Principal $bg.groups
  $script:markets=[ordered]@{updated=([DateTime]::UtcNow.ToString("o")); ver=$COMMON_VERSION; quotes=$QUOTES; principal=$pr; groups=$bg.groups; suspended=$bg.suspended}
  $script:markets | ConvertTo-Json -Depth 6 | Set-Content "data/markets.json" -Encoding UTF8
  $script:marketsTs=Get-Date
  Write-Host "Mercados: $(($bg.groups | Where-Object { $_.members.Count -ge 2 }).Count) grupos con 2+ exchanges, $($bg.suspended.Count) suspendidos"
}
$last=@{}
if(-not (Test-Path "data")){ New-Item -ItemType Directory data | Out-Null }
function Save-Local($a){
  $f="data/alerts.json"; $cur=@()
  if(Test-Path $f){ try{$c=Get-Content $f -Raw | ConvertFrom-Json; $cur=@($c)}catch{$cur=@()} }
  $list=@($a)+@($cur) | Select-Object -First $MAXA
  if($list.Count -eq 1){ "["+($list|ConvertTo-Json -Depth 5)+"]" | Set-Content $f -Encoding UTF8 }
  else { $list | ConvertTo-Json -Depth 5 | Set-Content $f -Encoding UTF8 }
}
function Get-TradeUrl($ex,$sym){
  $uf=$sym.Replace("/","_"); $parts=$sym.Split("/"); $base=$parts[0]; $quote=$parts[1]
  if($ex -eq "BINANCE"){ return "https://www.binance.com/en/trade/${uf}?type=spot" }
  if($ex -eq "MEXC"){ return "https://www.mexc.com/exchange/${uf}" }
  if($ex -eq "BYBIT"){ return "https://www.bybit.com/en/trade/spot/${base}/${quote}" }
  return "https://www.okx.com/trade-spot/$($base.ToLower())-$($quote.ToLower())"
}
$n=0
$botStarted=[DateTime]::UtcNow
$script:tickerTs=$null; $script:depthTs=$null; $script:tradesTs=$null
$script:cycleId="c0"; $script:cycleMs=$null
$script:exStat=@{BINANCE=@{ok=0;fail=0};MEXC=@{ok=0;fail=0};BYBIT=@{ok=0;fail=0};OKX=@{ok=0;fail=0}}
do{
  $n++
  $script:cycleId="c$($botStarted.ToString('yyyyMMddHHmmss'))-#$n"
  $script:exStat=@{BINANCE=@{ok=0;fail=0};MEXC=@{ok=0;fail=0};BYBIT=@{ok=0;fail=0};OKX=@{ok=0;fail=0}}
  $sw=[Diagnostics.Stopwatch]::StartNew()
  Write-Host "`n--- Ciclo $script:cycleId $([DateTime]::UtcNow.ToString('HH:mm:ss')) UTC ---"
  if($script:markets -eq $null -or ((Get-Date)-$script:marketsTs).TotalHours -ge 6){ Update-Markets $false }
  $fees=@{BINANCE=$TFB;MEXC=$TFM;BYBIT=$TFY;OKX=$TFO}
  $live=@()
  foreach($grp in $script:markets.groups){
    $sym=$grp.normalized
    if($last.ContainsKey($sym) -and ((Get-Date)-$last[$sym]).TotalSeconds -lt $COOL){continue}
    $pxn=Get-PricesNative $grp.members
    foreach($ex in $grp.members.Keys){ if($pxn.ContainsKey($ex)){ $script:exStat[$ex].ok++ } else { $script:exStat[$ex].fail++ } }
    $px=@{}
    foreach($ex in $pxn.Keys){ if($pxn[$ex].ask -gt 0 -and $pxn[$ex].bid -gt 0){ $px[$ex]=@{bid=[double]$pxn[$ex].bid; ask=[double]$pxn[$ex].ask; fee=$fees[$ex]} } }
    $row=[ordered]@{symbol=$sym; base=$grp.base; quote=$grp.quote; principal=($script:markets.principal[$grp.base] -eq $grp.quote)}
    foreach($ex in @("BINANCE","MEXC","BYBIT","OKX")){
      $k=$ex.ToLower()
      if($px.ContainsKey($ex)){ $row["${k}_bid"]=$px[$ex].bid; $row["${k}_ask"]=$px[$ex].ask }
      else { $row["${k}_bid"]=$null; $row["${k}_ask"]=$null }
    }
    $bestN=-999; $bx=""; $sx=""; $bp=0; $sp=0; $gross=0
    foreach($be in $px.Keys){ foreach($se in $px.Keys){ if($be -eq $se){continue}
      $g=(($px[$se].bid-$px[$be].ask)/$px[$be].ask*100); $nn=Compute-Net $px[$be].ask $px[$se].bid $px[$be].fee $px[$se].fee 0 0
      if($nn -gt $bestN){ $bestN=$nn; $bx=$be; $sx=$se; $bp=$px[$be].ask; $sp=$px[$se].bid; $gross=$g; $fb=$px[$be].fee; $fs=$px[$se].fee }
    }}
    if($px.Count -ge 2){ $row.best=[Math]::Round($bestN,4); $row.best_buy=$bx; $row.best_sell=$sx }
    else { $row.best=$null; $row.best_buy=$null; $row.best_sell=$null }
    $live+=$row
    if($px.Count -ge 2 -and $bestN -ge $MIN){
      $amt=$SIZE/$bp; $profit=($amt*(1-$fb/100)*$sp*(1-$fs/100))-$SIZE
      $a=[ordered]@{symbol=$sym; base=$grp.base; quote=$grp.quote; buy_exchange=$bx; sell_exchange=$sx; buy_native=$grp.members[$bx]; sell_native=$grp.members[$sx]; buy_price=[Math]::Round($bp,8);sell_price=[Math]::Round($sp,8);gross_spread=[Math]::Round($gross,2);net_spread=[Math]::Round($bestN,2);estimated_profit=[Math]::Round($profit,2);timestamp=([DateTime]::UtcNow.ToString("o"));pair_urls=@{buy=(Get-TradeUrl $bx $sym);sell=(Get-TradeUrl $sx $sym)}}
      Write-Host "  OPORTUNIDAD $sym | $bx -> $sx | Neto $([Math]::Round($bestN,2))% | +`$$([Math]::Round($profit,2))" -ForegroundColor Green
      Save-Local $a; $last[$sym]=Get-Date
    }
  }
  Write-Host "Fin scan #$n. Guardado en data/alerts.json"
  @{ updated=([DateTime]::UtcNow.ToString("o")); ver=$COMMON_VERSION; ticker_updated_at=([DateTime]::UtcNow.ToString("o")); cycle_id=$script:cycleId; bot_heartbeat_at=([DateTime]::UtcNow.ToString("o")); symbols=$live } | ConvertTo-Json -Depth 5 | Set-Content "data/live.json" -Encoding UTF8
  $script:tickerTs=([DateTime]::UtcNow.ToString("o"))
  if(((Get-Date)-$lastDepth).TotalSeconds -ge $DINT){
    $lastDepth=Get-Date; $depth=@(); $books=@()
    $cfg=@{MIN=$MIN; SIZE=$SIZE; THIN=$THIN; SAFE=$SAFE; EXITMIN=$EXITMIN; PERSIST=$PERSIST; LAT=$LAT; PRISK=$PRISK; EVOLK=$EVOLK; SIZES=$SIZES; PRESIG_MS=$PRESIG_MS; PREP_MS=$PREP_MS; GAP_MS=$GAP_MS; GAPSCAN_S=$GAPSCAN_S; NEAR=$NEAR; QMAXAGE_MS=$QMAXAGE_MS; SYNCMAX_MS=$SYNCMAX_MS; FEESV=@{BINANCE=$FVB;MEXC=$FVM;BYBIT=$FVY;OKX=$FVO}; MF=@{BINANCE=$MFB;MEXC=$MFM;BYBIT=$MFY;OKX=$MFO}; TF=@{BINANCE=$TFB;MEXC=$TFM;BYBIT=$TFY;OKX=$TFO}}
    $now=Get-Date; $trN=0; $trO=0
    foreach($grp in $script:markets.groups){
      $sym=$grp.normalized
      $bk=Get-DepthAllNative $grp.members 20
      if($bk.Count -lt 2){ continue }
      $ginfo=[ordered]@{base=$grp.base; quote=$grp.quote; normalized=$grp.normalized; natives=$grp.members}
      $ev=Eval-Depth $sym $bk $cfg $hist $now ${function:Get-TradeUrl} $ginfo
      $books+=$ev.booksRow; $trN+=$ev.tradesN; $trO+=$ev.tradesOk
      foreach($sig in $ev.signals){
        $depth+=$sig
        if($sig.state -eq "POSIBLE FILL" -or $sig.state -eq "POSIBLE FILL PARCIAL"){
          $f=[ordered]@{symbol=$sig.symbol; buy_exchange=$(if($sig.model -eq "A"){$sig.maker_exchange}else{$sig.exit_exchange}); sell_exchange=$(if($sig.model -eq "A"){$sig.exit_exchange}else{$sig.maker_exchange}); buy_price=$(if($sig.model -eq "A"){$sig.limit_price}else{$sig.exit_price}); sell_price=$(if($sig.model -eq "A"){$sig.exit_price}else{$sig.limit_price}); gross_spread=$sig.gross; net_spread=$sig.net; estimated_profit=[Math]::Round($sig.net/100*$SIZE,2); timestamp=$sig.timestamp; pair_urls=$sig.pair_urls; kind="fill"; state=$sig.state}
          Save-Local $f; $last[$sym]=Get-Date
          Write-Host "  $($sig.state) $sym $($sig.type) $($sig.maker_exchange) -> $($sig.exit_exchange) neto $($sig.net)% ev=$($sig.evidence)" -ForegroundColor Yellow
        }
        elseif($sig.state -eq "PREPARAR"){ Write-Host "  PREPARAR $sym $($sig.type) $($sig.maker_exchange) @ $($sig.limit_price) -> $($sig.exit_exchange) $($sig.exit_price) neto $($sig.net)% fill~$($sig.est_fill_s)s" -ForegroundColor Cyan }
      }
    }
    @{ updated=([DateTime]::UtcNow.ToString("o")); ver=$COMMON_VERSION; depth_updated_at=([DateTime]::UtcNow.ToString("o")); cycle_id=$script:cycleId; bot_heartbeat_at=([DateTime]::UtcNow.ToString("o")); thin_usdt=$THIN; safety=$SAFE; persist_reads=$PERSIST; trade_usdt=$SIZE; trades_feeds="$trO/$trN"; signals=$depth; books=$books } | ConvertTo-Json -Depth 9 | Set-Content "data/depth.json" -Encoding UTF8
    $script:depthTs=([DateTime]::UtcNow.ToString("o"))
    try{ $tp=Invoke-RestMethod "https://api.binance.com/api/v3/trades?symbol=BTCUSDT&limit=1" -TimeoutSec 10; if($tp){ $script:tradesTs=([DateTime]::UtcNow.ToString("o")) } }catch{}
    Write-Host "Depth guardado ($($depth.Count) senales, trades $trO/$trN)"
  }
  $sw.Stop(); $script:cycleMs=$sw.ElapsedMilliseconds
  [ordered]@{ver=$COMMON_VERSION; mode="local"; bot_started_at=$botStarted.ToString("o"); bot_heartbeat_at=([DateTime]::UtcNow.ToString("o")); ticker_updated_at=$script:tickerTs; depth_updated_at=$script:depthTs; trades_updated_at=$script:tradesTs; cycle_id=$script:cycleId; cycle_duration_ms=$script:cycleMs; bot_status="RUNNING"; timestamp=([DateTime]::UtcNow.ToString("o"))} | ConvertTo-Json -Depth 5 | Set-Content "data/status.json" -Encoding UTF8
  $eok=($script:exStat.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value.ok)ok/$($_.Value.fail)fail" }) -join " "
  Write-Host "Fin ciclo $($script:cycleId) en $($script:cycleMs) ms UTC $([DateTime]::UtcNow.ToString('HH:mm:ss')) | $eok"
  if($Once){break}
  Start-Sleep -Seconds $WAIT
}while($true)
