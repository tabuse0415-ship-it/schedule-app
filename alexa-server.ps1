# alexa-server.ps1
$Port=8082; $Root="C:\Users\tabus\schedule-app"
$TokenFile=Join-Path $Root "alexa-token.json"
$CalId="primary"; $CalBase="https://www.googleapis.com/calendar/v3"
[Console]::OutputEncoding=[System.Text.Encoding]::UTF8

function Get-SavedToken {
    if(Test-Path $TokenFile){$o=Get-Content $TokenFile -Raw -Encoding UTF8|ConvertFrom-Json;return $o.access_token}
    return $null
}
function Invoke-CalAPI($Method,$Path,$Body=$null,$Token){
    $url="$CalBase$Path"; $h=@{Authorization="Bearer $Token";Accept="application/json"}
    $p=@{Uri=$url;Method=$Method;Headers=$h;UseBasicParsing=$true;ErrorAction="Stop"}
    if($Body){$p.Body=($Body|ConvertTo-Json -Depth 10 -Compress);$p.ContentType="application/json; charset=utf-8"}
    try{return Invoke-RestMethod @p}catch{Write-Host "CalAPI Error: $_" -ForegroundColor Red;return $null}
}
function Get-EventsForDate($Date,$Token){
    $tMin=[uri]::EscapeDataString("${Date}T00:00:00+09:00")
    $tMax=[uri]::EscapeDataString("${Date}T23:59:59+09:00")
    $res=Invoke-CalAPI GET "/calendars/$CalId/events?timeMin=$tMin&timeMax=$tMax&singleEvents=true&orderBy=startTime" -Token $Token
    if($res -and $res.items){return @($res.items)}else{return @()}
}
function New-CalendarEvent($Title,$Date,$StartTime,$Token){
    $body=@{summary=$Title}
    if($StartTime){
        $h=[int]($StartTime.Substring(0,2))+1
        $endT="$($h.ToString('00')):$($StartTime.Substring(3,2))"
        $body.start=@{dateTime="${Date}T${StartTime}:00";timeZone="Asia/Tokyo"}
        $body.end=@{dateTime="${Date}T${endT}:00";timeZone="Asia/Tokyo"}
    }else{$body.start=@{date=$Date};$body.end=@{date=$Date}}
    $body.reminders=@{useDefault=$false;overrides=@(@{method="popup";minutes=30})}
    return Invoke-CalAPI POST "/calendars/$CalId/events" $body $Token
}
function Format-DateJP($DateStr){
    try{
        $d=[datetime]::ParseExact($DateStr,"yyyy-MM-dd",$null)
        $dows=@("日","月","火","水","木","金","土")
        return "$($d.Month)月$($d.Day)日（$($dows[$d.DayOfWeek.value__])）"
    }catch{return $DateStr}
}
function Resolve-Date($SlotVal,$DefaultOffset=1){
    if(-not $SlotVal){return (Get-Date).AddDays($DefaultOffset).ToString("yyyy-MM-dd")}
    $v=$SlotVal.ToString().Trim()
    if($v -eq "PRESENT_REF" -or $v -eq "TODAY"){return (Get-Date).ToString("yyyy-MM-dd")}
    if($v -match "^\d{4}-\d{2}-\d{2}$"){return $v}
    try{return ([datetime]::Parse($v)).ToString("yyyy-MM-dd")}
    catch{return (Get-Date).AddDays($DefaultOffset).ToString("yyyy-MM-dd")}
}
function Get-SlotVal($Slots,$Name){
    if($Slots -and $Slots.$Name -and $Slots.$Name.value){return $Slots.$Name.value}
    return $null
}
function New-Response($Text,$End=$true){
    return @{version="1.0";response=@{outputSpeech=@{type="PlainText";text=$Text};shouldEndSession=$End}}|ConvertTo-Json -Depth 8 -Compress
}
function Invoke-Intent($Req){
    $rType=$Req.request.type
    if($rType -eq "LaunchRequest"){return New-Response "家族スケジュールです。予定の追加、確認、持ち物の確認ができます。どうぞ。" $false}
    if($rType -eq "SessionEndedRequest"){return New-Response "" $true}
    $intent=$Req.request.intent.name; $slots=$Req.request.intent.slots
    if($intent -eq "AMAZON.HelpIntent"){return New-Response "「明日の予定は」「今日の持ち物は」「5月3日の10時から運動会を登録して」などと話しかけてください。" $false}
    if($intent -in @("AMAZON.CancelIntent","AMAZON.StopIntent")){return New-Response "終了します。" $true}
    $token=Get-SavedToken
    if(-not $token){return New-Response "Googleトークンが必要です。スケジュールアプリの設定からAlexaトークンを送信してください。"}
    if($intent -eq "AddEventIntent"){
        $title=Get-SlotVal $slots "title"; $date=Resolve-Date (Get-SlotVal $slots "date") 1
        $startSl=Get-SlotVal $slots "startTime"
        $startTime=if($startSl){$startSl.Substring(0,[Math]::Min(5,$startSl.Length))}else{$null}
        if(-not $title){return New-Response "タイトルが聞き取れませんでした。もう一度お願いします。" $false}
        $ev=New-CalendarEvent $title $date $startTime $token
        if(-not $ev){return New-Response "登録に失敗しました。アプリからトークンを再送信してください。"}
        $dateJP=Format-DateJP $date
        $timeJP=if($startTime){"$($startTime.Split(':')[0])時$($startTime.Split(':')[1])分から"}else{""}
        Write-Host "登録: $title ($date $startTime)" -ForegroundColor Green
        return New-Response "${dateJP}、${timeJP}「${title}」を登録しました。"
    }
    if($intent -eq "GetScheduleIntent"){
        $date=Resolve-Date (Get-SlotVal $slots "date") 1; $dateJP=Format-DateJP $date
        $evItems=Get-EventsForDate $date $token
        if($evItems.Count -eq 0){return New-Response "${dateJP}の予定はありません。"}
        $lines=@(); foreach($ev in $evItems){
            $t=$ev.summary
            if($ev.start.dateTime){$dt=[datetime]::Parse($ev.start.dateTime);$lines+="$($dt.Hour)時$($dt.Minute.ToString('00'))分から、${t}"}
            else{$lines+="終日、${t}"}
        }
        Write-Host "予定確認: $date" -ForegroundColor Cyan
        return New-Response "${dateJP}の予定は$($evItems.Count)件です。"+($lines -join "。次に、")+"。以上です。"
    }
    if($intent -eq "GetBelongingsIntent"){
        $date=Resolve-Date (Get-SlotVal $slots "date") 1; $dateJP=Format-DateJP $date
        $evItems=Get-EventsForDate $date $token; $blList=@()
        foreach($ev in $evItems){
            if($ev.description -and $ev.description -match "持ち物[：:]([^\n]+)"){
                $blList+=$Matches[1] -split "[、,]"|ForEach-Object{$_.Trim()}|Where-Object{$_ -ne ""}
            }
        }
        $blList=$blList|Select-Object -Unique
        if($blList.Count -eq 0){return New-Response "${dateJP}の持ち物は登録されていません。"}
        Write-Host "持ち物確認: $date" -ForegroundColor Cyan
        return New-Response "${dateJP}の持ち物は、"+($blList -join "、")+"です。忘れずに。"
    }
    return New-Response "すみません、もう一度お願いします。" $false
}

