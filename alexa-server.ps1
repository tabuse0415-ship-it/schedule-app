# ============================================================
# alexa-server.ps1  Alexa スキル用バックエンドサーバー
# ポート: 8082  ※ 管理者権限で実行してください
# ============================================================

$Port      = 8082
$Root      = "C:\Users\tabus\schedule-app"
$TokenFile = Join-Path $Root "alexa-token.json"
$CalId     = "primary"
$CalBase   = "https://www.googleapis.com/calendar/v3"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ===== Google Calendar API =====

function Get-SavedToken {
    if (Test-Path $TokenFile) {
        $obj = Get-Content $TokenFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return $obj.access_token
    }
    return $null
}

function Invoke-CalAPI {
    param([string]$Method, [string]$Path, $Body = $null, [string]$Token)
    $url     = "$CalBase$Path"
    $headers = @{ Authorization = "Bearer $Token"; Accept = "application/json" }
    $params  = @{ Uri = $url; Method = $Method; Headers = $headers; UseBasicParsing = $true; ErrorAction = "Stop" }
    if ($Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $params.ContentType = "application/json; charset=utf-8"
    }
    try   { return Invoke-RestMethod @params }
    catch { Write-Host "CalAPI Error[$Method $Path]: $_" -ForegroundColor Red; return $null }
}

function Get-EventsForDate {
    param([string]$Date, [string]$Token)
    $tMin = [uri]::EscapeDataString("${Date}T00:00:00+09:00")
    $tMax = [uri]::EscapeDataString("${Date}T23:59:59+09:00")
    $path = "/calendars/$CalId/events?timeMin=$tMin&timeMax=$tMax&singleEvents=true&orderBy=startTime"
    $res  = Invoke-CalAPI -Method GET -Path $path -Token $Token
    if ($res -and $res.items) { return @($res.items) } else { return @() }
}

function New-CalendarEvent {
    param([string]$Title, [string]$Date, [string]$StartTime, [string]$EndTime, [int]$NotifyMin, [string]$Token)
    $body = @{ summary = $Title }

    if ($StartTime) {
        $endT = if ($EndTime) { $EndTime } else {
            $h = [int]($StartTime.Substring(0,2)) + 1
            "$($h.ToString('00')):$($StartTime.Substring(3,2))"
        }
        $body.start = @{ dateTime = "${Date}T${StartTime}:00"; timeZone = "Asia/Tokyo" }
        $body.end   = @{ dateTime = "${Date}T${endT}:00";      timeZone = "Asia/Tokyo" }
    } else {
        $body.start = @{ date = $Date }
        $body.end   = @{ date = $Date }
    }

    if ($NotifyMin -ge 0) {
        $body.reminders = @{ useDefault = $false; overrides = @(@{ method = "popup"; minutes = $NotifyMin }) }
    } else {
        $body.reminders = @{ useDefault = $false; overrides = @() }
    }

    return Invoke-CalAPI -Method POST -Path "/calendars/$CalId/events" -Body $body -Token $Token
}

# ===== Alexa Reminders API =====

function New-AlexaReminder {
    param([string]$ApiEndpoint, [string]$ApiToken, [string]$Title, [string]$Date, [string]$EventTime, [int]$NotifyMin)
    try {
        $baseDt = if ($EventTime) {
            [datetime]::ParseExact("${Date}T${EventTime}", "yyyy-MM-ddTHH:mm", $null)
        } else {
            [datetime]::ParseExact($Date, "yyyy-MM-dd", $null).AddHours(8)
        }
        $remDt = $baseDt.AddMinutes(-$NotifyMin)
        if ($remDt -le (Get-Date)) { return $false }

        $dateJP = "$($baseDt.Month)月$($baseDt.Day)日"
        $timeJP = if ($EventTime) { "$($baseDt.Hour)時$($baseDt.Minute.ToString('00'))分から" } else { "" }
        $text   = "${dateJP}、${timeJP}「${Title}」があります"

        $reqBody = @{
            requestTime      = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
            trigger          = @{ type = "SCHEDULED_ABSOLUTE"; scheduledTime = $remDt.ToString("yyyy-MM-ddTHH:mm:ss"); timeZoneId = "Asia/Tokyo" }
            alertInfo        = @{ spokenInfo = @{ content = @(@{ locale = "ja-JP"; text = $text }) } }
            pushNotification = @{ status = "ENABLED" }
        }
        $hdrs = @{ Authorization = "Bearer $ApiToken"; "Content-Type" = "application/json" }
        Invoke-RestMethod -Uri "$ApiEndpoint/v1/alerts/reminders" -Method POST -Headers $hdrs -Body ($reqBody | ConvertTo-Json -Depth 10 -Compress) -UseBasicParsing | Out-Null
        return $true
    } catch {
        Write-Host "Reminder API Warning: $_" -ForegroundColor Yellow
        return $false
    }
}

