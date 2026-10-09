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
$lastDepth=[DateTime]::MinValue
$tracked=@{}
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
      foreach($be in $bk.Keys){
        $ask=$bk[$be].ask; $askU=$ask*$bk[$be].askQ
        if($askU -gt $THIN){ continue }
        $entry=[double]$bk[$be].bid
        $a2=$null; if($bk[$be].asks.Count -ge 2){ $a2=[double]$bk[$be].asks[1].p }
        $bestS=""; $bestB=0
        foreach($se in $bk.Keys){ if($se -eq $be){continue}; if([double]$bk[$se].bid -gt $bestB){ $bestB=[double]$bk[$se].bid; $bestS=$se } }
        if(-not $bestS){ continue }
        $limitNet=(($bestB-$entry)/$entry*100)-$fees[$be]-$fees[$bestS]
        $mkt1=(($bestB-$ask)/$ask*100)-$fees[$be]-$fees[$bestS]
        $mkt2=$null; if($a2){ $mkt2=[Math]::Round((($bestB-$a2)/$a2*100)-$fees[$be]-$fees[$bestS],4) }
        $net=$limitNet
        $worth=$net -ge $MIN
        $ask2=$a2; $ask2U=$null; if($a2 -and $bk[$be].asks.Count -ge 2){ $ask2U=[Math]::Round($a2*[double]$bk[$be].asks[1].q,2) }
        $key="$sym|$be"; $fill=$false
        if($tracked.ContainsKey($key)){ $prev=$tracked[$key]; if($prev.entry -and $ask -gt $prev.entry){ $fill=$true } }
        $tracked[$key]=@{entry=$entry; ask=$ask}
        if($worth -or $fill){
          $sig=[ordered]@{symbol=$sym; buy_exchange=$be; sell_exchange=$bestS; entry_price=[Math]::Round($entry,8); buy_price=[Math]::Round($entry,8); buy_lvl=0; sell_price=[Math]::Round($bestB,8); sell_lvl=1; ask_now=[Math]::Round($ask,8); ask_vol_usdt=[Math]::Round($askU,2); sell_bid=[Math]::Round($bestB,8); net_if_filled=[Math]::Round($net,2); mkt_net_lvl1=[Math]::Round($mkt1,4); mkt_net_lvl2=$mkt2; worth=$worth; fill_suspected=$fill; ask_next=$ask2; ask_next_vol_usdt=$ask2U; timestamp=([DateTime]::UtcNow.ToString("o")); pair_urls=@{buy=(Get-TradeUrl $be $sym); sell=(Get-TradeUrl $bestS $sym)}}
          $depth+=$sig
          if($fill){ $f=[ordered]@{symbol=$sym; buy_exchange=$be; sell_exchange=$bestS; buy_price=$sig.entry_price; sell_price=$sig.sell_bid; gross_spread=$sig.net_if_filled; net_spread=$sig.net_if_filled; estimated_profit=[Math]::Round((($SIZE/$sig.entry_price)*$sig.sell_bid)-$SIZE,2); timestamp=$sig.timestamp; pair_urls=$sig.pair_urls; kind="fill"}; Save-Local $f; $last[$sym]=Get-Date; Write-Host "  POSIBLE FILL $sym en $be a $($sig.entry_price) -> vende $bestS" -ForegroundColor Yellow }
          elseif($worth){ Write-Host "  LIBRO FINO $sym entra COLA-BID $be $($sig.entry_price) -> vende $bestS $($sig.sell_price) neto $($sig.net_if_filled)% (mercado directo daria $($sig.mkt_net_lvl1)%)" -ForegroundColor Cyan }
        }
      }
    }
    @{ updated=([DateTime]::UtcNow.ToString("o")); thin_usdt=$THIN; signals=$depth; books=$books } | ConvertTo-Json -Depth 8 | Set-Content "data/depth.json" -Encoding UTF8
    Write-Host "Depth guardado ($($depth.Count) senales)"
  }
  if($Once){break}
  Start-Sleep -Seconds $WAIT
}while($true)
