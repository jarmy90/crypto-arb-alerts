# depth-common.ps1 v13.2 - logica compartida (bot-local.ps1 y bot.ps1 la importan con dot-source).
# Centraliza: niveles, VWAP, slippage, neto unico, modelos A/B, agotamiento, trades, estados,
# catalogos spot, grupos base/quote con simbolos nativos por exchange.
$COMMON_VERSION = "13.3"

function MkLevels($rows, $n){
  $out=@()
  $c=0
  foreach($r in $rows){ if($c -ge $n){ break }; $out+=@{p=[double]$r[0]; q=[double]$r[1]}; $c++ }
  return $out
}

# VWAP para cubrir sizeU recorriendo niveles. Devuelve @{ok; vwap; gotU; lvls}
function WalkBook($levels, $sizeU){
  $gotU=0; $vwap=0; $lvls=0
  foreach($l in $levels){
    if($gotU -ge $sizeU){ break }
    $p=[double]$l.p; $q=[double]$l.q; $u=$p*$q
    $need=$sizeU-$gotU
    $take=[Math]::Min($u,$need)
    $vwap+=($take/$sizeU)*$p
    $gotU+=$take; $lvls++
  }
  if($gotU -lt $sizeU){ return @{ok=$false; vwap=$null; gotU=$gotU; lvls=$lvls} }
  return @{ok=$true; vwap=$vwap; gotU=$gotU; lvls=$lvls}
}

function SlipPct($vwap, $l1, $isBuy){
  if($isBuy){ return ($vwap-$l1)/$l1*100 } else { return ($l1-$vwap)/$l1*100 }
}

function FindLvl($levels, $price){
  foreach($l in $levels){ if([double]$l.p -eq [double]$price){ return $l } }
  return $null
}

# Funcion UNICA de neto para todo: directo, maker A/B, ordenes, parciales, paper.
function Compute-Net($buyPx, $sellPx, $makerFee, $takerFee, $slip, $safe){
  if($buyPx -le 0 -or $sellPx -le 0){ return $null }
  return (($sellPx/$buyPx)-1)*100-$makerFee-$takerFee-$slip-$safe
}

function Get-DepthAll($sym, $DLEN){
  $s=$sym.Replace("/",""); $oid=$sym.Replace("/","-")
  $bk=@{}
  try{ $d=Invoke-RestMethod "https://api.binance.com/api/v3/depth?symbol=$s&limit=$DLEN" -TimeoutSec 10; $a5=MkLevels $d.asks $DLEN; $b5=MkLevels $d.bids $DLEN; $bk["BINANCE"]=@{ask=$a5[0].p; askQ=$a5[0].q; bid=$b5[0].p; bidQ=$b5[0].q; asks=$a5; bids=$b5} }catch{}
  try{ $d=Invoke-RestMethod "https://api.mexc.com/api/v3/depth?symbol=$s&limit=$DLEN" -TimeoutSec 10; $a5=MkLevels $d.asks $DLEN; $b5=MkLevels $d.bids $DLEN; $bk["MEXC"]=@{ask=$a5[0].p; askQ=$a5[0].q; bid=$b5[0].p; bidQ=$b5[0].q; asks=$a5; bids=$b5} }catch{}
  try{ $d=Invoke-RestMethod "https://api.bybit.com/v5/market/orderbook?category=spot&symbol=$s&limit=$DLEN" -TimeoutSec 10; $a5=MkLevels $d.result.a $DLEN; $b5=MkLevels $d.result.b $DLEN; $bk["BYBIT"]=@{ask=$a5[0].p; askQ=$a5[0].q; bid=$b5[0].p; bidQ=$b5[0].q; asks=$a5; bids=$b5} }catch{}
  try{
    $d=Invoke-RestMethod "https://www.okx.com/api/v5/market/books?instId=$oid&sz=$DLEN" -TimeoutSec 10
    $sa=$d.data[0].asks | Sort-Object { [double]$_[0] } | Select-Object -First $DLEN
    $sb=$d.data[0].bids | Sort-Object { [double]$_[0] } -Descending | Select-Object -First $DLEN
    $a5=MkLevels $sa $DLEN; $b5=MkLevels $sb $DLEN
    $bk["OKX"]=@{ask=$a5[0].p; askQ=$a5[0].q; bid=$b5[0].p; bidQ=$b5[0].q; asks=$a5; bids=$b5}
  }catch{}
  return $bk
}

