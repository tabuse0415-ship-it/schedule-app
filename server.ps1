# Kill existing process on port 8080
$netstat = netstat -ano 2>$null | Select-String ":8080\s.*LISTENING"
if ($netstat) {
    $pid2 = ($netstat.ToString().Trim() -split '\s+')[-1]
    if ($pid2 -match '^\d+$') {
        Stop-Process -Id ([int]$pid2) -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }
}

$root = "C:\Users\tabus\schedule-app"
$localUrl = "http://localhost:8080/"
$lanUrl   = "http://+:8080/"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($localUrl)
$listener.Prefixes.Add($lanUrl)
$listener.Start()

Write-Host "Server started (PC):     $localUrl" -ForegroundColor Green
Write-Host "Server started (tablet): http://192.168.2.143:8080/" -ForegroundColor Cyan
Write-Host "Root folder: $root" -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop." -ForegroundColor Yellow

Start-Process ($localUrl + "schedule-app.html")

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    $localPath = $request.Url.LocalPath
    if ($localPath -eq "/") { $localPath = "/schedule-app.html" }

    $filePath = Join-Path $root $localPath.TrimStart("/")

    if (Test-Path $filePath -PathType Leaf) {
        $content = [System.IO.File]::ReadAllBytes($filePath)
        $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
        $response.ContentType = switch ($ext) {
            ".html" { "text/html; charset=utf-8" }
            ".js"   { "application/javascript" }
            ".css"  { "text/css" }
            default { "application/octet-stream" }
        }
        $response.ContentLength64 = $content.Length
        $response.OutputStream.Write($content, 0, $content.Length)
    } else {
        $response.StatusCode = 404
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("Not Found: $filePath")
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    $response.OutputStream.Close()
}
