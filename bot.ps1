# Crypto Arbitrage Detector - PowerShell version (sin Python)
param([switch]$Once)
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

function Load-Env {
  $envFile = Join-Path $PSScriptRoot ".env"
  $map = @{}
  if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
      $l = $_.Trim()
      if ($l -and -not $l.StartsWith("#") -and $l.Contains("=")) {
        $k,$v = $l.Split("=",2); $map[$k.Trim()] = $v.Trim()
      }
    }
  }
  return $map
}
$cfg = Load-Env
$TOKEN = $cfg["GITHUB_TOKEN"]
$REPO  = $cfg["GITHUB_REPO"]
function Get-Cfg($k, $d) { if ($cfg.ContainsKey($k) -and $cfg[$k]) { return $cfg[$k] } else { return $d } }
$MIN   = [double](Get-Cfg "MIN_NET_SPREAD" "0.40")
$SIZE  = [double](Get-Cfg "TRADE_SIZE_USDT" "500")
$FEE_B = [double](Get-Cfg "FEE_BINANCE" "0.10")
$FEE_M = [double](Get-Cfg "FEE_MEXC" "0.05")
$FEE_Y = [double](Get-Cfg "FEE_BYBIT" "0.10")
$FEE_O = [double](Get-Cfg "FEE_OKX" "0.10")
$WAIT  = [int](Get-Cfg "CHECK_INTERVAL" "8")
$COOL  = [int](Get-Cfg "COOLDOWN_SECONDS" "90")
$MAXA  = [int](Get-Cfg "MAX_ALERTS" "50")
$THIN  = [double](Get-Cfg "THIN_BOOK_USDT" "1000")
$DINT  = [int](Get-Cfg "DEPTH_INTERVAL" "30")
$MFB = [double](Get-Cfg "FEE_MAKER_BINANCE" "0.10"); $MFM = [double](Get-Cfg "FEE_MAKER_MEXC" "0.05"); $MFY = [double](Get-Cfg "FEE_MAKER_BYBIT" "0.10"); $MFO = [double](Get-Cfg "FEE_MAKER_OKX" "0.10")
$SAFE = [double](Get-Cfg "SAFETY_MARGIN" "0.05")
$EXITMIN = [double](Get-Cfg "EXIT_MIN_USDT" "500")
$PERSIST = [int](Get-Cfg "PERSIST_READS" "2")
$MAXAGE = [int](Get-Cfg "MAX_DATA_AGE_S" "90")
$lastDepth = [DateTime]::MinValue
$tracked = @{}
$hist = @{}
function WalkBook($levels, $sizeU, $isBuy){
  $gotU=0; $vwap=0
  foreach($l in $levels){
    $p=[double]$l.p; $q=[double]$l.q; $u=$p*$q
    $need=$sizeU-$gotU
    if($need -le 0){ break }
    $take=[Math]::Min($u,$need)
    $vwap+=($take/$sizeU)*$p
    $gotU+=$take
  }
  if($gotU -lt $sizeU){ return @{ok=$false; vwap=$null; gotU=$gotU} }
  return @{ok=$true; vwap=$vwap; gotU=$gotU}
}
function SlipPct($vwap, $l1, $isBuy){
  if($isBuy){ return ($vwap-$l1)/$l1*100 } else { return ($l1-$vwap)/$l1*100 }
}
function FindLvl($levels, $price){
  foreach($l in $levels){ if([double]$l.p -eq [double]$price){ return $l } }
  return $null
}
$PATHF = Get-Cfg "GITHUB_FILE_PATH" "data/alerts.json"
$SYMS  = (Get-Cfg "SYMBOLS" "BTC/USDT,ETH/USDT,BNB/USDT,SOL/USDT,XRP/USDT,ADA/USDT,DOGE/USDT").Split(",") | ForEach-Object { $_.Trim() }