# ===== ユーティリティ =====

function Format-DateJP {
    param([string]$DateStr)
    try {
        $d    = [datetime]::ParseExact($DateStr, "yyyy-MM-dd", $null)
        $dows = @("日","月","火","水","木","金","土")
        return "$($d.Month)月$($d.Day)日（$($dows[$d.DayOfWeek.value__])）"
    } catch { return $DateStr }
}

function Resolve-Date {
    param($SlotVal, [int]$DefaultOffset = 1)
    if (-not $SlotVal) { return (Get-Date).AddDays($DefaultOffset).ToString("yyyy-MM-dd") }
    $v = $SlotVal.ToString().Trim()
    if ($v -eq "PRESENT_REF" -or $v -eq "TODAY") { return (Get-Date).ToString("yyyy-MM-dd") }
    if ($v -match "^\d{4}-\d{2}-\d{2}$") { return $v }
    try { return ([datetime]::Parse($v)).ToString("yyyy-MM-dd") }
    catch { return (Get-Date).AddDays($DefaultOffset).ToString("yyyy-MM-dd") }
}

function Get-SlotVal {
    param($Slots, [string]$Name)
    if ($Slots -and $Slots.$Name -and $Slots.$Name.value) { return $Slots.$Name.value }
    return $null
}

# ===== Alexa レスポンス =====

function New-Response {
    param([string]$Text, [bool]$End = $true)
    return @{
        version  = "1.0"
        response = @{
            outputSpeech     = @{ type = "PlainText"; text = $Text }
            shouldEndSession = $End
        }
    } | ConvertTo-Json -Depth 8 -Compress
}

# ===== インテント処理 =====

function Invoke-Intent {
    param($Req)

    $rType = $Req.request.type
    $apiEP = $Req.context.System.apiEndpoint
    $apiTk = $Req.context.System.apiAccessToken

    # LaunchRequest
    if ($rType -eq "LaunchRequest") {
        return New-Response "家族スケジュールです。予定の追加や確認、持ち物の確認ができます。どうぞ。" $false
    }
    if ($rType -eq "SessionEndedRequest") { return New-Response "" $true }

    $intent = $Req.request.intent.name
    $slots  = $Req.request.intent.slots

    # ヘルプ
    if ($intent -eq "AMAZON.HelpIntent") {
        $help = "使い方の例です。「明日の予定は」「今日の持ち物は」「5月3日の10時からイチゴ狩りを登録して」などと話しかけてください。"
        return New-Response $help $false
    }
    if ($intent -in @("AMAZON.CancelIntent","AMAZON.StopIntent")) {
        return New-Response "終了します。" $true
    }

    # Googleトークン確認
    $token = Get-SavedToken
    if (-not $token) {
        return New-Response "Googleカレンダーとの連携設定が必要です。スケジュールアプリの設定画面を開いて、Alexaトークンを送信してください。"
    }

    # ========== 予定追加 ==========
    if ($intent -eq "AddEventIntent") {
        $title     = Get-SlotVal $slots "title"
        $dateSl    = Get-SlotVal $slots "date"
        $startSl   = Get-SlotVal $slots "startTime"
        $date      = Resolve-Date $dateSl 1
        $startTime = if ($startSl) { $startSl.Substring(0,[Math]::Min(5,$startSl.Length)) } else { $null }

        if (-not $title) {
            return New-Response "予定のタイトルが聞き取れませんでした。もう一度お願いします。" $false
        }

        $ev = New-CalendarEvent -Title $title -Date $date -StartTime $startTime -EndTime $null -NotifyMin 30 -Token $token
        if (-not $ev) {
            return New-Response "登録に失敗しました。アプリのGoogleログインが切れているかもしれません。もう一度トークンを送信してください。"
        }

        $dateJP = Format-DateJP $date
        $timeJP = if ($startTime) { $startTime.Replace(":"," 時 ").Split(" ")[0] + "時" + $startTime.Split(":")[1] + "分から" } else { "" }
        $msg    = "${dateJP}、${timeJP}「${title}」を登録しました。"

        # Alexaリマインダー（30分前）
        if ($startTime -and $apiTk -and $apiEP) {
            $ok = New-AlexaReminder -ApiEndpoint $apiEP -ApiToken $apiTk -Title $title -Date $date -EventTime $startTime -NotifyMin 30
            if ($ok) { $msg += "30分前にアレクサからもお知らせします。" }
        }

        Write-Host "$(Get-Date -Format HH:mm:ss) 登録: $title ($date $startTime)" -ForegroundColor Green
        return New-Response $msg
    }

    # ========== 予定確認 ==========
    if ($intent -eq "GetScheduleIntent") {
        $dateSl  = Get-SlotVal $slots "date"
        $date    = Resolve-Date $dateSl 1
        $dateJP  = Format-DateJP $date
        $evItems = Get-EventsForDate -Date $date -Token $token

        if ($evItems.Count -eq 0) {
            return New-Response "${dateJP}の予定はありません。"
        }

        $lines = @()
        foreach ($ev in $evItems) {
            $t = $ev.summary
            if ($ev.start.dateTime) {
                $dt = [datetime]::Parse($ev.start.dateTime)
                $lines += "$($dt.Hour)時$($dt.Minute.ToString('00'))分から、${t}"
            } else {
                $lines += "終日、${t}"
            }
        }
        $count = $evItems.Count
        $text  = "${dateJP}の予定は${count}件です。" + ($lines -join "。次に、") + "。以上です。"
        Write-Host "$(Get-Date -Format HH:mm:ss) 予定確認: $date ($count 件)" -ForegroundColor Cyan
        return New-Response $text
    }

    # ========== 持ち物確認 ==========
    if ($intent -eq "GetBelongingsIntent") {
        $dateSl  = Get-SlotVal $slots "date"
        $date    = Resolve-Date $dateSl 1
        $dateJP  = Format-DateJP $date
        $evItems = Get-EventsForDate -Date $date -Token $token

        $blList = @()
        foreach ($ev in $evItems) {
            $desc = $ev.description
            if ($desc -and $desc -match "持ち物[：:]([^\n]+)") {
                $items2 = $Matches[1] -split "[、,]" |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { $_ -ne "" }
                $blList += $items2
            }
        }
        $blList = $blList | Select-Object -Unique

        if ($blList.Count -eq 0) {
            return New-Response "${dateJP}の持ち物は登録されていません。"
        }

        $text = "${dateJP}の持ち物は、" + ($blList -join "、") + "です。忘れずに。"
        Write-Host "$(Get-Date -Format HH:mm:ss) 持ち物確認: $date ($($blList.Count) 件)" -ForegroundColor Cyan
        return New-Response $text
    }

    return New-Response "すみません、もう一度お願いします。" $false
}

