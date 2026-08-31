# example calls:
# .\updater.ps1 -orgName "rajbos-actions" -userName "xxx" -PAT $env:GitHubPAT
param (
    [string] $orgName,
    [string] $userName,
    [string] $PAT,
    [string] $sourceToken,
    [string] $targetToken,
    [string] $targetServerUrl = "https://github.com",
    [string] $issuesRepository
)

# pull in central calls library
. $PSScriptRoot\github-calls.ps1
. $PSScriptRoot\library.ps1
. $PSScriptRoot\sync-mirror.ps1

# placeholder to enable testing locally
$testingLocally = $false

# -PAT is the legacy single token parameter and seeds both sides when the new ones are absent
if ([string]::IsNullOrWhiteSpace($sourceToken)) { $sourceToken = $PAT }
if ([string]::IsNullOrWhiteSpace($targetToken)) { $targetToken = $PAT }

$sourceHost = CreateGitHubHost -serverUrl "https://github.com" -token $sourceToken
$targetHost = CreateGitHubHost -serverUrl $targetServerUrl -token $targetToken -userName $userName

function GetUpstreamState {
    param (
        [object] $repo,
        [object] $sourceHost,
        [object] $targetHost,
        [object] $syncSettings
    )

    # the repository list endpoints return a minimal representation that omits the parent, so reload the fork in full
    if ($repo.fork -and $null -eq $repo.parent) {
        $full = GetRepoInfo -gitHubHost $targetHost -repoFullName $repo.full_name
        if ($null -ne $full) {
            $repo = $full
        }
    }

    $upstream = ResolveUpstream -repo $repo -syncSettings $syncSettings
    if ($null -eq $upstream) {
        return $null
    }

    $resolved = ResolveRepoAcrossHosts -repoFullName $upstream -targetHost $targetHost -sourceHost $sourceHost
    if ($null -eq $resolved) {
        Write-Warning "Could not find upstream [$upstream] for [$($repo.full_name)] on either host"
        return $null
    }

    $upstreamInfo = $resolved.repo
    $upstreamHost = $resolved.gitHubHost
    $defaultBranch = $upstreamInfo.default_branch

    Write-Host "Found upstream [$($upstreamInfo.full_name)] on [$($upstreamHost.ServerUrl)] for [$($repo.full_name)], default branch [$defaultBranch]"

    $branchCommit = GetBranchCommit -gitHubHost $upstreamHost -parent $upstreamInfo.full_name -branchName $defaultBranch

    # the commit the target is on today, so the compare link keeps showing what was reviewed even after the upstream moves
    $repoBranch = if ($repo.default_branch) { $repo.default_branch } else { $defaultBranch }
    $baseCommit = GetBranchCommit -gitHubHost $targetHost -parent $repo.full_name -branchName $repoBranch

    $compareUrl = BuildCompareUrl -targetServerUrl $targetHost.ServerUrl -upstreamServerUrl $upstreamHost.ServerUrl -repoFullName $repo.full_name -upstreamFullName $upstreamInfo.full_name -baseSha $baseCommit.sha -headSha $branchCommit.sha -defaultBranch $defaultBranch -isFork ([bool]$repo.fork)

    return [PSCustomObject]@{
        parentUrl       = $upstreamInfo.html_url
        parentArchived  = $upstreamInfo.archived
        upstreamName    = $upstreamInfo.full_name
        upstreamHost    = $upstreamHost
        isFork          = [bool]$repo.fork
        defaultBranch   = $defaultBranch
        headSha         = $branchCommit.sha
        baseSha         = $baseCommit.sha
        lastPushRepo    = $repo.pushed_at
        lastPushParent  = $branchCommit.date
        updateAvailable = ($repo.pushed_at -lt $branchCommit.date)
        compareUrl      = $compareUrl
    }
}

function TestReleasesOutOfSync {
    param (
        [string] $mirror,
        [string] $upstream,
        [object] $sourceHost,
        [object] $targetHost,
        [object] $syncSettings
    )

    if ($syncSettings.syncReleases -eq 'none') {
        return $false
    }

    $upstreamReleases = GetUpstreamReleases -gitHubHost $sourceHost -repoFullName $upstream | Where-Object { -not $_.isDraft }
    if ($syncSettings.syncReleases -eq 'immutable') {
        $upstreamReleases = $upstreamReleases | Where-Object { $_.immutable -eq $true }
    }

    $existingReleases = CallWebRequest -url "repos/$mirror/releases?per_page=100" -gitHubHost $targetHost
    $existingTags = @($existingReleases | ForEach-Object { $_.tag_name })

    $missing = @($upstreamReleases | Where-Object { $existingTags -notcontains $_.tagName })
    if ($missing.Count -gt 0) {
        Write-Host "Found [$($missing.Count)] releases on [$upstream] that are missing on [$mirror]"
        return $true
    }

    return $false
}

