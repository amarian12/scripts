#Requires -Version 5.1
<#
.SYNOPSIS
    Checks all links in an M3U playlist in parallel, removes non-working and duplicate links.
    Optimized for speed on very large playlists and compatible with PowerShell 5.1.

.DESCRIPTION
    This script reads an M3U playlist file, parses all unique URLs, and then uses a runspace pool
    to send parallel HEAD requests to check their accessibility simultaneously. It removes non-working 
    and duplicate links, then writes a new M3U file containing only the unique, working links.

.PARAMETER PlaylistFile
    The full path to the M3U playlist file you want to clean.

.PARAMETER OutputCleanedPlaylistFile
    (Optional) The full path where the cleaned M3U playlist will be saved.
    If not specified, the input file will be overwritten.

.PARAMETER ThrottleLimit
    (Optional) The maximum number of links to check simultaneously. Default is 50.
    Lower this if you experience network issues or are being blocked.

.PARAMETER TimeoutSeconds
    (Optional) The maximum time in seconds to wait for a response for each link. Default is 5.

.PARAMETER UserAgent
    (Optional) The User-Agent string to send with web requests. Some servers require this.
    Default is a common VLC media player User-Agent.

.PARAMETER KeepServerErrors
    (Optional) If specified, links that return an HTTP server error (status 500-599) will be
    kept in the playlist. By default, they are removed.

.EXAMPLE
    .\Clean-M3UPlaylist-PS5.ps1 -PlaylistFile "C:\Playlists\huge_list.m3u"
    This will clean 'huge_list.m3u' in parallel and overwrite the original file.

.EXAMPLE
    .\Clean-M3UPlaylist-PS5.ps1 -PlaylistFile "C:\Playlists\list.m3u" -OutputCleanedPlaylistFile "C:\Playlists\list_clean.m3u" -ThrottleLimit 20 -TimeoutSeconds 10
    Cleans 'list.m3u', saves it to a new file, checking a maximum of 20 links at a time with a 10-second timeout.
#>
param(
    [Parameter(Mandatory=$true, Position=0, HelpMessage="Path to the input M3U playlist file.")]
    [string]$PlaylistFile,

    [Parameter(Mandatory=$false, HelpMessage="Path to save the cleaned output file. If not provided, the input file will be overwritten.")]
    [string]$OutputCleanedPlaylistFile,
    
    [Parameter(Mandatory=$false, HelpMessage="The maximum number of links to check simultaneously.")]
    [int]$ThrottleLimit = 50,

    [Parameter(Mandatory=$false, HelpMessage="The timeout for each web request in seconds.")]
    [int]$TimeoutSeconds = 5,

    [Parameter(Mandatory=$false, HelpMessage="The User-Agent string for web requests.")]
    [string]$UserAgent = 'VLC/3.0.x LibVLC/3.0.x',

    [Parameter(Mandatory=$false, HelpMessage="If specified, keeps links that return HTTP server errors (500-599).")]
    [switch]$KeepServerErrors
)

# --- Main Script Body ---

