#requires -Version 7.0
Set-StrictMode -Version Latest

function Invoke-ImmichNativeProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$ProbeName
    )

    # Qualification only: do not change G_DEBUG in the calling process or in
    # the running server. Preserve inherited flags in this isolated child.
    # https://docs.gtk.org/glib/running.html documents fatal-criticals.
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WorkingDirectory = (Get-Location).ProviderPath
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $ArgumentList) { $start.ArgumentList.Add($argument) }
    $start.Environment['G_DEBUG'] = (@($start.Environment['G_DEBUG'], 'fatal-criticals') | Where-Object { $_ }) -join ','

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        # Drain both streams concurrently; a full stderr pipe must never block
        # stdout/JSON collection (or prevent the child from exiting).
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    } finally { $process.Dispose() }

    # A launcher may reload G_DEBUG from an env file, or a native component may
    # override GLib's fatal mask. Reject its diagnostic even if it exits zero.
    $critical = ($stdout + "`n" + $stderr) -match '\bGLib(?:-[\w]+)*-(?:CRITICAL|ERROR)\b'
    if ($critical -or $exitCode -ne 0) {
        if ($stdout) { Write-Host $stdout -NoNewline }
        $reason = if ($critical) { 'emitted a GLib critical/error diagnostic' } else { 'failed' }
        $message = "$ProbeName $reason (exit code $exitCode)."
        if ($stderr) { $message += "`n$stderr" }
        throw $message
    }
    # Keep diagnostics out of the success stream so callers can parse JSON.
    if ($stderr) { [Console]::Error.Write($stderr) }
    return $stdout
}

Export-ModuleMember -Function Invoke-ImmichNativeProbe
