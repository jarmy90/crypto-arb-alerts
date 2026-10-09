# markets-common.ps1 v13.2 - catalogos spot y grupos base/quote (dot-source desde los bots).
# Regla: solo comparar la misma quote. Nunca mezclar USDC con USDT.
$MARKETS_VERSION = "13.2"

function Native-Symbol($ex, $base, $quote){
  if($ex -eq "OKX"){ return "$base-$quote" }
  return "$base$quote"
}

function Get-CatalogBinance(){
  $map=@{}
  try{
    $d=Invoke-RestMethod "https://api.binance.com/api/v3/exchangeInfo" -TimeoutSec 30
    foreach($s in $d.symbols){
      $ok=($s.status -eq "TRADING") -and ($s.isSpotTradingAllowed -eq $true)
      if($s.permissions -and ($s.permissions -notcontains "SPOT")){ $ok=$false }
      $tick=$null; $step=$null; $minQ=$null; $minN=$null
      foreach($f in $s.filters){
        if($f.filterType -eq "PRICE_FILTER"){ $tick=[double]$f.tickSize }
        if($f.filterType -eq "LOT_SIZE"){ $step=[double]$f.stepSize; $minQ=[double]$f.minQty }
        if($f.filterType -eq "MIN_NOTIONAL" -or $f.filterType -eq "NOTIONAL"){ if($f.minNotional){ $minN=[double]$f.minNotional } }
      }
      $map[$s.symbol]=@{base=$s.baseAsset; quote=$s.quoteAsset; ok=$ok; native=$s.symbol; suspended=($s.status -ne "TRADING"); status=$s.status; spot=$s.isSpotTradingAllowed; tick=$tick; step=$step; minQty=$minQ; minNotional=$minN}
    }
  }catch{}
  return $map
}

function Get-CatalogMexc(){
  $map=@{}
  try{
    $d=Invoke-RestMethod "https://api.mexc.com/api/v3/exchangeInfo" -TimeoutSec 30
    foreach($s in $d.symbols){
      $ok=($s.status -eq "1" -or $s.status -eq "TRADING") -and ($s.isSpotTradingAllowed -eq $true)
      if($s.permissions -and ($s.permissions -notcontains "SPOT")){ $ok=$false }
      $map[$s.symbol]=@{base=$s.baseAsset; quote=$s.quoteAsset; ok=$ok; native=$s.symbol; suspended=($s.status -ne "1" -and $s.status -ne "TRADING"); status="$($s.status)"; spot=$s.isSpotTradingAllowed; tick=$null; step=$null; minQty=$null; minNotional=$null}
    }
  }catch{}
  return $map
}

function Get-CatalogBybit(){
  $map=@{}
  try{
    $d=Invoke-RestMethod "https://api.bybit.com/v5/market/instruments-info?category=spot&limit=1000" -TimeoutSec 30
    foreach($s in $d.result.list){
      $ok=($s.status -eq "Trading")
      $map[$s.symbol]=@{base=$s.baseCoin; quote=$s.quoteCoin; ok=$ok; native=$s.symbol; suspended=($s.status -ne "Trading"); status="$($s.status)"; spot=$true; tick=$null; step=$null; minQty=$null; minNotional=$null}
    }
  }catch{}
  return $map
}

function Get-CatalogOkx(){
  $map=@{}
  try{
    $d=Invoke-RestMethod "https://www.okx.com/api/v5/public/instruments?instType=SPOT" -TimeoutSec 30
    foreach($s in $d.data){
      $ok=($s.state -eq "live")
      $map[$s.instId]=@{base=$s.baseCcy; quote=$s.quoteCcy; ok=$ok; native=$s.instId; suspended=($s.state -ne "live"); status="$($s.state)"; spot=$true; tick=$null; step=$null; minQty=$null; minNotional=$null}
      if($s.tickSz){ $map[$s.instId].tick=[double]$s.tickSz }
      if($s.lotSz){ $map[$s.instId].lotSz=[double]$s.lotSz }
      if($s.minSz){ $map[$s.instId].minSz=[double]$s.minSz }
    }
  }catch{}
  return $map
}

function Get-CatalogAll(){
  return @{BINANCE=(Get-CatalogBinance); MEXC=(Get-CatalogMexc); BYBIT=(Get-CatalogBybit); OKX=(Get-CatalogOkx)}
}

# Grupos por (base,quote) con simbolos nativos. Solo miembros ok. Suspendidos aparte.
function Build-Groups($catalog, $bases, $quotes){
  $groups=@(); $susp=@()
  foreach($b in $bases){
    foreach($q in $quotes){
      $members=@{}
      foreach($ex in $catalog.Keys){
        $found=$null
        foreach($k in $catalog[$ex].Keys){
          $e=$catalog[$ex][$k]
          if($e.base -eq $b -and $e.quote -eq $q){ $found=$e; break }
        }
        if($found -and $found.ok){ $members[$ex]=$found.native }
        elseif($found){ $susp+=[ordered]@{base=$b; quote=$q; exchange=$ex; native=$found.native; status="$($found.status)"} }
      }
      $groups+=[ordered]@{base=$b; quote=$q; normalized="$b/$q"; members=$members}
    }
  }
  return @{groups=$groups; suspended=$susp}
}