try {
    # --- Phase 1: Parse Playlist and Identify Unique Links ---
    Write-Host "--- Phase 1: Parsing playlist and identifying unique links... ---" -ForegroundColor Cyan

    if (-not (Test-Path -Path $PlaylistFile -PathType Leaf)) {
        throw [System.IO.FileNotFoundException] "The file '$PlaylistFile' was not found."
    }

    $lines = Get-Content -Path $PlaylistFile -Encoding UTF8
    if (-not $lines) {
        Write-Warning "The input file '$PlaylistFile' is empty."
        return
    }

    $linkJobs = [System.Collections.Generic.List[PSCustomObject]]::new()
    $processedUrls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $hasExtM3uHeader = $false
    $duplicateLinksCount = 0

    if ($lines[0].Trim().StartsWith('#EXTM3U')) {
        $hasExtM3uHeader = $true
        $startIndex = 1
    } else {
        $startIndex = 0
    }

    for ($i = $startIndex; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ([string]::IsNullOrEmpty($line)) { continue }

        $urlPattern = "^https?://[^\s]+"
        $currentUrl = $null
        $extInfLine = $null

        if ($line.StartsWith('#EXTINF')) {
            if ($i + 1 -lt $lines.Count -and $lines[$i+1].Trim() -match $urlPattern) {
                $extInfLine = $line
                $currentUrl = $lines[$i+1].Trim()
                $i++ # Skip the next line since we've processed it
            }
        } elseif ($line -match $urlPattern) {
            $currentUrl = $line
        }
        
        if ($null -ne $currentUrl) {
            if ($processedUrls.Add($currentUrl)) {
                $linkJobs.Add([PSCustomObject]@{
                    Url    = $currentUrl
                    ExtInf = $extInfLine
                })
            } else {
                $duplicateLinksCount++
            }
        }
    }

    Write-Host "Found $($linkJobs.Count) unique links to check."
    Write-Host "Skipped $duplicateLinksCount duplicate links during parsing."
    
    # --- Phase 2: Parallel Link Validation using Runspace Pools ---
    Write-Host "`n--- Phase 2: Checking $($linkJobs.Count) unique links in parallel (Throttle: $ThrottleLimit)... ---" -ForegroundColor Cyan
    
    $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $ThrottleLimit)
    $runspacePool.Open()

    $powershellInstances = [System.Collections.Generic.List[powershell]]::new()
    $asyncResults = [System.Collections.Generic.List[System.IAsyncResult]]::new()

    # Define the script block to be executed in each runspace
    $scriptBlock = {
        param($linkJob, $timeout, $ua, $keepErrors)

        $url = $linkJob.Url
        $isWorking = $false
        $statusCode = 0
        $errorMessage = "Timeout or connection error"

        $params = @{
            Uri         = $url
            Method      = 'Head'
            TimeoutSec  = $timeout
            UserAgent   = $ua
            UseBasicParsing = $true
            ErrorAction = 'Stop'
        }

        try {
            $response = Invoke-WebRequest @params
            $statusCode = $response.StatusCode

            if (($statusCode -ge 200 -and $statusCode -lt 400) -or ($keepErrors -and $statusCode -ge 500)) {
                $isWorking = $true
            } else {
                $errorMessage = "Failed with HTTP Status: $statusCode"
            }
        } catch {
            $errorMessage = $_.Exception.Message
            if ($_.Exception.InnerException) { $errorMessage = $_.Exception.InnerException.Message }
            $statusCode = -1 # Indicate a connection error
        }

        return [PSCustomObject]@{
            Url        = $url
            ExtInf     = $linkJob.ExtInf
            IsWorking  = $isWorking
            StatusCode = $statusCode
            Error      = $errorMessage
        }
    }

    # Create and start a powershell instance for each link job
    foreach ($job in $linkJobs) {
        $ps = [powershell]::Create().AddScript($scriptBlock).AddParameters(@($job, $TimeoutSeconds, $UserAgent, $KeepServerErrors.IsPresent))
        $ps.RunspacePool = $runspacePool
        $powershellInstances.Add($ps)
        $asyncResults.Add($ps.BeginInvoke())
    }

    # Wait for all jobs to complete and collect results
    $results = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $powershellInstances.Count; $i++) {
        $results.Add($powershellInstances[$i].EndInvoke($asyncResults[$i]))
        $powershellInstances[$i].Dispose()
        Write-Progress -Activity "Checking Links" -Status "Completed $($i + 1) of $($powershellInstances.Count)" -PercentComplete (($i + 1) / $powershellInstances.Count * 100)
    }
    Write-Progress -Activity "Checking Links" -Completed

    $runspacePool.Close()
    $runspacePool.Dispose()

    # --- Phase 3: Assemble Cleaned Playlist and Write to File ---
    Write-Host "`n--- Phase 3: Assembling and saving the cleaned playlist... ---" -ForegroundColor Cyan

    $workingLines = [System.Collections.Generic.List[string]]::new()
    if ($hasExtM3uHeader) {
        $workingLines.Add('#EXTM3U')
    }

    $workingResults = $results | Where-Object { $_.IsWorking }

    foreach ($result in $workingResults) {
        if ($null -ne $result.ExtInf) {
            $workingLines.Add($result.ExtInf)
        }
        $workingLines.Add($result.Url)
    }

    $finalOutputFilePath = if ([string]::IsNullOrEmpty($OutputCleanedPlaylistFile)) { $PlaylistFile } else { $OutputCleanedPlaylistFile }
    $workingLines | Set-Content -Path $finalOutputFilePath -Encoding UTF8

    # --- Final Summary ---
    $workingLinksCount = $workingResults.Count
    $nonWorkingLinksCount = $results.Count - $workingLinksCount

    Write-Host "`n--- Summary ---" -ForegroundColor White
    Write-Host "Total unique links checked: $($results.Count)" -ForegroundColor Yellow
    Write-Host "Working links found: $workingLinksCount" -ForegroundColor Green
    Write-Host "Non-working links removed: $nonWorkingLinksCount" -ForegroundColor Red
    Write-Host "Duplicate links skipped: $duplicateLinksCount" -ForegroundColor DarkGray
    Write-Host "Cleaned playlist saved to: '$finalOutputFilePath'" -ForegroundColor Green

} catch [System.IO.FileNotFoundException] {
    Write-Error "Error: The file '$PlaylistFile' was not found."
} catch {
    Write-Error "An unexpected error occurred: $($_.Exception.Message)"
}