# Volumen USDT negociado CONFIRMADO a nuestro precio (o atravesandolo) desde sinceUtc.
# makerSide BUY: ventas agresivas (taker sell) con px <= price. SELL: compras agresivas px >= price.
# Devuelve @{vol=USDT; ok=$true} u @{vol=0; ok=$false} si el feed falla.
function Get-TradesVol($ex, $sym, $sinceUtc, $price, $makerSide){
  $s=$sym.Replace("/",""); $oid=$sym.Replace("/","-")
  try{
    $tr=@()
    if($ex -eq "BINANCE"){
      $d=Invoke-RestMethod "https://api.binance.com/api/v3/trades?symbol=$s&limit=50" -TimeoutSec 10
      foreach($t in $d){
        $ts=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$t.time).UtcDateTime
        if($ts -lt $sinceUtc){ continue }
        $px=[double]$t.price; $qv=0; if($t.quoteQty){ $qv=[double]$t.quoteQty } else { $qv=$px*[double]$t.qty }
        $hit=$false
        if($makerSide -eq "BUY" -and $t.isBuyerMaker -eq $false -and $px -le $price){ $hit=$true }
        if($makerSide -eq "SELL" -and $t.isBuyerMaker -eq $true -and $px -ge $price){ $hit=$true }
        if($hit){ $tr+=@{t=$ts; v=$qv} }
      }
    } elseif($ex -eq "MEXC"){
      $d=Invoke-RestMethod "https://api.mexc.com/api/v3/trades?symbol=$s&limit=50" -TimeoutSec 10
      if($d -isnot [array] -and $d.data){ $d=$d.data }
      foreach($t in $d){
        $px=[double]$t.price
        $q=0; if($t.quantity){ $q=[double]$t.quantity } elseif($t.qty){ $q=[double]$t.qty } elseif($t.amount){ $q=[double]$t.amount }
        $qv=$px*$q
        $ts=$sinceUtc
        if($t.time){ $ts=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$t.time).UtcDateTime }
        elseif($t.timestamp){ $ts=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$t.timestamp).UtcDateTime }
        if($ts -lt $sinceUtc){ continue }
        $isSell=$false; if($t.isBuyerMaker -ne $null){ $isSell=($t.isBuyerMaker -eq $false) } elseif($t.side){ $isSell=("$($t.side)".ToLower() -eq "sell") } elseif($t.isBid -ne $null){ $isSell=($t.isBid -eq $false) }
        $hit=$false
        if($makerSide -eq "BUY" -and $isSell -and $px -le $price){ $hit=$true }
        if($makerSide -eq "SELL" -and -not $isSell -and $px -ge $price){ $hit=$true }
        if($hit){ $tr+=@{t=$ts; v=$qv} }
      }
    } elseif($ex -eq "BYBIT"){
      $d=Invoke-RestMethod "https://api.bybit.com/v5/market/recent-trade?category=spot&symbol=$s&limit=50" -TimeoutSec 10
      foreach($t in $d.result.list){
        $ts=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$t.time).UtcDateTime
        if($ts -lt $sinceUtc){ continue }
        $px=[double]$t.price; $qv=$px*[double]$t.size
        $tk="$($t.side)".ToLower()
        $hit=$false
        if($makerSide -eq "BUY" -and $tk -eq "sell" -and $px -le $price){ $hit=$true }
        if($makerSide -eq "SELL" -and $tk -eq "buy" -and $px -ge $price){ $hit=$true }
        if($hit){ $tr+=@{t=$ts; v=$qv} }
      }
    } else {
      $d=Invoke-RestMethod "https://www.okx.com/api/v5/market/trades?instId=$oid&limit=50" -TimeoutSec 10
      foreach($t in $d.data){
        $ts=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$t.ts).UtcDateTime
        if($ts -lt $sinceUtc){ continue }
        $px=[double]$t.px; $qv=$px*[double]$t.sz
        $tk="$($t.side)".ToLower()
        $hit=$false
        if($makerSide -eq "BUY" -and $tk -eq "sell" -and $px -le $price){ $hit=$true }
        if($makerSide -eq "SELL" -and $tk -eq "buy" -and $px -ge $price){ $hit=$true }
        if($hit){ $tr+=@{t=$ts; v=$qv} }
      }
    }
    $sum=0; foreach($x in $tr){ $sum+=$x.v }
    return @{vol=[Math]::Round($sum,2); ok=$true}
  }catch{ return @{vol=0; ok=$false} }
}

