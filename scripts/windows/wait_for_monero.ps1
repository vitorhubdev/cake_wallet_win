[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][long]$RunId,
    [int]$TimeoutMinutes = 300
)

$ErrorActionPreference = 'Stop'
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $RunId -lt 1 -or
    $TimeoutMinutes -lt 1 -or -not $env:GH_TOKEN) {
    throw 'A repository, workflow run, positive timeout and GitHub token are required.'
}
$headers = @{
    Authorization = "Bearer $env:GH_TOKEN"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$uri = "https://api.github.com/repos/$Repository/actions/runs/$RunId/jobs?filter=all&per_page=100"
$deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
$failures = 0
while ([DateTime]::UtcNow -lt $deadline) {
    try {
        $result = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 30
        $failures = 0
    } catch {
        $failures++
        if ($failures -ge 5) { throw 'Could not read the native build status after five attempts.' }
        Write-Warning 'Temporary failure reading the native build status; retrying.'
        Start-Sleep -Seconds 30
        continue
    }
    # A retry of only failed Windows jobs reuses the successful native job from
    # an earlier attempt. When native was rerun too, prefer its newest job ID.
    $job = @($result.jobs | Where-Object { $_.name -eq 'Build pinned Monero for Windows' } |
        Sort-Object id -Descending | Select-Object -First 1)
    if ($job.Count -eq 1 -and $job[0].status -eq 'completed') {
        if ($job[0].conclusion -ne 'success') {
            throw "Native Monero build ended with $($job[0].conclusion). Inspect that job's logs."
        }
        Write-Host 'The pinned Monero native artifact is ready.'
        exit 0
    }
    Write-Host 'Waiting for the parallel native Monero build...'
    Start-Sleep -Seconds 30
}
throw 'Timed out waiting for the native Monero build.'