$listener=New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:${Port}/")
try{$listener.Start()}catch{Write-Host "起動失敗: $_" -ForegroundColor Red;exit 1}
Write-Host "✅ Alexaサーバー起動 ポート:$Port" -ForegroundColor Green
Write-Host "Ctrl+C で停止" -ForegroundColor Yellow

while($listener.IsListening){
    $ctx=$listener.GetContext(); $req=$ctx.Request; $resp=$ctx.Response
    $resp.ContentType="application/json; charset=utf-8"
    $resp.Headers.Add("Access-Control-Allow-Origin","*")
    $resp.Headers.Add("Access-Control-Allow-Headers","Content-Type,Authorization")
    $path=$req.Url.LocalPath; $method=$req.HttpMethod
    try{
        if($method -eq "OPTIONS"){$resp.Headers.Add("Access-Control-Allow-Methods","GET,POST,OPTIONS");$resp.StatusCode=200;$bytes=[byte[]]@()}
        elseif($path -eq "/health" -and $method -eq "GET"){
            $hasToken=if(Test-Path $TokenFile){"true"}else{"false"}
            $bytes=[System.Text.Encoding]::UTF8.GetBytes("{`"status`":`"ok`",`"token`":$hasToken}")
        }
        elseif($path -eq "/save-token" -and $method -eq "POST"){
            $reader=New-Object System.IO.StreamReader($req.InputStream,[System.Text.Encoding]::UTF8)
            $body=$reader.ReadToEnd();$reader.Dispose()
            Set-Content -Path $TokenFile -Value $body -Encoding UTF8
            Write-Host "トークン保存完了" -ForegroundColor Green
            $bytes=[System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        }
        elseif($path -eq "/alexa" -and $method -eq "POST"){
            $reader=New-Object System.IO.StreamReader($req.InputStream,[System.Text.Encoding]::UTF8)
            $body=$reader.ReadToEnd();$reader.Dispose()
            $result=Invoke-Intent ($body|ConvertFrom-Json)
            $bytes=[System.Text.Encoding]::UTF8.GetBytes($result)
        }
        else{$resp.StatusCode=404;$bytes=[System.Text.Encoding]::UTF8.GetBytes('{"error":"not found"}')}
        $resp.ContentLength64=$bytes.Length; $resp.OutputStream.Write($bytes,0,$bytes.Length)
    }catch{
        Write-Host "Error: $_" -ForegroundColor Red
        $e=[System.Text.Encoding]::UTF8.GetBytes('{"error":"internal error"}')
        try{$resp.StatusCode=500;$resp.OutputStream.Write($e,0,$e.Length)}catch{}
    }
    finally{try{$resp.OutputStream.Close()}catch{}}
}