# Feed de trades con lado taker para ventanas de flujo (M4). No filtra por precio.
# Devuelve @{trades=@(@{t;px;v;tk}); ok}. tk = buy|sell|unknown (lado agresivo).
function Get-FlowTrades($ex, $sym){
  $s=$sym.Replace("/",""); $oid=$sym.Replace("/","-")
  $tr=@()
  try{
    if($ex -eq "BINANCE"){
      $d=Invoke-RestMethod "https://api.binance.com/api/v3/trades?symbol=$s&limit=100" -TimeoutSec 10
      foreach($t in $d){
        $ts=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$t.time).UtcDateTime
        $px=[double]$t.price; $qv=0; if($t.quoteQty){ $qv=[double]$t.quoteQty } else { $qv=$px*[double]$t.qty }
        $tr+=@{t=$ts; px=$px; v=$qv; tk=$(if($t.isBuyerMaker){"buy"}else{"sell"})}
      }
    } elseif($ex -eq "MEXC"){
      $d=Invoke-RestMethod "https://api.mexc.com/api/v3/trades?symbol=$s&limit=100" -TimeoutSec 10
      if($d -isnot [array] -and $d.data){ $d=$d.data }
      foreach($t in $d){
        $px=[double]$t.price
        $q=0; if($t.quantity){ $q=[double]$t.quantity } elseif($t.qty){ $q=[double]$t.qty } elseif($t.amount){ $q=[double]$t.amount }
        $ts=[DateTime]::UtcNow
        if($t.time){ $ts=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$t.time).UtcDateTime }
        elseif($t.timestamp){ $ts=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$t.timestamp).UtcDateTime }
        $tk="unknown"
        if($t.isBuyerMaker -ne $null){ $tk=$(if($t.isBuyerMaker){"buy"}else{"sell"}) } elseif($t.side){ $tk="$($t.side)".ToLower() } elseif($t.isBid -ne $null){ $tk=$(if($t.isBid){"buy"}else{"sell"}) }
        $tr+=@{t=$ts; px=$px; v=$px*$q; tk=$tk}
      }
    } elseif($ex -eq "BYBIT"){
      $d=Invoke-RestMethod "https://api.bybit.com/v5/market/recent-trade?category=spot&symbol=$s&limit=100" -TimeoutSec 10
      foreach($t in $d.result.list){
        $ts=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$t.time).UtcDateTime
        $tr+=@{t=$ts; px=[double]$t.price; v=([double]$t.price*[double]$t.size); tk="$($t.side)".ToLower()}
      }
    } else {
      $d=Invoke-RestMethod "https://www.okx.com/api/v5/market/trades?instId=$oid&limit=100" -TimeoutSec 10
      foreach($t in $d.data){
        $ts=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$t.ts).UtcDateTime
        $tr+=@{t=$ts; px=[double]$t.px; v=([double]$t.px*[double]$t.sz); tk="$($t.side)".ToLower()}
      }
    }
    return @{trades=$tr; ok=$true}
  }catch{ return @{trades=@(); ok=$false} }
}

# Fill parcial estimado compartido (bot + tests + documentado para la web).
function Estimate-Partial($queueAheadInitial, $tradedAtPrice, $ownAmount){
  $over=[Math]::Max(0,$tradedAtPrice-$queueAheadInitial)
  $fill=[Math]::Min($ownAmount,$over)
  return @{fill=[Math]::Round($fill,2); pending=[Math]::Round($ownAmount-$fill,2)}
}

function Stdev($arr){
  $a=@($arr | Where-Object { $_ -ne $null })
  if($a.Count -lt 2){ return 0 }
  $m=($a | Measure-Object -Average).Average
  $v=0; foreach($x in $a){ $v+=($x-$m)*($x-$m) }
  return [Math]::Sqrt($v/$a.Count)
}

# Umbral dinamico desglosado (M1). Devuelve @{total; parts}
function Dyn-Threshold($makerFee, $takerFee, $slip, $lat, $prisk, $evol, $safe){
  return @{total=[Math]::Round($makerFee+$takerFee+$slip+$lat+$prisk+$evol+$safe,4);
    parts=[ordered]@{maker_fee=$makerFee; taker_fee=$takerFee; slippage=[Math]::Round($slip,4); latency=$lat; partial=$prisk; exitvol=[Math]::Round($evol,4); safety=$safe}}
}

# Flujo agresivo contra el nivel (M4). $trades: @(@{t;px;v;tk}) tk=taker side buy/sell.
function Classify-Flow($trades, $price, $makerSide, $now){
  $wins=@(1,3,5,10,30)
  $fav=0; $contra=0; $nFav=0; $nTot=0; $sizes=@()
  $w3=0; $w30=0
  foreach($t in $trades){
    $age=($now-$t.t).TotalSeconds
    if($age -lt 0 -or $age -gt 30){ continue }
    $nTot++
    $isFav=$false; $isContra=$false
    if($makerSide -eq "BUY"){
      if($t.tk -eq "sell" -and $t.px -le $price){ $isFav=$true }
      elseif($t.tk -eq "buy"){ $isContra=$true }
    } else {
      if($t.tk -eq "buy" -and $t.px -ge $price){ $isFav=$true }
      elseif($t.tk -eq "sell"){ $isContra=$true }
    }
    if($isFav){ $fav+=$t.v; $nFav++; $sizes+=$t.v; if($age -le 3){ $w3+=$t.v } ; $w30+=$t.v }
    elseif($isContra){ $contra+=$t.v }
  }
  $avg=0; if($nFav -gt 0){ $avg=[Math]::Round($fav/$nFav,2) }
  $accel=$null
  if($w30 -gt 0){ $accel=[Math]::Round(($w3/3)/($w30/30),2) }
  $state="SIN EVIDENCIA"
  if($fav -gt 0 -and $fav -ge 2*$contra){ $state="FLUJO FAVORABLE" }
  elseif($contra -gt 0 -and $contra -ge 2*[Math]::Max($fav,1)){ $state="FLUJO CONTRARIO" }
  elseif($fav -gt 0){ $state="FLUJO DEBIL" }
  return @{state=$state; favVol=[Math]::Round($fav,2); contraVol=[Math]::Round($contra,2); nFav=$nFav; nTot=$nTot; avgSize=$avg; accel=$accel}
}

