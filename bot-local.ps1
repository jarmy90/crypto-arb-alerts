# Bot local: escanea y guarda en data/alerts.json local + sirve la web. Sin GitHub.
param([switch]$Once)
Set-Location $PSScriptRoot
function Get-Cfg($map,$k,$d){ if($map.ContainsKey($k)-and $map[$k]){return $map[$k]} else{return $d} }
$map=@{}
if(Test-Path ".env"){ Get-Content ".env" | ForEach-Object { $l=$_.Trim(); if($l -and -not $l.StartsWith("#") -and $l.Contains("=")){ $k,$v=$l.Split("=",2); $map[$k.Trim()]=$v.Trim() } } }
$MIN=[double](Get-Cfg $map "MIN_NET_SPREAD" "0.40"); $SIZE=[double](Get-Cfg $map "TRADE_SIZE_USDT" "500")
$FB=[double](Get-Cfg $map "FEE_BINANCE" "0.10"); $FM=[double](Get-Cfg $map "FEE_MEXC" "0.05")
$WAIT=[int](Get-Cfg $map "CHECK_INTERVAL" "8"); $COOL=[int](Get-Cfg $map "COOLDOWN_SECONDS" "90")
$MAXA=[int](Get-Cfg $map "MAX_ALERTS" "50")
$SYMS=(Get-Cfg $map "SYMBOLS" "BTC/USDT,ETH/USDT,BNB/USDT,SOL/USDT,XRP/USDT,ADA/USDT,DOGE/USDT").Split(",") | ForEach-Object{$_.Trim()}
$last=@{}
if(-not (Test-Path "data")){ New-Item -ItemType Directory data | Out-Null }
function Save-Local($a){
  $f="data/alerts.json"; $cur=@()
  if(Test-Path $f){ try{$cur=Get-Content $f -Raw | ConvertFrom-Json; if($cur -isnot [array]){$cur=@($cur)}}catch{$cur=@()} }
  $list=@($a)+@($cur) | Select-Object -First $MAXA
  $list | ConvertTo-Json -Depth 5 | Set-Content $f -Encoding UTF8
}
$n=0
do{
  $n++; Write-Host "`n--- Scan #$n $([DateTime]::UtcNow.ToString('HH:mm:ss')) UTC ---"
  $live=@()
  foreach($sym in $SYMS){
    if($last.ContainsKey($sym) -and ((Get-Date)-$last[$sym]).TotalSeconds -lt $COOL){continue}
    $s=$sym.Replace("/",""); $b=$null; $m=$null
    try{$b=Invoke-RestMethod "https://api.binance.com/api/v3/ticker/bookTicker?symbol=$s" -TimeoutSec 10}catch{}
    try{$m=Invoke-RestMethod "https://api.mexc.com/api/v3/ticker/bookTicker?symbol=$s" -TimeoutSec 10}catch{}
    if(-not $b -or -not $m){continue}
    $bA=[double]$b.askPrice; $bB=[double]$b.bidPrice; $mA=[double]$m.askPrice; $mB=[double]$m.bidPrice
    if($bA -le 0 -or $mA -le 0){continue}
    $n1=(($mB-$bA)/$bA*100)-$FB-$FM; $n2=(($bB-$mA)/$mA*100)-$FM-$FB
    $best=[Math]::Max($n1,$n2)
    $live+= [ordered]@{symbol=$sym; binance_bid=$bB; binance_ask=$bA; mexc_bid=$mB; mexc_ask=$mA; net1=[Math]::Round($n1,4); net2=[Math]::Round($n2,4); best=[Math]::Round($best,4)}
    if($best -ge $MIN){
      if($n1 -ge $n2){$bx="BINANCE";$sx="MEXC";$bp=$bA;$sp=$mB;$g=(($mB-$bA)/$bA*100);$nn=$n1;$fb=$FB;$fs=$FM}
      else{$bx="MEXC";$sx="BINANCE";$bp=$mA;$sp=$bB;$g=(($bB-$mA)/$mA*100);$nn=$n2;$fb=$FM;$fs=$FB}
      $amt=$SIZE/$bp; $profit=($amt*(1-$fb/100)*$sp*(1-$fs/100))-$SIZE
      $sf=$sym.Replace("/",""); $uf=$sym.Replace("/","_")
      $buyUrl=if($bx -eq "BINANCE"){"https://www.binance.com/en/trade/${uf}?type=spot"}else{"https://www.mexc.com/exchange/${uf}"}
      $sellUrl=if($sx -eq "BINANCE"){"https://www.binance.com/en/trade/${uf}?type=spot"}else{"https://www.mexc.com/exchange/${uf}"}
      $a=[ordered]@{symbol=$sym;buy_exchange=$bx;sell_exchange=$sx;buy_price=[Math]::Round($bp,8);sell_price=[Math]::Round($sp,8);gross_spread=[Math]::Round($g,2);net_spread=[Math]::Round($nn,2);estimated_profit=[Math]::Round($profit,2);timestamp=([DateTime]::UtcNow.ToString("o"));pair_urls=@{buy=$buyUrl;sell=$sellUrl}}
      Write-Host "  OPORTUNIDAD $sym | $bx -> $sx | Neto $([Math]::Round($nn,2))% | +`$$([Math]::Round($profit,2))" -ForegroundColor Green
      Save-Local $a; $last[$sym]=Get-Date
    }
  }
  Write-Host "Fin scan #$n. Guardado en data/alerts.json"
  @{ updated=([DateTime]::UtcNow.ToString("o")); symbols=$live } | ConvertTo-Json -Depth 5 | Set-Content "data/live.json" -Encoding UTF8
  if($Once){break}
  Start-Sleep -Seconds $WAIT
}while($true)