# ===== HTTPサーバー起動 =====

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:${Port}/")
try { $listener.Start() }
catch {
    Write-Host "ポート $Port の起動に失敗しました。管理者権限で実行してください。" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=====================================" -ForegroundColor Green
Write-Host " Alexa サーバー起動 ポート: $Port" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Green
Write-Host " ngrok コマンド: ngrok http $Port" -ForegroundColor Cyan
Write-Host " エンドポイント: https://xxxx.ngrok.io/alexa" -ForegroundColor Cyan
Write-Host " Ctrl+C で停止" -ForegroundColor Yellow
Write-Host ""

while ($listener.IsListening) {
    $ctx    = $listener.GetContext()
    $req    = $ctx.Request
    $resp   = $ctx.Response
    $resp.ContentType = "application/json; charset=utf-8"
    $resp.Headers.Add("Access-Control-Allow-Origin", "*")
    $resp.Headers.Add("Access-Control-Allow-Headers", "Content-Type,Authorization")

    $path   = $req.Url.LocalPath
    $method = $req.HttpMethod

    try {
        if ($method -eq "OPTIONS") {
            $resp.Headers.Add("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
            $resp.StatusCode = 200
            $bytes = [byte[]]@()
        }
        # ヘルスチェック
        elseif ($path -eq "/health" -and $method -eq "GET") {
            $hasToken = if (Test-Path $TokenFile) { "true" } else { "false" }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("{`"status`":`"ok`",`"token`":$hasToken}")
        }
        # Googleトークン保存（アプリから送信される）
        elseif ($path -eq "/save-token" -and $method -eq "POST") {
            $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $body   = $reader.ReadToEnd(); $reader.Dispose()
            Set-Content -Path $TokenFile -Value $body -Encoding UTF8
            Write-Host "$(Get-Date -Format HH:mm:ss) トークン保存完了" -ForegroundColor Green
            $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        }
        # Alexa Webhook
        elseif ($path -eq "/alexa" -and $method -eq "POST") {
            $reader  = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $body    = $reader.ReadToEnd(); $reader.Dispose()
            $reqObj  = $body | ConvertFrom-Json
            $result  = Invoke-Intent $reqObj
            $bytes   = [System.Text.Encoding]::UTF8.GetBytes($result)
        }
        else {
            $resp.StatusCode = 404
            $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"not found"}')
        }

        $resp.ContentLength64 = $bytes.Length
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    catch {
        Write-Host "Server Error: $_" -ForegroundColor Red
        $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"internal error"}')
        try {
            $resp.StatusCode = 500
            $resp.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    }
    finally { try { $resp.OutputStream.Close() } catch {} }
}
