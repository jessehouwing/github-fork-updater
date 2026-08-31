# example calls:
# .\init-labels.ps1 -targetToken $env:GitHubPAT -issuesRepository "rajbos/github-fork-updater"

param (
    [string] $userName,
    [string] $PAT,
    [string] $targetToken,
    [string] $targetServerUrl = "https://github.com",
    [string] $issuesRepository
)

. $PSScriptRoot\github-calls.ps1
. $PSScriptRoot\labels.ps1

if ([string]::IsNullOrWhiteSpace($targetToken)) { $targetToken = $PAT }

$targetHost = CreateGitHubHost -serverUrl $targetServerUrl -token $targetToken -userName $userName

Write-Host "Creating the labels used by the fork updater in repository [$issuesRepository] on [$($targetHost.ServerUrl)]"

$failed = 0
foreach ($label in GetRequiredLabels) {
    if (-not (SetLabel -gitHubHost $targetHost -repoFullName $issuesRepository -name $label.name -color $label.color -description $label.description)) {
        $failed++
    }
}

if ($failed -gt 0) {
    Write-Error "Could not create or update [$failed] labels"
    exit 1
}

Write-Host "All labels are up to date"