$lastAlert = @{}
$H = @{ Authorization = "Bearer $TOKEN"; Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28"; "User-Agent" = "arb-bot-ps" }

function Get-Prices($sym) {
  $s = $sym.Replace("/",""); $oid = $sym.Replace("/","-")
  $b = $null; $m = $null; $yB = $null; $yA = $null; $oB = $null; $oA = $null
  try { $b = Invoke-RestMethod "https://api.binance.com/api/v3/ticker/bookTicker?symbol=$s" -TimeoutSec 10 } catch { Write-Host "  Binance $sym error: $($_.Exception.Message)" }
  try { $m = Invoke-RestMethod "https://api.mexc.com/api/v3/ticker/bookTicker?symbol=$s" -TimeoutSec 10 } catch { Write-Host "  MEXC $sym error: $($_.Exception.Message)" }
  try { $y = Invoke-RestMethod "https://api.bybit.com/v5/market/tickers?category=spot&symbol=$s" -TimeoutSec 10; $t=$y.result.list[0]; $yB=[double]$t.bid1Price; $yA=[double]$t.ask1Price } catch { Write-Host "  Bybit $sym error: $($_.Exception.Message)" }
  try { $o = Invoke-RestMethod "https://www.okx.com/api/v5/market/ticker?instId=$oid" -TimeoutSec 10; $d=$o.data[0]; $oB=[double]$d.bidPx; $oA=[double]$d.askPx } catch { Write-Host "  OKX $sym error: $($_.Exception.Message)" }
  return @{ B=$b; M=$m; YB=$yB; YA=$yA; OB=$oB; OA=$oA }
}
function MkLevels($rows, $n){
  $out=@()
  $c=0
  foreach($r in $rows){ if($c -ge $n){ break }; $out+=@{p=[double]$r[0]; q=[double]$r[1]}; $c++ }
  return $out
}
function Get-Depth($ex,$sym){
  $s=$sym.Replace("/",""); $oid=$sym.Replace("/","-")
  try{
    if($ex -eq "BINANCE"){ $d=Invoke-RestMethod "https://api.binance.com/api/v3/depth?symbol=$s&limit=5" -TimeoutSec 10; $a5=MkLevels $d.asks 5; $b5=MkLevels $d.bids 5; return @{ask=$a5[0].p; askQ=$a5[0].q; bid=$b5[0].p; bidQ=$b5[0].q; asks=$a5; bids=$b5} }
    if($ex -eq "MEXC"){ $d=Invoke-RestMethod "https://api.mexc.com/api/v3/depth?symbol=$s&limit=5" -TimeoutSec 10; $a5=MkLevels $d.asks 5; $b5=MkLevels $d.bids 5; return @{ask=$a5[0].p; askQ=$a5[0].q; bid=$b5[0].p; bidQ=$b5[0].q; asks=$a5; bids=$b5} }
    if($ex -eq "BYBIT"){ $d=Invoke-RestMethod "https://api.bybit.com/v5/market/orderbook?category=spot&symbol=$s&limit=5" -TimeoutSec 10; $a5=MkLevels $d.result.a 5; $b5=MkLevels $d.result.b 5; return @{ask=$a5[0].p; askQ=$a5[0].q; bid=$b5[0].p; bidQ=$b5[0].q; asks=$a5; bids=$b5} }
    $d=Invoke-RestMethod "https://www.okx.com/api/v5/market/books?instId=$oid&sz=5" -TimeoutSec 10
    $sa=$d.data[0].asks | Sort-Object { [double]$_[0] } | Select-Object -First 5
    $sb=$d.data[0].bids | Sort-Object { [double]$_[0] } -Descending | Select-Object -First 5
    $a5=MkLevels $sa 5; $b5=MkLevels $sb 5
    return @{ask=$a5[0].p; askQ=$a5[0].q; bid=$b5[0].p; bidQ=$b5[0].q; asks=$a5; bids=$b5}
  }catch{ return $null }
}
function Get-TradeUrl($ex,$sym){
  $uf=$sym.Replace("/","_"); $parts=$sym.Split("/"); $base=$parts[0]; $quote=$parts[1]
  if($ex -eq "BINANCE"){ return "https://www.binance.com/en/trade/${uf}?type=spot" }
  if($ex -eq "MEXC"){ return "https://www.mexc.com/exchange/${uf}" }
  if($ex -eq "BYBIT"){ return "https://www.bybit.com/en/trade/spot/${base}/${quote}" }
  return "https://www.okx.com/trade-spot/$($base.ToLower())-$($quote.ToLower())"
}
function Push-Alert($alert) {
  $url = "https://api.github.com/repos/$REPO/contents/$PATHF"
  $cur = @(); $sha = $null
  try {
    $f = Invoke-RestMethod -Uri $url -Headers $H -TimeoutSec 10
    $sha = $f.sha
    $txt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($f.content.Replace("`n","")))
    $cur = $txt | ConvertFrom-Json
    if ($cur -isnot [array]) { $cur = @($cur) }
  } catch { $cur = @() }
  $list = @($alert) + @($cur) | Select-Object -First $MAXA
  $json = $list | ConvertTo-Json -Depth 5
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
  $body = @{ message = "Update alerts - $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC"; content = $b64; branch = "main" }
  if ($sha) { $body.sha = $sha }
  try {
    Invoke-RestMethod -Uri $url -Method Put -Headers $H -Body ($body | ConvertTo-Json -Depth 5) -ContentType "application/json" -TimeoutSec 15 | Out-Null
    return $true
  } catch { Write-Host "  GitHub push error: $($_.Exception.Message)" -ForegroundColor Red; return $false }
}

