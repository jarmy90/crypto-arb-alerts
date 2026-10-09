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
$lastDepth=[DateTime]::MinValue
$tracked=@{}
$hist=@{}
function WalkBook($levels, $sizeU, $isBuy){
  $gotU=0; $gotQ=0; $vwap=0
  foreach($l in $levels){
    $p=[double]$l.p; $q=[double]$l.q; $u=$p*$q
    $need=$sizeU-$gotU
    if($need -le 0){ break }
    $take=[Math]::Min($u,$need)
    $vwap+=($take/$sizeU)*$p
    $gotU+=$take; $gotQ+=$take/$p
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
$SYMS=(Get-Cfg $map "SYMBOLS" "BTC/USDT,ETH/USDT,BNB/USDT,SOL/USDT,XRP/USDT,ADA/USDT,DOGE/USDT").Split(",") | ForEach-Object{$_.Trim()}
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
do{
  $n++; Write-Host "`n--- Scan #$n $([DateTime]::UtcNow.ToString('HH:mm:ss')) UTC ---"
  $live=@()
  foreach($sym in $SYMS){
    if($last.ContainsKey($sym) -and ((Get-Date)-$last[$sym]).TotalSeconds -lt $COOL){continue}
    $s=$sym.Replace("/",""); $oid=$sym.Replace("/","-"); $b=$null; $m=$null; $yB=$null; $yA=$null; $oB=$null; $oA=$null
    try{$b=Invoke-RestMethod "https://api.binance.com/api/v3/ticker/bookTicker?symbol=$s" -TimeoutSec 10}catch{}
    try{$m=Invoke-RestMethod "https://api.mexc.com/api/v3/ticker/bookTicker?symbol=$s" -TimeoutSec 10}catch{}
    try{ $y=Invoke-RestMethod "https://api.bybit.com/v5/market/tickers?category=spot&symbol=$s" -TimeoutSec 10; $t=$y.result.list[0]; $yB=[double]$t.bid1Price; $yA=[double]$t.ask1Price }catch{}
    try{ $o=Invoke-RestMethod "https://www.okx.com/api/v5/market/ticker?instId=$oid" -TimeoutSec 10; $d=$o.data[0]; $oB=[double]$d.bidPx; $oA=[double]$d.askPx }catch{}
    if(-not $b -or -not $m -or -not $yB -or $yA -le 0 -or -not $oB -or $oA -le 0){continue}
    $bA=[double]$b.askPrice; $bB=[double]$b.bidPrice; $mA=[double]$m.askPrice; $mB=[double]$m.bidPrice
    if($bA -le 0 -or $mA -le 0){continue}
    $px=@{BINANCE=@{bid=$bB;ask=$bA;fee=$FB};MEXC=@{bid=$mB;ask=$mA;fee=$FM};BYBIT=@{bid=$yB;ask=$yA;fee=$FY};OKX=@{bid=$oB;ask=$oA;fee=$FO}}
    $bestN=-999; $bx=""; $sx=""; $bp=0; $sp=0; $gross=0
    foreach($be in $px.Keys){ foreach($se in $px.Keys){ if($be -eq $se){continue}
      $g=(($px[$se].bid-$px[$be].ask)/$px[$be].ask*100); $nn=$g-$px[$be].fee-$px[$se].fee
      if($nn -gt $bestN){ $bestN=$nn; $bx=$be; $sx=$se; $bp=$px[$be].ask; $sp=$px[$se].bid; $gross=$g; $fb=$px[$be].fee; $fs=$px[$se].fee }
    }}
    $live+= [ordered]@{symbol=$sym; binance_bid=$bB; binance_ask=$bA; mexc_bid=$mB; mexc_ask=$mA; bybit_bid=$yB; bybit_ask=$yA; okx_bid=$oB; okx_ask=$oA; best=[Math]::Round($bestN,4); best_buy=$bx; best_sell=$sx}
    if($bestN -ge $MIN){
      $amt=$SIZE/$bp; $profit=($amt*(1-$fb/100)*$sp*(1-$fs/100))-$SIZE
      $a=[ordered]@{symbol=$sym;buy_exchange=$bx;sell_exchange=$sx;buy_price=[Math]::Round($bp,8);sell_price=[Math]::Round($sp,8);gross_spread=[Math]::Round($gross,2);net_spread=[Math]::Round($bestN,2);estimated_profit=[Math]::Round($profit,2);timestamp=([DateTime]::UtcNow.ToString("o"));pair_urls=@{buy=(Get-TradeUrl $bx $sym);sell=(Get-TradeUrl $sx $sym)}}
      Write-Host "  OPORTUNIDAD $sym | $bx -> $sx | Neto $([Math]::Round($bestN,2))% | +`$$([Math]::Round($profit,2))" -ForegroundColor Green
      Save-Local $a; $last[$sym]=Get-Date
    }
  }
  Write-Host "Fin scan #$n. Guardado en data/alerts.json"
  @{ updated=([DateTime]::UtcNow.ToString("o")); symbols=$live } | ConvertTo-Json -Depth 5 | Set-Content "data/live.json" -Encoding UTF8
  if(((Get-Date)-$lastDepth).TotalSeconds -ge $DINT){
    $lastDepth=Get-Date; $depth=@(); $books=@()
    $fees=@{BINANCE=$FB;MEXC=$FM;BYBIT=$FY;OKX=$FO}
    foreach($sym in $SYMS){
      $bk=@{}
      foreach($ex in @("BINANCE","MEXC","BYBIT","OKX")){ $q=Get-Depth $ex $sym; if($q){ $bk[$ex]=$q } }
      if($bk.Count -lt 2){ continue }
      $brow=[ordered]@{symbol=$sym}
      foreach($ex in $bk.Keys){ $brow[$ex.ToLower()]=@{asks=$bk[$ex].asks; bids=$bk[$ex].bids} }
      $books+=$brow
      $mfees=@{BINANCE=$MFB;MEXC=$MFM;BYBIT=$MFY;OKX=$MFO}
      $taker=@{BINANCE=$FB;MEXC=$FM;BYBIT=$FY;OKX=$FO}
      $mfees=@{BINANCE=$MFB;MEXC=$MFM;BYBIT=$MFY;OKX=$MFO}
      $taker=@{BINANCE=$FB;MEXC=$FM;BYBIT=$FY;OKX=$FO}
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
            if($net -ge $MIN){ if($h){ $h.pos=$h.pos+1; $h.net=$net; $h.last=$now } else { $hist[$key]=@{pos=1; first=$now; last=$now; net=$net; entry=$entry; prevVol=$null; prevTime=$now; rate=0; queueAhead=$null} ; $h=$hist[$key] } }
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
              Save-Local $f; $last[$sym]=Get-Date
              Write-Host "  POSIBLE FILL $sym $($sig.type) $me -> $xe neto $($sig.net)%" -ForegroundColor Yellow
            }
            elseif($state -eq "PREPARAR"){ Write-Host "  PREPARAR $sym $($sig.type) $me @ $($sig.limit_price) -> $xe $($sig.exit_price) neto $($sig.net)% fill~$($estFill)s" -ForegroundColor Cyan }
          }
        }
      }
    }
    @{ updated=([DateTime]::UtcNow.ToString("o")); thin_usdt=$THIN; safety=$SAFE; persist_reads=$PERSIST; trade_usdt=$SIZE; signals=$depth; books=$books } | ConvertTo-Json -Depth 8 | Set-Content "data/depth.json" -Encoding UTF8
    Write-Host "Depth guardado ($($depth.Count) senales)"
  }
  if($Once){break}
  Start-Sleep -Seconds $WAIT
}while($true)
