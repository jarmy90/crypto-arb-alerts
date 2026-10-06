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
$WAIT  = [int](Get-Cfg "CHECK_INTERVAL" "8")
$COOL  = [int](Get-Cfg "COOLDOWN_SECONDS" "90")
$MAXA  = [int](Get-Cfg "MAX_ALERTS" "50")
$PATHF = Get-Cfg "GITHUB_FILE_PATH" "data/alerts.json"
$SYMS  = (Get-Cfg "SYMBOLS" "BTC/USDT,ETH/USDT,BNB/USDT,SOL/USDT,XRP/USDT,ADA/USDT,DOGE/USDT").Split(",") | ForEach-Object { $_.Trim() }

$lastAlert = @{}
$H = @{ Authorization = "Bearer $TOKEN"; Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28"; "User-Agent" = "arb-bot-ps" }

function Get-Prices($sym) {
  $s = $sym.Replace("/","")
  $b = $null; $m = $null
  try { $b = Invoke-RestMethod "https://api.binance.com/api/v3/ticker/bookTicker?symbol=$s" -TimeoutSec 10 } catch { Write-Host "  Binance $sym error: $($_.Exception.Message)" }
  try { $m = Invoke-RestMethod "https://api.mexc.com/api/v3/ticker/bookTicker?symbol=$s" -TimeoutSec 10 } catch { Write-Host "  MEXC $sym error: $($_.Exception.Message)" }
  return @{ B=$b; M=$m }
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
  foreach ($sym in $SYMS) {
    if ($lastAlert.ContainsKey($sym) -and ((Get-Date) - $lastAlert[$sym]).TotalSeconds -lt $COOL) { continue }
    $p = Get-Prices $sym
    if (-not $p.B -or -not $p.M) { continue }
    $bAsk=[double]$p.B.askPrice; $bBid=[double]$p.B.bidPrice
    $mAsk=[double]$p.M.askPrice; $mBid=[double]$p.M.bidPrice
    if ($bAsk -le 0 -or $mAsk -le 0) { continue }
    # Dir1: compra Binance, vende MEXC
    $g1 = ($mBid - $bAsk)/$bAsk*100; $n1 = $g1 - $FEE_B - $FEE_M
    # Dir2: compra MEXC, vende Binance
    $g2 = ($bBid - $mAsk)/$mAsk*100; $n2 = $g2 - $FEE_M - $FEE_B
    $best = [Math]::Max($n1,$n2)
    if ($best -ge $MIN) {
      if ($n1 -ge $n2) { $bx="BINANCE"; $sx="MEXC"; $bp=$bAsk; $sp=$mBid; $g=$g1; $nn=$n1; $fb=$FEE_B; $fs=$FEE_M }
      else { $bx="MEXC"; $sx="BINANCE"; $bp=$mAsk; $sp=$bBid; $g=$g2; $nn=$n2; $fb=$FEE_M; $fs=$FEE_B }
      $amt = $SIZE/$bp; $net = $amt*(1-$fb/100); $usdt = $net*$sp; $netU = $usdt*(1-$fs/100); $profit = $netU - $SIZE
      $sf = $sym.Replace("/",""); $uf = $sym.Replace("/","_")
      $alert = [ordered]@{
        symbol=$sym; buy_exchange=$bx; sell_exchange=$sx
        buy_price=[Math]::Round($bp,8); sell_price=[Math]::Round($sp,8)
        gross_spread=[Math]::Round($g,2); net_spread=[Math]::Round($nn,2)
        estimated_profit=[Math]::Round($profit,2)
        timestamp=([DateTime]::UtcNow.ToString("o"))
        pair_urls=@{ buy="https://www.binance.com/en/trade/${uf}?type=spot"; sell="https://www.mexc.com/exchange/${uf}" }
      }
      if ($bx -eq "MEXC") { $alert.pair_urls.buy="https://www.mexc.com/exchange/${uf}"; $alert.pair_urls.sell="https://www.binance.com/en/trade/${uf}?type=spot" }
      Write-Host "  OPORTUNIDAD $sym | Compra $bx $bp | Vende $sx $sp | Neto $([Math]::Round($nn,2))% | +`$$([Math]::Round($profit,2))" -ForegroundColor Green
      if (Push-Alert $alert) { Write-Host "  Publicado en GitHub" -ForegroundColor Cyan; $lastAlert[$sym]=Get-Date } else { Write-Host "  Fallo al publicar" -ForegroundColor Red }
    }
  }
  Write-Host "Fin scan #$n. Proximo en ${WAIT}s..."
  if ($Once) { break }
  Start-Sleep -Seconds $WAIT
} while ($true)