# Principal por base: quote con mas exchanges; empate -> USDC.
function Select-Principal($groups){
  $out=@{}
  $bases=$groups | ForEach-Object { $_.base } | Sort-Object -Unique
  foreach($b in $bases){
    $cands=$groups | Where-Object { $_.base -eq $b }
    $best=$null; $bestN=-1
    foreach($c in $cands){
      $n=$c.members.Count
      if($n -gt $bestN -or ($n -eq $bestN -and $c.quote -eq "USDC")){ $best=$c.quote; $bestN=$n }
    }
    $out[$b]=$best
  }
  return $out
}

function Get-PricesNative($natives){
  $r=@{}
  if($natives.ContainsKey("BINANCE")){ try{ $d=Invoke-RestMethod "https://api.binance.com/api/v3/ticker/bookTicker?symbol=$($natives['BINANCE'])" -TimeoutSec 10; $r["BINANCE"]=@{bid=[double]$d.bidPrice; ask=[double]$d.askPrice} }catch{} }
  if($natives.ContainsKey("MEXC")){ try{ $d=Invoke-RestMethod "https://api.mexc.com/api/v3/ticker/bookTicker?symbol=$($natives['MEXC'])" -TimeoutSec 10; $r["MEXC"]=@{bid=[double]$d.bidPrice; ask=[double]$d.askPrice} }catch{} }
  if($natives.ContainsKey("BYBIT")){ try{ $d=Invoke-RestMethod "https://api.bybit.com/v5/market/tickers?category=spot&symbol=$($natives['BYBIT'])" -TimeoutSec 10; $t=$d.result.list[0]; $r["BYBIT"]=@{bid=[double]$t.bid1Price; ask=[double]$t.ask1Price} }catch{} }
  if($natives.ContainsKey("OKX")){ try{ $d=Invoke-RestMethod "https://www.okx.com/api/v5/market/ticker?instId=$($natives['OKX'])" -TimeoutSec 10; $t=$d.data[0]; $r["OKX"]=@{bid=[double]$t.bidPx; ask=[double]$t.askPx} }catch{} }
  return $r
}

function Get-DepthAllNative($natives, $DLEN){
  $bk=@{}
  if($natives.ContainsKey("BINANCE")){ try{ $d=Invoke-RestMethod "https://api.binance.com/api/v3/depth?symbol=$($natives['BINANCE'])&limit=$DLEN" -TimeoutSec 10; $a5=MkLevels $d.asks $DLEN; $b5=MkLevels $d.bids $DLEN; $bk["BINANCE"]=@{ask=$a5[0].p; askQ=$a5[0].q; bid=$b5[0].p; bidQ=$b5[0].q; asks=$a5; bids=$b5} }catch{} }
  if($natives.ContainsKey("MEXC")){ try{ $d=Invoke-RestMethod "https://api.mexc.com/api/v3/depth?symbol=$($natives['MEXC'])&limit=$DLEN" -TimeoutSec 10; $a5=MkLevels $d.asks $DLEN; $b5=MkLevels $d.bids $DLEN; $bk["MEXC"]=@{ask=$a5[0].p; askQ=$a5[0].q; bid=$b5[0].p; bidQ=$b5[0].q; asks=$a5; bids=$b5} }catch{} }
  if($natives.ContainsKey("BYBIT")){ try{ $d=Invoke-RestMethod "https://api.bybit.com/v5/market/orderbook?category=spot&symbol=$($natives['BYBIT'])&limit=$DLEN" -TimeoutSec 10; $a5=MkLevels $d.result.a $DLEN; $b5=MkLevels $d.result.b $DLEN; $bk["BYBIT"]=@{ask=$a5[0].p; askQ=$a5[0].q; bid=$b5[0].p; bidQ=$b5[0].q; asks=$a5; bids=$b5} }catch{} }
  if($natives.ContainsKey("OKX")){ try{
    $d=Invoke-RestMethod "https://www.okx.com/api/v5/market/books?instId=$($natives['OKX'])&sz=$DLEN" -TimeoutSec 10
    $sa=$d.data[0].asks | Sort-Object { [double]$_[0] } | Select-Object -First $DLEN
    $sb=$d.data[0].bids | Sort-Object { [double]$_[0] } -Descending | Select-Object -First $DLEN
    $a5=MkLevels $sa $DLEN; $b5=MkLevels $sb $DLEN
    $bk["OKX"]=@{ask=$a5[0].p; askQ=$a5[0].q; bid=$b5[0].p; bidQ=$b5[0].q; asks=$a5; bids=$b5}
  }catch{} }
  return $bk
}