Write-Host "============================================================"
Write-Host "ARBITRAGE BOT (PowerShell) - Repo: $REPO - Min: $MIN% - Cada ${WAIT}s"
Write-Host "============================================================"
$n = 0
do {
  $n++
  Write-Host ""
  Write-Host "--- Scan #$n $([DateTime]::UtcNow.ToString('HH:mm:ss')) UTC ---"
  $live=@()
  foreach ($sym in $SYMS) {
    $p = Get-Prices $sym
    if (-not $p.B -or -not $p.M) { continue }
    $bAsk=[double]$p.B.askPrice; $bBid=[double]$p.B.bidPrice
    $mAsk=[double]$p.M.askPrice; $mBid=[double]$p.M.bidPrice
    $yB=[double]$p.YB; $yA=[double]$p.YA; $oB=[double]$p.OB; $oA=[double]$p.OA
    if ($bAsk -le 0 -or $mAsk -le 0 -or $yA -le 0 -or $oA -le 0) { continue }
    $px=@{BINANCE=@{bid=$bBid;ask=$bAsk;fee=$FEE_B};MEXC=@{bid=$mBid;ask=$mAsk;fee=$FEE_M};BYBIT=@{bid=$yB;ask=$yA;fee=$FEE_Y};OKX=@{bid=$oB;ask=$oA;fee=$FEE_O}}
    $nn=-999; $bx=""; $sx=""; $bp=0; $sp=0; $g=0; $fb=0; $fs=0; $best=-999
    foreach($be in $px.Keys){ foreach($se in $px.Keys){ if($be -eq $se){continue}
      $gg=(($px[$se].bid-$px[$be].ask)/$px[$be].ask*100); $qq=$gg-$px[$be].fee-$px[$se].fee
      if($qq -gt $best){ $best=$qq; $bx=$be; $sx=$se; $bp=$px[$be].ask; $sp=$px[$se].bid; $g=$gg; $nn=$qq; $fb=$px[$be].fee; $fs=$px[$se].fee }
    }}
    $live += [ordered]@{symbol=$sym; binance_bid=$bBid; binance_ask=$bAsk; mexc_bid=$mBid; mexc_ask=$mAsk; bybit_bid=$yB; bybit_ask=$yA; okx_bid=$oB; okx_ask=$oA; best=[Math]::Round($best,4); best_buy=$bx; best_sell=$sx}
    if ($lastAlert.ContainsKey($sym) -and ((Get-Date) - $lastAlert[$sym]).TotalSeconds -lt $COOL) { continue }
    if ($best -ge $MIN) {
      $amt = $SIZE/$bp; $net = $amt*(1-$fb/100); $usdt = $net*$sp; $netU = $usdt*(1-$fs/100); $profit = $netU - $SIZE
      $alert = [ordered]@{
        symbol=$sym; buy_exchange=$bx; sell_exchange=$sx
        buy_price=[Math]::Round($bp,8); sell_price=[Math]::Round($sp,8)
        gross_spread=[Math]::Round($g,2); net_spread=[Math]::Round($nn,2)
        estimated_profit=[Math]::Round($profit,2)
        timestamp=([DateTime]::UtcNow.ToString("o"))
        pair_urls=@{ buy=(Get-TradeUrl $bx $sym); sell=(Get-TradeUrl $sx $sym) }
      }
      Write-Host "  OPORTUNIDAD $sym | Compra $bx $bp | Vende $sx $sp | Neto $([Math]::Round($nn,2))% | +`$$([Math]::Round($profit,2))" -ForegroundColor Green
      if (Push-Alert $alert) { Write-Host "  Publicado en GitHub" -ForegroundColor Cyan; $lastAlert[$sym]=Get-Date } else { Write-Host "  Fallo al publicar" -ForegroundColor Red }
    }
  }
  $liveObj = @{ updated=([DateTime]::UtcNow.ToString("o")); symbols=$live }
  $liveObj | ConvertTo-Json -Depth 5 | Set-Content "data/live.json" -Encoding UTF8
  try {
    $lj = Get-Content "data/live.json" -Raw -Encoding UTF8
    $lb64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lj))
    $lurl = "https://api.github.com/repos/$REPO/contents/data/live.json"
    $lsha = $null; try { $lsha = (Invoke-RestMethod -Uri "$lurl`?ref=main" -Headers $H -TimeoutSec 10).sha } catch {}
    $lbody = @{ message = "Update live - $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC"; content = $lb64; branch = "main" }
    if ($lsha) { $lbody.sha = $lsha }
    Invoke-RestMethod -Uri $lurl -Method Put -Headers $H -Body ($lbody | ConvertTo-Json -Depth 5) -ContentType "application/json" -TimeoutSec 15 | Out-Null
    Write-Host "Live publicado ($($live.Count) pares)"
  } catch { Write-Host "  Live push error: $($_.Exception.Message)" -ForegroundColor Yellow }
  if(((Get-Date)-$lastDepth).TotalSeconds -ge $DINT){
    $lastDepth=Get-Date; $depth=@(); $books=@()
    $fees=@{BINANCE=$FEE_B;MEXC=$FEE_M;BYBIT=$FEE_Y;OKX=$FEE_O}
    foreach($sym in $SYMS){
      $bk=@{}
      foreach($ex in @("BINANCE","MEXC","BYBIT","OKX")){ $q=Get-Depth $ex $sym; if($q){ $bk[$ex]=$q } }
      if($bk.Count -lt 2){ continue }
      $brow=[ordered]@{symbol=$sym}
      foreach($ex in $bk.Keys){ $brow[$ex.ToLower()]=@{asks=$bk[$ex].asks; bids=$bk[$ex].bids} }
      $books+=$brow
      $mfees=@{BINANCE=$MFB;MEXC=$MFM;BYBIT=$MFY;OKX=$MFO}
      $taker=@{BINANCE=$FEE_B;MEXC=$FEE_M;BYBIT=$FEE_Y;OKX=$FEE_O}
      $now=Get-Date
      foreach($me in $bk.Keys){
        foreach($xe in $bk.Keys){
          if($xe -eq $me){ continue }
          foreach($model in @("A","B")){
            $key="$sym|$me|$xe|$model"
            if($model -eq "A"){
              $entry=[double]$bk[$me].bid
              $exitP=[double]$bk[$xe].bid
              $w=WalkBook $bk[$xe].bids $SIZE $false
              if(-not $w.ok -or $w.gotU -lt $EXITMIN){ $h=$null; if($hist.ContainsKey($key)){ $h=$hist[$key] }; if($h -and $h.pos -gt 0){ $depth+=[ordered]@{symbol=$sym; type="COMPRA EN COLA"; maker_exchange=$me; exit_exchange=$xe; model=$model; state="RETIRAR"; state_reason="sin liquidez de salida"; limit_price=$h.entry; exit_price=$exitP; net=$h.net; timestamp=([DateTime]::UtcNow.ToString("o")); pair_urls=@{buy=(Get-TradeUrl $me $sym); sell=(Get-TradeUrl $xe $sym)}} }; $hist.Remove($key); continue }
              $slip=SlipPct $w.vwap $exitP $false
              $net=(($exitP/$entry)-1)*100-$mfees[$me]-$taker[$xe]-$slip-$SAFE
              $side="BID"; $askU=$bk[$me].ask*$bk[$me].askQ; $bidU=$entry*$bk[$me].bidQ
              if(-not ($askU -le $THIN -and $askU -le $bidU*0.5)){ $side="BID-EQUILIBRADO" }
            } else {
              $entry=[double]$bk[$me].ask
              $exitP=[double]$bk[$xe].ask
              $w=WalkBook $bk[$xe].asks $SIZE $true
              if(-not $w.ok -or $w.gotU -lt $EXITMIN){ $h=$null; if($hist.ContainsKey($key)){ $h=$hist[$key] }; if($h -and $h.pos -gt 0){ $depth+=[ordered]@{symbol=$sym; type="VENTA EN COLA"; maker_exchange=$me; exit_exchange=$xe; model=$model; state="RETIRAR"; state_reason="sin liquidez de salida"; limit_price=$h.entry; exit_price=$exitP; net=$h.net; timestamp=([DateTime]::UtcNow.ToString("o")); pair_urls=@{buy=(Get-TradeUrl $xe $sym); sell=(Get-TradeUrl $me $sym)}} }; $hist.Remove($key); continue }
              $slip=SlipPct $w.vwap $exitP $true
              $net=(($entry/$exitP)-1)*100-$mfees[$me]-$taker[$xe]-$slip-$SAFE
              $side="ASK"; $askU=$entry*$bk[$me].askQ; $bidU=$bk[$me].bid*$bk[$me].bidQ
              if(-not ($bidU -le $THIN -and $bidU -le $askU*0.5)){ $side="ASK-EQUILIBRADO" }
            }
            $h=$null; if($hist.ContainsKey($key)){ $h=$hist[$key] }
            if($net -ge $MIN){ if($h){ $h.pos=$h.pos+1; $h.net=$net; $h.last=$now } else { $hist[$key]=@{pos=1; first=$now; last=$now; net=$net; entry=$entry; prevVol=$null; prevTime=$now; rate=0; queueAhead=$null}; $h=$hist[$key] } }
            else { if($h -and $h.pos -gt 0){ $depth+=[ordered]@{symbol=$sym; type=$(if($model -eq "A"){"COMPRA EN COLA"}else{"VENTA EN COLA"}); maker_exchange=$me; exit_exchange=$xe; model=$model; state="RETIRAR"; state_reason="neto bajo umbral"; limit_price=$h.entry; exit_price=$exitP; net=[Math]::Round($net,4); timestamp=([DateTime]::UtcNow.ToString("o")); pair_urls=$(if($model -eq "A"){@{buy=(Get-TradeUrl $me $sym); sell=(Get-TradeUrl $xe $sym)}}else{@{buy=(Get-TradeUrl $xe $sym); sell=(Get-TradeUrl $me $sym)}})} }; $hist.Remove($key); continue }
            $lvl=FindLvl $(if($model -eq "A"){$bk[$me].bids}else{$bk[$me].asks}) $entry
            $curVol=$null; if($lvl){ $curVol=[Math]::Round($entry*[double]$lvl.q,2) }
            $rate=0; $queueAhead=$curVol
            if($h.prevVol -ne $null -and $curVol -ne $null){
              $el=($now-$h.prevTime).TotalSeconds; if($el -gt 0){ $rate=[Math]::Round([Math]::Max(0,$h.prevVol-$curVol)/$el,4) }
            }
            $h.prevVol=$curVol; $h.prevTime=$now; $h.rate=$rate; $h.queueAhead=$queueAhead
            $estFill=$null
            if($rate -gt 0 -and $queueAhead -ne $null){ $estFill=[Math]::Round($queueAhead/$rate,1) }
            $age=[Math]::Round(($now-$h.first).TotalSeconds,0)
            $state="OBSERVAR"; $reason="neto positivo, cola grande o agotamiento lento"
            $curAsk=[double]$bk[$me].ask; $curBid=[double]$bk[$me].bid
            $fillEv=$false
            if($model -eq "A"){ if($curAsk -gt $entry -and $rate -gt 0){ $fillEv=$true } }
            else { if($curBid -lt $entry -and $rate -gt 0){ $fillEv=$true } }
            if($fillEv -and $h.pos -ge $PERSIST){ $state="POSIBLE FILL"; $reason="volumen delante consumido con operaciones" }
            elseif($h.pos -ge $PERSIST -and $queueAhead -ne $null -and $queueAhead -le $SIZE*2 -and $rate -gt 0){ $state="PREPARAR"; $reason="volumen delante reducido y salida disponible" }
            elseif($h.pos -ge $PERSIST){ $state="OBSERVAR"; $reason="estable pero cola aun grande" }
            $sig=[ordered]@{symbol=$sym; type=$(if($model -eq "A"){"COMPRA EN COLA"}else{"VENTA EN COLA"}); maker_exchange=$me; exit_exchange=$xe; model=$model; state=$state; state_reason=$reason; side=$side; limit_price=[Math]::Round($entry,8); queue_ahead_usdt=$queueAhead; depletion_rate=$rate; est_fill_s=$estFill; exit_price=[Math]::Round($exitP,8); exit_vol_usdt=[Math]::Round($w.gotU,2); gross=[Math]::Round($(if($model -eq "A"){(($exitP/$entry)-1)*100}else{(($entry/$exitP)-1)*100}),4); maker_fee=$mfees[$me]; taker_fee=$taker[$xe]; slippage=[Math]::Round($slip,4); safety=$SAFE; net=[Math]::Round($net,4); pos_reads=$h.pos; age_s=$age; timestamp=([DateTime]::UtcNow.ToString("o")); pair_urls=$(if($model -eq "A"){@{buy=(Get-TradeUrl $me $sym); sell=(Get-TradeUrl $xe $sym)}}else{@{buy=(Get-TradeUrl $xe $sym); sell=(Get-TradeUrl $me $sym)}})}
            $depth+=$sig
            if($state -eq "POSIBLE FILL"){
              $f=[ordered]@{symbol=$sym; buy_exchange=$(if($model -eq "A"){$me}else{$xe}); sell_exchange=$(if($model -eq "A"){$xe}else{$me}); buy_price=$(if($model -eq "A"){$sig.limit_price}else{$sig.exit_price}); sell_price=$(if($model -eq "A"){$sig.exit_price}else{$sig.limit_price}); gross_spread=$sig.gross; net_spread=$sig.net; estimated_profit=[Math]::Round($sig.net/100*$SIZE,2); timestamp=$sig.timestamp; pair_urls=$sig.pair_urls; kind="fill"}
              if(Push-Alert $f){ $lastAlert[$sym]=Get-Date }
              Write-Host "  POSIBLE FILL $sym $($sig.type) $me -> $xe neto $($sig.net)%" -ForegroundColor Yellow
            }
            elseif($state -eq "PREPARAR"){ Write-Host "  PREPARAR $sym $($sig.type) $me @ $($sig.limit_price) -> $xe $($sig.exit_price) neto $($sig.net)% fill~$($estFill)s" -ForegroundColor Cyan }
          }
        }
      }
    }
    @{ updated=([DateTime]::UtcNow.ToString("o")); thin_usdt=$THIN; safety=$SAFE; persist_reads=$PERSIST; trade_usdt=$SIZE; signals=$depth; books=$books } | ConvertTo-Json -Depth 8 | Set-Content "data/depth.json" -Encoding UTF8
    try {
      $dj=Get-Content "data/depth.json" -Raw -Encoding UTF8
      $db64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($dj))
      $durl="https://api.github.com/repos/$REPO/contents/data/depth.json"
      $dsha=$null; try{ $dsha=(Invoke-RestMethod -Uri "$durl`?ref=main" -Headers $H -TimeoutSec 10).sha }catch{}
      $dbody=@{ message="Update depth - $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC"; content=$db64; branch="main" }
      if($dsha){ $dbody.sha=$dsha }
      Invoke-RestMethod -Uri $durl -Method Put -Headers $H -Body ($dbody|ConvertTo-Json -Depth 5) -ContentType "application/json" -TimeoutSec 15 | Out-Null
      Write-Host "Depth publicado ($($depth.Count) senales)"
    } catch { Write-Host "  Depth push error: $($_.Exception.Message)" -ForegroundColor Yellow }
  }
  Write-Host "Fin scan #$n. Proximo en ${WAIT}s..."
  if ($Once) { break }
  Start-Sleep -Seconds $WAIT
} while ($true)