# Survival ratio (M6). Devuelve @{ratio; class}
function Survival-Class($survivalS, $estFillS){
  if($estFillS -eq $null -or $estFillS -le 0){ return @{ratio=$null; class="desconocido"} }
  $r=$survivalS/$estFillS
  $c="insuficiente"; if($r -ge 4){ $c="favorable" } elseif($r -ge 2){ $c="razonable" } elseif($r -ge 1){ $c="riesgo" }
  return @{ratio=[Math]::Round($r,2); class=$c}
}

# Tamanos dinamicos (M3). $isExitBuy=$true si la salida COMPRA asks (modelo B).
function Best-Size($exitLevels, $entry, $mf, $tf, $safe, $baseRisk, $sizes, $model, $recSlipMax=0.5){
  $rows=@()
  foreach($sz in $sizes){
    if($model -eq "A"){ $w=WalkBook $exitLevels $sz $false } else { $w=WalkBook $exitLevels $sz $true }
    if(-not $w.ok){ $rows+=[ordered]@{size=$sz; covered=$false; gotU=[Math]::Round($w.gotU,2)}; continue }
    $l1=[double]$exitLevels[0].p
    $slip=$(if($model -eq "A"){SlipPct $w.vwap $l1 $false}else{SlipPct $w.vwap $l1 $true})
    if($model -eq "A"){ $net=Compute-Net $entry $w.vwap $mf $tf $slip $safe } else { $net=Compute-Net $w.vwap $entry $mf $tf $slip $safe }
    $dyn=$mf+$tf+$slip+$baseRisk+$safe
    $rows+=[ordered]@{size=$sz; covered=$true; gotU=[Math]::Round($w.gotU,2); vwap=[Math]::Round($w.vwap,8); lvls=$w.lvls; slippage=[Math]::Round($slip,4); net=[Math]::Round($net,4); abs=[Math]::Round($net/100*$sz,2); dyn=[Math]::Round($dyn,4)}
  }
  $cov=@($rows | Where-Object { $_.covered })
  $bestPct=$null; $bestAbs=$null; $rec=$null
  if($cov.Count -gt 0){
    $bestPct=($cov | Sort-Object net -Descending | Select-Object -First 1).size
    $bestAbs=($cov | Sort-Object abs -Descending | Select-Object -First 1).size
    $okRisk=@($cov | Where-Object { $_.net -gt $_.dyn -and $_.slippage -le $recSlipMax } | Sort-Object abs -Descending)
    if($okRisk.Count -gt 0){ $rec=$okRisk[0].size }
  }
  return @{rows=$rows; bestPct=$bestPct; bestAbs=$bestAbs; recommended=$rec}
}

