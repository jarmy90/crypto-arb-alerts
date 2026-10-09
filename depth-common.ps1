# depth-common.ps1 v13 - logica compartida (bot-local.ps1 y bot.ps1 la importan con dot-source).
# Centraliza: niveles, VWAP, slippage, neto unico, modelos A/B, agotamiento, trades, estados.
$COMMON_VERSION = "13"

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

# Fill parcial estimado compartido (bot + tests + documentado para la web).
function Estimate-Partial($queueAheadInitial, $tradedAtPrice, $ownAmount){
  $over=[Math]::Max(0,$tradedAtPrice-$queueAheadInitial)
  $fill=[Math]::Min($ownAmount,$over)
  return @{fill=[Math]::Round($fill,2); pending=[Math]::Round($ownAmount-$fill,2)}
}

# Evalua modelos A/B para un simbolo. Actualiza $hist. Devuelve @{signals=@(); booksRow; tradesStats}
function Eval-Depth($sym, $bk, $cfg, $hist, $now, $getTradeUrl){
  $out=@(); $tradesN=0; $tradesOk=0
  $brow=[ordered]@{symbol=$sym}
  foreach($ex in $bk.Keys){ $brow[$ex.ToLower()]=@{asks=$bk[$ex].asks; bids=$bk[$ex].bids} }
  $trCache=@{}
  foreach($me in $bk.Keys){
    foreach($xe in $bk.Keys){
      if($xe -eq $me){ continue }
      foreach($model in @("A","B")){
        $key="$sym|$me|$xe|$model"
        $mSide=$(if($model -eq "A"){"BUY"}else{"SELL"})
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
          $net=Compute-Net $entry $exitP $cfg.MF[$me] $cfg.TF[$xe] $slip $cfg.SAFE
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
          $net=Compute-Net $exitP $entry $cfg.MF[$me] $cfg.TF[$xe] $slip $cfg.SAFE
          $side="ASK"; $askU=$entry*$bk[$me].askQ; $bidU=$bk[$me].bid*$bk[$me].bidQ
          if(-not ($askU -le $cfg.THIN -and $askU -le $bidU*0.5)){ $side="ASK-EQUILIBRADO" }
          $w=$wexit
        }
        $h=$null; if($hist.ContainsKey($key)){ $h=$hist[$key] }
        if($net -ge $cfg.MIN){
          if($h){ $h.pos=$h.pos+1; $h.net=$net; $h.last=$now }
          else { $hist[$key]=@{pos=1; first=$now; last=$now; net=$net; entry=$entry; prevVol=$null; prevTime=$now; rate=0; queueAhead=$null; q0=$null; traded=0; ev="none"}; $h=$hist[$key] }
        } else {
          if($h -and $h.pos -gt 0){
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
          $el=($now-$h.prevTime).TotalSeconds; if($el -gt 0){ $rate=[Math]::Round([Math]::Max(0,$h.prevVol-$curVol)/$el,4) }
        }
        $h.prevVol=$curVol; $h.prevTime=$now
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
        $estFill=$null
        if($rate -gt 0 -and $queueAhead -ne $null){ $estFill=[Math]::Round($queueAhead/$rate,1) }
        $age=[Math]::Round(($now-$h.first).TotalSeconds,0)
        $state="OBSERVAR"; $reason="neto positivo, cola grande o agotamiento lento"
        $reduced=$false; $consumedByPrice=$false
        if($h.q0 -ne $null -and $curVol -ne $null -and $curVol -lt $h.q0){ $reduced=$true }
        $curAsk=[double]$bk[$me].ask; $curBid=[double]$bk[$me].bid
        if($model -eq "A"){ if($curBid -lt $entry){ $consumedByPrice=$true } }
        else { if($curAsk -gt $entry){ $consumedByPrice=$true } }
        $est=$null; $pend=$null
        if($tv.ok -and $h.q0 -ne $null){
          $est=Estimate-Partial $h.q0 $tv.vol $cfg.SIZE
        }
        if($consumedByPrice -and $tv.ok -and $est -ne $null -and $est.fill -ge $cfg.SIZE -and $h.pos -ge $cfg.PERSIST){
          $state="POSIBLE FILL"; $reason="nivel consumido con operaciones confirmadas"
        }
        elseif($consumedByPrice -and $tv.ok -and $est -ne $null -and $est.fill -gt 0 -and $h.pos -ge $cfg.PERSIST){
          $state="POSIBLE FILL PARCIAL"; $reason="parte ejecutada con operaciones confirmadas"
        }
        elseif($reduced -and -not $tv.ok){
          $state="NIVEL REDUCIDO"; $reason="NIVEL REDUCIDO, EJECUCION NO CONFIRMADA (puede ser cancelacion)"
        }
        elseif($reduced -and $tv.ok){
          $state="NIVEL REDUCIDO"; $reason="NIVEL REDUCIDO, EJECUCION NO CONFIRMADA (trades: $($tv.vol) USDT, insuficiente)"
        }
        elseif($h.pos -ge $cfg.PERSIST -and $queueAhead -ne $null -and $queueAhead -le $cfg.SIZE*2 -and $rate -gt 0){ $state="PREPARAR"; $reason="volumen delante reducido y salida disponible" }
        elseif($h.pos -ge $cfg.PERSIST){ $state="OBSERVAR"; $reason="estable pero cola aun grande" }
        $gross=$(if($model -eq "A"){(($exitP/$entry)-1)*100}else{(($entry/$exitP)-1)*100})
        $sig=[ordered]@{symbol=$sym; type=$(if($model -eq "A"){"COMPRA EN COLA"}else{"VENTA EN COLA"}); maker_exchange=$me; exit_exchange=$xe; model=$model; state=$state; state_reason=$reason; side=$side; limit_price=[Math]::Round($entry,8); queue_ahead_usdt=$queueAhead; queue_initial_usdt=$h.q0; depletion_rate=$rate; est_fill_s=$estFill; evidence=$ev; traded_usdt=$tv.vol; own_fill_est=$(if($est -eq $null){$null}else{$est.fill}); pending_usdt=$(if($est -eq $null){$null}else{$est.pending}); exit_price=[Math]::Round($exitP,8); exit_vol_usdt=[Math]::Round($w.gotU,2); exit_vwap=[Math]::Round($w.vwap,4); exit_lvls=$w.lvls; gross=[Math]::Round($gross,4); maker_fee=$cfg.MF[$me]; taker_fee=$cfg.TF[$xe]; slippage=[Math]::Round($slip,4); safety=$cfg.SAFE; net=[Math]::Round($net,4); pos_reads=$h.pos; age_s=$age; ver=$COMMON_VERSION; timestamp=$now.ToString("o"); pair_urls=$(if($model -eq "A"){@{buy=(& $getTradeUrl $me $sym); sell=(& $getTradeUrl $xe $sym)}}else{@{buy=(& $getTradeUrl $xe $sym); sell=( & $getTradeUrl $me $sym)}})}
        $out+=$sig
      }
    }
  }
  return @{signals=$out; booksRow=$brow; tradesN=$tradesN; tradesOk=$tradesOk}
}
