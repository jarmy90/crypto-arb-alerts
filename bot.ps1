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
$hist = @{}
. (Join-Path $PSScriptRoot "depth-common.ps1")
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
      $gg=(($px[$se].bid-$px[$be].ask)/$px[$be].ask*100); $qq=Compute-Net $px[$be].ask $px[$se].bid $px[$be].fee $px[$se].fee 0 0
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
  $liveObj = @{ updated=([DateTime]::UtcNow.ToString("o")); ver=$COMMON_VERSION; symbols=$live }
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
    $cfg=@{MIN=$MIN; SIZE=$SIZE; THIN=$THIN; SAFE=$SAFE; EXITMIN=$EXITMIN; PERSIST=$PERSIST; MF=@{BINANCE=$MFB;MEXC=$MFM;BYBIT=$MFY;OKX=$MFO}; TF=@{BINANCE=$FEE_B;MEXC=$FEE_M;BYBIT=$FEE_Y;OKX=$FEE_O}}
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
          if(Push-Alert $f){ $lastAlert[$sym]=Get-Date }
          Write-Host "  $($sig.state) $sym $($sig.type) $($sig.maker_exchange) -> $($sig.exit_exchange) neto $($sig.net)% ev=$($sig.evidence)" -ForegroundColor Yellow
        }
        elseif($sig.state -eq "PREPARAR"){ Write-Host "  PREPARAR $sym $($sig.type) $($sig.maker_exchange) @ $($sig.limit_price) -> $($sig.exit_exchange) $($sig.exit_price) neto $($sig.net)% fill~$($sig.est_fill_s)s" -ForegroundColor Cyan }
      }
    }
    @{ updated=([DateTime]::UtcNow.ToString("o")); ver=$COMMON_VERSION; thin_usdt=$THIN; safety=$SAFE; persist_reads=$PERSIST; trade_usdt=$SIZE; trades_feeds="$trO/$trN"; signals=$depth; books=$books } | ConvertTo-Json -Depth 9 | Set-Content "data/depth.json" -Encoding UTF8
    Write-Host "Depth publicado ($($depth.Count) senales, trades $trO/$trN)"
    } catch { Write-Host "  Depth push error: $($_.Exception.Message)" -ForegroundColor Yellow }
  }
  Write-Host "Fin scan #$n. Proximo en ${WAIT}s..."
  if ($Once) { break }
  Start-Sleep -Seconds $WAIT
} while ($true)
