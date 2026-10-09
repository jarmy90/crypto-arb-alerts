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
$lastDepth = [DateTime]::MinValue
$tracked = @{}
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
function Get-Depth($ex,$sym){
  $s=$sym.Replace("/",""); $oid=$sym.Replace("/","-")
  try{
    if($ex -eq "BINANCE"){ $d=Invoke-RestMethod "https://api.binance.com/api/v3/depth?symbol=$s&limit=5" -TimeoutSec 10; return @{ask=[double]$d.asks[0][0]; askQ=[double]$d.asks[0][1]; bid=[double]$d.bids[0][0]; bidQ=[double]$d.bids[0][1]} }
    if($ex -eq "MEXC"){ $d=Invoke-RestMethod "https://api.mexc.com/api/v3/depth?symbol=$s&limit=5" -TimeoutSec 10; return @{ask=[double]$d.asks[0][0]; askQ=[double]$d.asks[0][1]; bid=[double]$d.bids[0][0]; bidQ=[double]$d.bids[0][1]} }
    if($ex -eq "BYBIT"){ $d=Invoke-RestMethod "https://api.bybit.com/v5/market/orderbook?category=spot&symbol=$s&limit=5" -TimeoutSec 10; $a=$d.result.a[0]; $b2=$d.result.b[0]; return @{ask=[double]$a[0]; askQ=[double]$a[1]; bid=[double]$b2[0]; bidQ=[double]$b2[1]} }
    $d=Invoke-RestMethod "https://www.okx.com/api/v5/market/books?instId=$oid&sz=5" -TimeoutSec 10; $asks=$d.data[0].asks; $bids=$d.data[0].bids
    $ba=($asks | ForEach-Object { [double]$_[0] } | Measure-Object -Minimum).Minimum
    $baQ=0; foreach($r in $asks){ if([double]$r[0] -eq $ba){ $baQ=[double]$r[1]; break } }
    $bb=($bids | ForEach-Object { [double]$_[0] } | Measure-Object -Maximum).Maximum
    $bbQ=0; foreach($r in $bids){ if([double]$r[0] -eq $bb){ $bbQ=[double]$r[1]; break } }
    return @{ask=$ba; askQ=$baQ; bid=$bb; bidQ=$bbQ}
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
    $lastDepth=Get-Date; $depth=@()
    $fees=@{BINANCE=$FEE_B;MEXC=$FEE_M;BYBIT=$FEE_Y;OKX=$FEE_O}
    foreach($sym in $SYMS){
      $bk=@{}
      foreach($ex in @("BINANCE","MEXC","BYBIT","OKX")){ $q=Get-Depth $ex $sym; if($q){ $bk[$ex]=$q } }
      if($bk.Count -lt 2){ continue }
      foreach($be in $bk.Keys){
        $ask=$bk[$be].ask; $askU=$ask*$bk[$be].askQ
        if($askU -gt $THIN){ continue }
        $entry=$bk[$be].bid
        $bestS=""; $bestB=0
        foreach($se in $bk.Keys){ if($se -eq $be){continue}; if($bk[$se].bid -gt $bestB){ $bestB=$bk[$se].bid; $bestS=$se } }
        if(-not $bestS){ continue }
        $net=(($bestB-$entry)/$entry*100)-$fees[$be]-$fees[$bestS]
        $worth=$net -ge $MIN
        $key="$sym|$be"; $fill=$false
        if($tracked.ContainsKey($key)){ $prev=$tracked[$key]; if($prev.entry -and $ask -gt $prev.entry){ $fill=$true } }
        $tracked[$key]=@{entry=$entry; ask=$ask}
        if($worth -or $fill){
          $sig=[ordered]@{symbol=$sym; buy_exchange=$be; sell_exchange=$bestS; entry_price=[Math]::Round($entry,8); ask_now=[Math]::Round($ask,8); ask_vol_usdt=[Math]::Round($askU,2); sell_bid=[Math]::Round($bestB,8); net_if_filled=[Math]::Round($net,2); worth=$worth; fill_suspected=$fill; timestamp=([DateTime]::UtcNow.ToString("o")); pair_urls=@{buy=(Get-TradeUrl $be $sym); sell=(Get-TradeUrl $bestS $sym)}}
          $depth+=$sig
          if($fill){ Write-Host "  POSIBLE FILL $sym en $be a $($sig.entry_price) -> vende $bestS" -ForegroundColor Yellow; if(Push-Alert ([ordered]@{symbol=$sym; buy_exchange=$be; sell_exchange=$bestS; buy_price=$sig.entry_price; sell_price=$sig.sell_bid; gross_spread=$sig.net_if_filled; net_spread=$sig.net_if_filled; estimated_profit=[Math]::Round((($SIZE/$sig.entry_price)*$sig.sell_bid)-$SIZE,2); timestamp=$sig.timestamp; pair_urls=$sig.pair_urls; kind="fill"})){ $lastAlert[$sym]=Get-Date } }
          elseif($worth){ Write-Host "  LIBRO FINO $sym $be askVol $($sig.ask_vol_usdt) USDT entrada $($sig.entry_price) neto $($sig.net_if_filled)%" -ForegroundColor Cyan }
        }
      }
    }
    @{ updated=([DateTime]::UtcNow.ToString("o")); thin_usdt=$THIN; signals=$depth } | ConvertTo-Json -Depth 6 | Set-Content "data/depth.json" -Encoding UTF8
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