function SyncRepo {
    param (
        [object] $repoInfo,
        [object] $sourceHost,
        [object] $targetHost
    )

    Write-Host "Syncing mirror [$($repoInfo.repoName)] from upstream [$($repoInfo.upstreamName)]"

    $refResult = SyncMirrorRefs -mirror $repoInfo.repoName -upstream $repoInfo.upstreamName -sourceHost $sourceHost -targetHost $targetHost -syncSettings $repoInfo.syncSettings
    $releaseResult = SyncReleases -mirror $repoInfo.repoName -upstream $repoInfo.upstreamName -sourceHost $sourceHost -targetHost $targetHost -syncSettings $repoInfo.syncSettings

    return ($refResult.success -and $releaseResult.success)
}


function CheckAllReposInOrg {
    param (
        [string] $orgName,
        [object] $sourceHost,
        [object] $targetHost
    )

    Write-Host "Running a check on all repositories inside of organization [$orgName] on [$($targetHost.ServerUrl)]"

    $repos = FindAllRepos -orgName $orgName -gitHubHost $targetHost

    # create hastable
    $reposWithUpdates = @()

    foreach ($repo in $repos) {
        if ($repo.archived -or $repo.disabled) {
            Write-Host "Skipping repository [$($repo.full_name)] since it has been archived or is disabled"
            continue
        }

        Write-Host "Checking repository [$($repo.full_name)]"

        $properties = GetRepoCustomProperties -gitHubHost $targetHost -repoFullName $repo.full_name
        $syncSettings = GetSyncSettings -properties $properties -repoFullName $repo.full_name

        $repoInfo = GetUpstreamState -repo $repo -sourceHost $sourceHost -targetHost $targetHost -syncSettings $syncSettings
        if ($null -eq $repoInfo) {
            continue
        }

        $releasesOutOfSync = $false
        if (-not $repoInfo.isFork) {
            $releasesOutOfSync = TestReleasesOutOfSync -mirror $repo.full_name -upstream $repoInfo.upstreamName -sourceHost $repoInfo.upstreamHost -targetHost $targetHost -syncSettings $syncSettings
        }

        if ($repoInfo.updateAvailable -or $repoInfo.parentArchived -or $releasesOutOfSync) {
            Write-Host "Found new updates in the upstream repository [$($repoInfo.parentUrl)], compare the changes with [$($repoInfo.compareUrl)]"

            $snapshot = CollectApprovalSnapshot -upstreamHost $repoInfo.upstreamHost -upstream $repoInfo.upstreamName -defaultBranch $repoInfo.defaultBranch -headSha $repoInfo.headSha -baseSha $repoInfo.baseSha -compareUrl $repoInfo.compareUrl -syncSettings $syncSettings -isFork $repoInfo.isFork

            $repoData = [PSCustomObject]@{
                repoName       = $repo.full_name
                parentArchived = $repoInfo.parentArchived
                parentUrl      = $repoInfo.parentUrl
                compareUrl     = $repoInfo.compareUrl
                upstreamName   = $repoInfo.upstreamName
                isFork         = $repoInfo.isFork
                syncSettings   = $syncSettings
                snapshot       = $snapshot
            }

            $reposWithUpdates += $repoData
        }
        else {
            Write-Host "No updates available from upstream"
        }
    }

    Write-Host "Found [$($reposWithUpdates.Count)] repositories with available updates"
    if ($null -ne $env:GITHUB_STEP_SUMMARY) {
        Write-Output "Found [$($reposWithUpdates.Count)] repositories with available updates" >> $env:GITHUB_STEP_SUMMARY
    }
    return $reposWithUpdates
}