function CfgD($cfg, $k, $d){ if($cfg.ContainsKey($k) -and $cfg[$k] -ne $null){ return $cfg[$k] } else { return $d } }
# Evalua modelos A/B para un simbolo. Actualiza $hist. Devuelve @{signals=@(); booksRow; tradesStats}
# $grp opcional: @{base; quote; normalized; natives=@{EX=nativo}} para sellar base/quote/nativos.
function Eval-Depth($sym, $bk, $cfg, $hist, $now, $getTradeUrl, $grp=$null){
  $LAT=CfgD $cfg "LAT" 0.05; $PRISK=CfgD $cfg "PRISK" 0.05; $EVOLK=CfgD $cfg "EVOLK" 1.0
  $SIZES=CfgD $cfg "SIZES" @(25,50,100,250,500,1000)
  $PRESIG_MS=CfgD $cfg "PRESIG_MS" 2000; $PREP_MS=CfgD $cfg "PREP_MS" 4000
  $GAP_MS=CfgD $cfg "GAP_MS" 1000; $GAPSCAN_S=CfgD $cfg "GAPSCAN_S" 300
  $NEAR=CfgD $cfg "NEAR" 0.10
  $QMAX=CfgD $cfg "QMAXAGE_MS" 2000; $SYNCMAX=CfgD $cfg "SYNCMAX_MS" 1500
  $FV=CfgD $cfg "FEESV" @{}
  $out=@(); $tradesN=0; $tradesOk=0
  $nowU=$now.ToUniversalTime()
  $brow=[ordered]@{symbol=$sym}
  foreach($ex in $bk.Keys){ $brow[$ex.ToLower()]=@{asks=$bk[$ex].asks; bids=$bk[$ex].bids} }
  $trCache=@{}; $flowCache=@{}
  $ageM=0; $ageX=0
  if($cfg.ContainsKey("Ages") -and $cfg.Ages -ne $null){ $ageM=CfgD $cfg.Ages "maker" 0; $ageX=CfgD $cfg.Ages "exit" 0 }
  $agesBad=([Math]::Max($ageM,$ageX) -gt $QMAX) -or ([Math]::Abs($ageM-$ageX) -gt $SYNCMAX)
  foreach($me in $bk.Keys){
    foreach($xe in $bk.Keys){
      if($xe -eq $me){ continue }
      foreach($model in @("A","B")){
        $key="$sym|$me|$xe|$model"
        $mSide=$(if($model -eq "A"){"BUY"}else{"SELL"})
        $feeV=($FV.Count -eq 0) -or ($FV[$me] -and $FV[$xe])
        if($agesBad){
          if($hist.ContainsKey($key) -and $hist[$key].pos -gt 0){
            $out+=[ordered]@{symbol=$sym; type=$(if($model -eq "A"){"COMPRA EN COLA"}else{"VENTA EN COLA"}); maker_exchange=$me; exit_exchange=$xe; model=$model; state="RETIRAR"; state_reason="DATOS INVALIDOS (libro maker ${ageM}ms, salida ${ageX}ms)"; limit_price=$hist[$key].entry; exit_price=$null; net=$hist[$key].net; ver=$COMMON_VERSION; timestamp=$now.ToString("o"); pair_urls=$(if($model -eq "A"){@{buy=(& $getTradeUrl $me $sym); sell=(& $getTradeUrl $xe $sym)}}else{@{buy=(& $getTradeUrl $xe $sym); sell=( & $getTradeUrl $me $sym)}})}
          }
          $hist.Remove($key); continue
        }
        if($model -eq "A"){
          $entry=[double]$bk[$me].bid
          $exitP=[double]$bk[$xe].bid
          $w=WalkBook $bk[$xe].bids $cfg.SIZE $false
          if(-not $w.ok -or $w.gotU -lt $cfg.EXITMIN){
            if($hist.ContainsKey($key) -and $hist[$key].pos -gt 0){
              $out+=[ordered]@{symbol=$sym; type="COMPRA EN COLA"; maker_exchange=$me; exit_exchange=$xe; model=$model; state="RETIRAR"; state_reason="sin liquidez de salida"; limit_price=$hist[$key].entry; exit_price=$exitP; net=$hist[$key].net; ver=$COMMON_VERSION; timestamp=$now.ToString("o"); pair_urls=@{buy=(& $getTradeUrl $me $sym); sell=(& $getTradeUrl $xe $sym)}}
            }
            $hist.Remove($key); continue
          }
          $slip=SlipPct $w.vwap $exitP $false
          $askU=$bk[$me].ask*$bk[$me].askQ; $bidU=$entry*$bk[$me].bidQ
          $side="BID"; if($askU -le $cfg.THIN -and $askU -le $bidU*0.5){ $side="ASK" }
        } else {
          $entry=[double]$bk[$me].ask
          $exitP=[double]$bk[$xe].ask
          $wexit=WalkBook $bk[$xe].asks $cfg.SIZE $true
          if(-not $wexit.ok -or $wexit.gotU -lt $cfg.EXITMIN){
            if($hist.ContainsKey($key) -and $hist[$key].pos -gt 0){
              $out+=[ordered]@{symbol=$sym; type="VENTA EN COLA"; maker_exchange=$me; exit_exchange=$xe; model=$model; state="RETIRAR"; state_reason="sin liquidez de salida"; limit_price=$hist[$key].entry; exit_price=$exitP; net=$hist[$key].net; ver=$COMMON_VERSION; timestamp=$now.ToString("o"); pair_urls=@{buy=(& $getTradeUrl $xe $sym); sell=(& $getTradeUrl $me $sym)}}
            }
            $hist.Remove($key); continue
          }
          $slip=SlipPct $wexit.vwap $exitP $true
          $side="ASK"; $askU=$entry*$bk[$me].askQ; $bidU=$bk[$me].bid*$bk[$me].bidQ
          if(-not ($askU -le $cfg.THIN -and $askU -le $bidU*0.5)){ $side="ASK-EQUILIBRADO" }
          $w=$wexit
        }
        $h=$null; if($hist.ContainsKey($key)){ $h=$hist[$key] }
        if($h -and (($nowU-$h.last).TotalSeconds -gt [Math]::Max($GAP_MS/1000,$GAPSCAN_S))){
          $h=@{pos=0; first=$nowU; last=$nowU; net=$null; entry=$entry; prevVol=$null; prevTime=$nowU; rate=0; queueAhead=$null; q0=$null; traded=0; ev="none"; nets=@(); gaps=0; exitMin=$null; exitMax=$null; gapNote="DESCARTADA POR INESTABILIDAD previa (hueco largo), se reevalua"}
          $hist[$key]=$h
        }
        $netRaw=$(if($model -eq "A"){Compute-Net $entry $exitP $cfg.MF[$me] $cfg.TF[$xe] $slip 0}else{Compute-Net $exitP $entry $cfg.MF[$me] $cfg.TF[$xe] $slip 0})
        if($h){ $h.nets+=@($netRaw); if($h.nets.Count -gt 20){ $h.nets=$h.nets[($h.nets.Count-20)..($h.nets.Count-1)] } }
        $evol=$EVOLK*$(if($h -and $h.nets.Count -ge 2){Stdev $h.nets}else{0})
        $dyn=Dyn-Threshold $cfg.MF[$me] $cfg.TF[$xe] $slip $LAT $PRISK $evol $cfg.SAFE
        $net=Compute-Net $entry $exitP $cfg.MF[$me] $cfg.TF[$xe] $slip $cfg.SAFE
        if($model -eq "B"){ $net=Compute-Net $exitP $entry $cfg.MF[$me] $cfg.TF[$xe] $slip $cfg.SAFE }
        $gate=[Math]::Max($cfg.MIN,$dyn.total)
        if($net -ge $cfg.MIN){
          if($h){ $h.pos=$h.pos+1; $h.net=$net; $h.last=$nowU }
          else { $hist[$key]=@{pos=1; first=$nowU; last=$nowU; net=$net; entry=$entry; prevVol=$null; prevTime=$nowU; rate=0; queueAhead=$null; q0=$null; traded=0; ev="none"; nets=@($netRaw); gaps=0; exitMin=$null; exitMax=$null; gapNote=$null}; $h=$hist[$key] }
        } else {
          if($h -and $h.pos -gt 0){ $h.gaps=$h.gaps+1
            $out+=[ordered]@{symbol=$sym; type=$(if($model -eq "A"){"COMPRA EN COLA"}else{"VENTA EN COLA"}); maker_exchange=$me; exit_exchange=$xe; model=$model; state="RETIRAR"; state_reason="neto bajo umbral"; limit_price=$h.entry; exit_price=$exitP; net=[Math]::Round($net,4); ver=$COMMON_VERSION; timestamp=$now.ToString("o"); pair_urls=$(if($model -eq "A"){@{buy=(& $getTradeUrl $me $sym); sell=(& $getTradeUrl $xe $sym)}}else{@{buy=(& $getTradeUrl $xe $sym); sell=( & $getTradeUrl $me $sym)}})}
          }
          $hist.Remove($key); continue
        }
        $lvls=$(if($model -eq "A"){$bk[$me].bids}else{$bk[$me].asks})
        $lvl=FindLvl $lvls $entry
        $curVol=$null; if($lvl){ $curVol=[Math]::Round($entry*[double]$lvl.q,2) }
        if($h.q0 -eq $null -and $curVol -ne $null){ $h.q0=$curVol }
        $rate=0
        if($h.prevVol -ne $null -and $curVol -ne $null){
          $el=($nowU-$h.prevTime).TotalSeconds; if($el -gt 0){ $rate=[Math]::Round([Math]::Max(0,$h.prevVol-$curVol)/$el,4) }
        }
        $h.prevVol=$curVol; $h.prevTime=$nowU
        $trKey="$me|$sym|$model"
        if(-not $trCache.ContainsKey($trKey)){
          if($cfg.ContainsKey("TradesStub") -and $cfg.TradesStub.ContainsKey($trKey)){ $tv=$cfg.TradesStub[$trKey] }
          else { $tv=Get-TradesVol $me $sym $h.first $entry $mSide }
          $trCache[$trKey]=$tv; $tradesN++
          if($tv.ok){ $tradesOk++ }
        }
        $tv=$trCache[$trKey]
        $h.traded=$tv.vol
        $ev=$(if($tv.ok){"trades"}else{"snapshot"})
        $h.ev=$ev
        $queueAhead=$curVol
        $h.rate=$rate; $h.queueAhead=$queueAhead
        $flKey="$me|$sym"
        if(-not $flowCache.ContainsKey($flKey)){
          if($cfg.ContainsKey("FlowStub") -and $cfg.FlowStub.ContainsKey($flKey)){ $flowCache[$flKey]=$cfg.FlowStub[$flKey] }
          else {
            $ft=Get-FlowTrades $me $sym
            $flowCache[$flKey]=$ft; $tradesN++
            if($ft.ok){ $tradesOk++ }
          }
        }
        $fl=$flowCache[$flKey]
        $flow=$(if($fl.ok){Classify-Flow $fl.trades $entry $mSide $nowU}else{@{state="SIN EVIDENCIA"; favVol=0; contraVol=0; nFav=0; nTot=0; avgSize=0; accel=$null}})
        $estFill=$null; $fillQ="NO CALCULABLE"
        $crate=0
        if($flow.favVol -gt 0){
          $span=[Math]::Max(1,($nowU-$h.first).TotalSeconds)
          $crate=$flow.favVol/$span
        }
        if($crate -gt 0 -and $queueAhead -ne $null){ $estFill=[Math]::Round($queueAhead/$crate,1); $fillQ="trades" }
        elseif($rate -gt 0 -and $queueAhead -ne $null){ $estFill=[Math]::Round($queueAhead/$rate,1); $fillQ="snapshot" }
        $age=[Math]::Round(($nowU-$h.first).TotalSeconds,0)
        if($h.exitNets -eq $null){ $h.exitNets=@() }
        $h.exitNets+=@(@{net=$net; t=$now})
        if($h.exitNets.Count -gt 20){ $h.exitNets=$h.exitNets[($h.exitNets.Count-20)..($h.exitNets.Count-1)] }
        $xn=@($h.exitNets | ForEach-Object { $_.net })
        $exitMin=($xn | Measure-Object -Minimum).Minimum; $exitMax=($xn | Measure-Object -Maximum).Maximum
        $exitAvg=[Math]::Round(($xn | Measure-Object -Average).Average,4)
        $surv=Survival-Class $age $estFill
        $bsizes=Best-Size $(if($model -eq "A"){$bk[$xe].bids}else{$bk[$xe].asks}) $entry $cfg.MF[$me] $cfg.TF[$xe] $cfg.SAFE ($LAT+$PRISK+$evol) $SIZES $model (CfgD $cfg "RECSLIP" 0.5)
        $feeOk=($FV.Count -eq 0) -or ($FV[$me] -and $FV[$xe])
        $state="OBSERVAR"; $reason="neto positivo, en evaluacion"
        $reduced=$false; $consumedByPrice=$false
        if($h.q0 -ne $null -and $curVol -ne $null -and $curVol -lt $h.q0){ $reduced=$true }
        $curAsk=[double]$bk[$me].ask; $curBid=[double]$bk[$me].bid
        if($model -eq "A"){ if($curBid -lt $entry){ $consumedByPrice=$true } }
        else { if($curAsk -gt $entry){ $consumedByPrice=$true } }
        $est=$null
        if($tv.ok -and $h.q0 -ne $null){ $est=Estimate-Partial $h.q0 $tv.vol $cfg.SIZE }
        $nearBand=($net -ge ($dyn.total-$NEAR)) -and ($net -lt $dyn.total)
        $flowOk=($flow.state -ne "FLUJO CONTRARIO")
        $qual=$(if($ev -eq "trades"){"ALTA"}else{"MEDIA"})
        if($consumedByPrice -and $tv.ok -and $est -ne $null -and $est.fill -ge $cfg.SIZE -and $h.pos -ge $cfg.PERSIST){
          $state="POSIBLE FILL"; $reason="nivel consumido con operaciones confirmadas"
        }
        elseif($consumedByPrice -and $tv.ok -and $est -ne $null -and $est.fill -gt 0 -and $h.pos -ge $cfg.PERSIST){
          $state="POSIBLE FILL PARCIAL"; $reason="parte ejecutada con operaciones confirmadas"
        }
        elseif($reduced -and (-not $tv.ok -or $tv.vol -le 0)){
          $state="NIVEL REDUCIDO"; $reason="NIVEL REDUCIDO, EJECUCION NO CONFIRMADA (puede ser cancelacion)"
        }
        elseif($nearBand){ $state="CERCA"; $reason="cerca del umbral dinamico, no operable" }
        elseif($h.pos -lt $cfg.PERSIST -or $age*1000 -lt $PRESIG_MS){
          if($flowOk){ $state="PRESEÑAL"; $reason="primera lectura positiva, en verificacion (flujo: $($flow.state))" }
          else { $state="OBSERVAR"; $reason="flujo contrario, sin oportunidad" }
        }
        elseif($net -le $dyn.total -or -not $flowOk){ $state="OBSERVAR"; $reason="neto bajo dinamico o flujo contrario" }
        elseif($queueAhead -ne $null -and $queueAhead -le $cfg.SIZE*2 -and ($rate -gt 0 -or $crate -gt 0) -and $surv.ratio -ne $null -and $surv.ratio -ge 1){ $state="PREPARAR"; $reason="volumen delante reducido, salida disponible, survival $($surv.ratio)" }
        else { $state="OBSERVAR"; $reason="estable pero cola aun grande o survival insuficiente" }
        $nf=$(if($dyn.total -gt 0){[Math]::Max(0,[Math]::Min(1,$net/($dyn.total*2)))}else{[Math]::Max(0,[Math]::Min(1,$net))})
        $fp=$(if($ev -ne "trades"){0.15}elseif($estFill -eq $null){0.3}else{[Math]::Max(0,[Math]::Min(1,1-$estFill/120))})
        $sf=$(if($surv.ratio -eq $null){0.3}elseif($surv.ratio -ge 4){1.0}elseif($surv.ratio -ge 2){0.75}elseif($surv.ratio -ge 1){0.5}else{0.2})
        $lf=[Math]::Max(0,[Math]::Min(1,$w.gotU/$cfg.SIZE))
        $df=$(if($ev -eq "trades"){1.0}else{0.7})
        $syf=1.0
        if($agesBad){ $syf=0 }
        $expo=[Math]::Max(0,[Math]::Min(0.3,$(if($queueAhead -ne $null){$queueAhead/($cfg.SIZE*4)}else{0.15})))
        $score=[Math]::Max(0,[Math]::Min(100,[Math]::Round(100*($nf*$fp*$sf*$lf*$df*$syf-$expo),1)))
        $band="DESCARTAR"; if($score -ge 90){ $band="ALTA CALIDAD" } elseif($score -ge 75){ $band="PREPARAR" } elseif($score -ge 60){ $band="PRESEÑAL" } elseif($score -ge 40){ $band="OBSERVAR" }
        if($band -eq "DESCARTAR" -and ($state -eq "PREPARAR" -or $state.indexOf("POSIBLE FILL") -eq 0)){ $state="OBSERVAR"; $reason="score bajo ($score), no avanza" }
        $sdet="net:$nf fill:$fp exit:$sf liq:$lf datos:$df sync:$syf - exposicion:$expo = $score [$band] PROBABILIDAD EXPERIMENTAL, MUESTRA INSUFICIENTE"
        $gross=$(if($model -eq "A"){(($exitP/$entry)-1)*100}else{(($entry/$exitP)-1)*100})
        $sig=[ordered]@{signal_id="$sym|$me|$xe|$model@$($h.first.ToString('yyyyMMddHHmmss'))"; paper_ready=$true; symbol=$sym; type=$(if($model -eq "A"){"COMPRA EN COLA"}else{"VENTA EN COLA"}); maker_exchange=$me; exit_exchange=$xe; model=$model; state=$state; state_reason=$reason; side=$side; limit_price=[Math]::Round($entry,8); queue_ahead_usdt=$queueAhead; queue_initial_usdt=$h.q0; depletion_rate=$rate; est_fill_s=$estFill; fill_quality=$fillQ; evidence=$ev; traded_usdt=$tv.vol; own_fill_est=$(if($est -eq $null){$null}else{$est.fill}); pending_usdt=$(if($est -eq $null){$null}else{$est.pending}); exit_price=[Math]::Round($exitP,8); exit_vol_usdt=[Math]::Round($w.gotU,2); exit_vwap=[Math]::Round($w.vwap,4); exit_lvls=$w.lvls; gross=[Math]::Round($gross,4); maker_fee=$cfg.MF[$me]; taker_fee=$cfg.TF[$xe]; fee_verified=$feeV; fee_source="config"; slippage=[Math]::Round($slip,4); safety=$cfg.SAFE; dyn_threshold=$dyn.total; dyn_parts=$dyn.parts; excess=[Math]::Round($net-$dyn.total,4); net=[Math]::Round($net,4); sizes=$bsizes.rows; best_pct_size=$bsizes.bestPct; best_abs_size=$bsizes.bestAbs; recommended_size=$bsizes.recommended; flow_state=$flow.state; flow_fav=$flow.favVol; flow_contra=$flow.contraVol; flow_n=$flow.nFav; flow_avg=$flow.avgSize; flow_accel=$flow.accel; survival_s=$age; survival_ratio=$surv.ratio; survival_class=$surv.class; exit_min=[Math]::Round($exitMin,4); exit_max=[Math]::Round($exitMax,4); exit_avg=$exitAvg; exit_gaps=$h.gaps; score=$score; score_band=$band; score_detail=$sdet; quality=$qual; pos_reads=$h.pos; age_s=$age; ver=$COMMON_VERSION; timestamp=$now.ToString("o"); pair_urls=$(if($model -eq "A"){@{buy=(& $getTradeUrl $me $sym); sell=(& $getTradeUrl $xe $sym)}}else{@{buy=(& $getTradeUrl $xe $sym); sell=( & $getTradeUrl $me $sym)}})}
        $out+=$sig
      }
    }
  }
  if($grp -ne $null){
    foreach($s in $out){
      $s.base=$grp.base; $s.quote=$grp.quote; $s.normalized_symbol=$grp.normalized
      if($grp.natives -and $s.maker_exchange){ $s.maker_native_symbol=$grp.natives[$s.maker_exchange] }
      if($grp.natives -and $s.exit_exchange){ $s.exit_native_symbol=$grp.natives[$s.exit_exchange] }
    }
    if($brow -is [System.Collections.Specialized.OrderedDictionary]){ $brow.base=$grp.base; $brow.quote=$grp.quote }
  }
  return @{signals=$out; booksRow=$brow; tradesN=$tradesN; tradesOk=$tradesOk}
}




