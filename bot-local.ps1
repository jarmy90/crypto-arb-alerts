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
$hist=@{}
. (Join-Path $PSScriptRoot "depth-common.ps1")
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
      $g=(($px[$se].bid-$px[$be].ask)/$px[$be].ask*100); $nn=Compute-Net $px[$be].ask $px[$se].bid $px[$be].fee $px[$se].fee 0 0
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
  @{ updated=([DateTime]::UtcNow.ToString("o")); ver=$COMMON_VERSION; symbols=$live } | ConvertTo-Json -Depth 5 | Set-Content "data/live.json" -Encoding UTF8
  if(((Get-Date)-$lastDepth).TotalSeconds -ge $DINT){
    $lastDepth=Get-Date; $depth=@(); $books=@()
    $cfg=@{MIN=$MIN; SIZE=$SIZE; THIN=$THIN; SAFE=$SAFE; EXITMIN=$EXITMIN; PERSIST=$PERSIST; MF=@{BINANCE=$MFB;MEXC=$MFM;BYBIT=$MFY;OKX=$MFO}; TF=@{BINANCE=$FB;MEXC=$FM;BYBIT=$FY;OKX=$FO}}
    $now=Get-Date; $trN=0; $trO=0
    foreach($sym in $SYMS){
      $bk=Get-DepthAll $sym 20
      if($bk.Count -lt 2){ continue }
      $ev=Eval-Depth $sym $bk $cfg $hist $now ${function:Get-TradeUrl}
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
    @{ updated=([DateTime]::UtcNow.ToString("o")); ver=$COMMON_VERSION; thin_usdt=$THIN; safety=$SAFE; persist_reads=$PERSIST; trade_usdt=$SIZE; trades_feeds="$trO/$trN"; signals=$depth; books=$books } | ConvertTo-Json -Depth 9 | Set-Content "data/depth.json" -Encoding UTF8
    Write-Host "Depth guardado ($($depth.Count) senales, trades $trO/$trN)"
  }
  if($Once){break}
  Start-Sleep -Seconds $WAIT
}while($true)