function CreateIssueFor { 
    param (
        [object] $repoInfo,
        [string] $issuesRepositoryName,
        [object] $existingIssues,
        [object] $gitHubHost
    )

    $labels = ""
    if ($repoInfo.parentArchived) {
        $issueTitle = "Parent repository for [$($repoInfo.repoName)] is archived"
        $body = "The parent repository for **[$($repoInfo.repoName)]($($repoInfo.parentUrl))** is archived. `r`n### Important!`r`nConsider revisiting the usage and find alternatives.`r`nLeave this issue open or it will be recreated."
        $labels = "parent-archived"
    } else {
        $body = "The parent repository for **[$($repoInfo.repoName)]($($repoInfo.parentUrl))** has updates available. `r`n### Important!`r`nClick on this [compare link]($($repoInfo.compareUrl)) to check the incoming changes before updating the fork. `r`n `r`n### To update the fork`r`nAdd the label **update-fork** to this issue to update the fork automatically."
        $issueTitle = "Parent repository for [$($repoInfo.repoName)] has updates available"
        $labels = "update-available"
    }

    if ($repoInfo.snapshot) {
        $body = UpdateApprovalSnapshotInBody -issueBody $body -snapshot $repoInfo.snapshot
    }

    $existingIssueForRepo = $existingIssues | Where-Object {$_.title -eq $issueTitle}

    if ($null -eq $existingIssueForRepo) {
        CreateNewIssueForRepo -issuesRepositoryName $issuesRepositoryName -title $issueTitle -body $body -gitHubHost $gitHubHost -labels $labels
        return
    }

    $approved = ParseApprovalSnapshot -issueBody $existingIssueForRepo.body
    $comparison = CompareApprovalSnapshots -approved $approved -current $repoInfo.snapshot

    if (-not $comparison.changed) {
        Write-Host "Issue with title [$issueTitle] already exists and still covers the current upstream version"
        return
    }

    # the upstream moved on, so whatever was reviewed before is no longer what would be applied
    Write-Host "Upstream for [$($repoInfo.repoName)] changed since issue [$($existingIssueForRepo.number)] was created, resetting the approval"

    UpdateIssueBody -gitHubHost $gitHubHost -repoFullName $issuesRepositoryName -number $existingIssueForRepo.number -body $body
    RemoveLabelFromIssue -gitHubHost $gitHubHost -repoFullName $issuesRepositoryName -number $existingIssueForRepo.number -label "update-fork"

    $message = ":warning: The upstream repository changed since this issue was created, so the previous approval no longer applies:`r`n- $($comparison.differences -join "`r`n- ")`r`n`r`nReview the changes again and re-apply the **update-fork** label."
    AddCommentToIssue -gitHubHost $gitHubHost -repoName $issuesRepositoryName -number $existingIssueForRepo.number -message $message
}

function CreateIssuesForReposWithUpdates {
    param(
         [object] $reposWithUpdates,
         [string] $issuesRepository,
         [object] $gitHubHost
    )

    $existingIssues = CallWebRequest -url "repos/$issuesRepository/issues" -gitHubHost $gitHubHost

    Write-Host "Found $($existingIssues.Count) existing issues in issues repository [$issuesRepository]"

    foreach ($repo in $reposWithUpdates) {        
        CreateIssueFor -repoInfo $repo -issuesRepositoryName $issuesRepository -existingIssues $existingIssues -gitHubHost $gitHubHost
    }
}

function ProcessReposWithUpdates {
    param (
        [object] $reposWithUpdates,
        [string] $issuesRepository,
        [object] $sourceHost,
        [object] $targetHost
    )

    # repos configured with sync-mode: auto are synced straight away, the rest go through an issue
    $autoSync = @($reposWithUpdates | Where-Object { $_.syncSettings.syncMode -eq 'auto' -and -not $_.isFork })
    $needsApproval = @($reposWithUpdates | Where-Object { $_.syncSettings.syncMode -ne 'auto' -or $_.isFork })

    foreach ($repo in $autoSync) {
        $null = SyncRepo -repoInfo $repo -sourceHost $sourceHost -targetHost $targetHost
    }

    if ($needsApproval.Count -gt 0) {
        CreateIssuesForReposWithUpdates -reposWithUpdates $needsApproval -issuesRepository $issuesRepository -gitHubHost $targetHost
    }
}

function TestLocally {
    param (
        [string] $orgName,
        [object] $sourceHost,
        [object] $targetHost,
        [string] $issuesRepository
    )

    $reposWithUpdates = CheckAllReposInOrg -orgName $orgName -sourceHost $sourceHost -targetHost $targetHost

    if ($reposWithUpdates.Count -gt 0) {
        ProcessReposWithUpdates -reposWithUpdates $reposWithUpdates -issuesRepository $issuesRepository -sourceHost $sourceHost -targetHost $targetHost
    }
}

# uncomment to test locally
#$orgName = "rajbos"; $userName = "xxx"; $PAT = $env:GitHubPAT; $testingLocally = $true; $issuesRepository = "rajbos/github-fork-updater"

if ($testingLocally) {
    TestLocally -orgName $orgName -sourceHost $sourceHost -targetHost $targetHost -issuesRepository $issuesRepository
}
else {
    # production flow:
    $reposWithUpdates = CheckAllReposInOrg -orgName $orgName -sourceHost $sourceHost -targetHost $targetHost

    if ($reposWithUpdates.Count -gt 0) {
        ProcessReposWithUpdates -reposWithUpdates $reposWithUpdates -issuesRepository $issuesRepository -sourceHost $sourceHost -targetHost $targetHost
    }

    return $reposWithUpdates
}
