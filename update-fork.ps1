# example calls:
# .\update-fork.ps1 -orgName "rajbos-actions" -userName "xxx" -PAT $env:GitHubPAT $issueTitle "Parent repository for [rajbos/azure-docs] has updates available"

param (
    [string] $orgName,
    [string] $userName,
    [string] $PAT,
    [string] $sourceToken,
    [string] $targetToken,
    [string] $targetServerUrl = "https://github.com",
    [string] $issuesRepository,
    [string] $issueTitle,
    [int] $issueId,
    [string] $repoName
)

# include local library code
. $PSScriptRoot\github-calls.ps1
. $PSScriptRoot\library.ps1
. $PSScriptRoot\sync-mirror.ps1

# -PAT is the legacy single token parameter and seeds both sides when the new ones are absent
if ([string]::IsNullOrWhiteSpace($sourceToken)) { $sourceToken = $PAT }
if ([string]::IsNullOrWhiteSpace($targetToken)) { $targetToken = $PAT }

$sourceHost = CreateGitHubHost -serverUrl "https://github.com" -token $sourceToken
$targetHost = CreateGitHubHost -serverUrl $targetServerUrl -token $targetToken -userName $userName

function ParseIssueTitle {
    param (
        [string] $issueTitle
    )

    $start = $issueTitle.IndexOf("[")+1;
    $end =  $issueTitle.IndexOf("]");

    $fork = $issueTitle.Substring($start, $end-$start)
    Write-Host "Found fork repo name to update [$fork]"
    return $fork
}

$sourceDirectory = "source"

function UpdateFork {
    param (
        [string] $fork,
        [object] $gitHubHost
    )

    $forkUrl = GetForkCloneUrl -fork $fork -gitHubHost $gitHubHost

    # set user settings
    git config --global user.email "noreply@githubupdater.com"
    git config --global user.name "GitHub Fork Updater"

    # create new temp dir to hold the fork
    New-Item -ItemType Directory $sourceDirectory
    Set-Location $sourceDirectory
    Write-Host "Clone fork from url [$forkUrl]"
    git clone $forkUrl .

    $parent = GetParentInfo -fork $fork -gitHubHost $gitHubHost
    Write-Host "Found forks parent with url [$($parent.parentUrl)]"

    # add remote to the parent
    git remote add github $parent.parentUrl

    # fetch the changes from the parent
    Write-Host "Fetching changes from parent repo"
    git fetch github $parent.parentDefaultBranch --tags --force

    # make sure you are on the right branch
    Write-Host "Pulling all changes from the parent on branch [$($parent.parentDefaultBranch)]"
    git checkout $parent.parentDefaultBranch

    # merge in any changes from the branch
    Write-Host "Merging changes from parent repo"
    git merge github/$($parent.parentDefaultBranch) --ff

    # check if there are any merge conflicts
    $mergeConflict = git status | Select-String "both modified"
    if ($mergeConflict) {
        Write-Host "Found merge conflicts, aborting the update"
        git merge --abort
        return 1
    }

    # push the changes back to your repo
    Write-Host "Pushing changes back to fork"
    git push origin $parent.parentDefaultBranch --tags --force

    Write-Host "Completed fork update"
}

function Main {
    param (
        [string] $issueTitle,
        [object] $sourceHost,
        [object] $targetHost,
        [int] $issueId,
        [string] $issuesRepository
    )

    Write-Host "Starting the update for issue with title [$issueTitle] having number [$issueId] on repository [$issuesRepository]"

    $workflowRunUrl = "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
    Write-Host "Found workflowRunUrl: [$workflowRunUrl]"

    $fork = ParseIssueTitle -issueTitle $issueTitle

    $repo = GetRepoInfo -gitHubHost $targetHost -repoFullName $fork
    if ($null -eq $repo) {
        Write-Host "Could not find repository [$fork] on [$($targetHost.ServerUrl)], halting execution"
        AddCommentToIssue -number $issueId -message ":warning: Could not find repository [$fork]" -repoName $issuesRepository -gitHubHost $targetHost
        return 1
    }

    $properties = GetRepoCustomProperties -gitHubHost $targetHost -repoFullName $fork
    $syncSettings = GetSyncSettings -properties $properties -repoFullName $fork
    $upstream = ResolveUpstream -repo $repo -syncSettings $syncSettings

    if ($null -eq $upstream) {
        AddCommentToIssue -number $issueId -message ":warning: Could not resolve an upstream repository for [$fork]" -repoName $issuesRepository -gitHubHost $targetHost
        return 1
    }

    $resolved = ResolveRepoAcrossHosts -repoFullName $upstream -targetHost $targetHost -sourceHost $sourceHost
    if ($null -eq $resolved) {
        AddCommentToIssue -number $issueId -message ":warning: Could not find the upstream repository [$upstream]" -repoName $issuesRepository -gitHubHost $targetHost
        return 1
    }

    $upstreamHost = $resolved.gitHubHost
    $defaultBranch = $resolved.repo.default_branch
    $branchCommit = GetBranchCommit -gitHubHost $upstreamHost -parent $upstream -branchName $defaultBranch

    $repoBranch = if ($repo.default_branch) { $repo.default_branch } else { $defaultBranch }
    $baseCommit = GetBranchCommit -gitHubHost $targetHost -parent $repo.full_name -branchName $repoBranch
    $compareUrl = BuildCompareUrl -targetServerUrl $targetHost.ServerUrl -upstreamServerUrl $upstreamHost.ServerUrl -repoFullName $repo.full_name -upstreamFullName $upstream -baseSha $baseCommit.sha -headSha $branchCommit.sha -defaultBranch $defaultBranch -isFork ([bool]$repo.fork)

    # only apply what was actually reviewed: re-check the upstream against the versions recorded on the issue
    $currentSnapshot = CollectApprovalSnapshot -upstreamHost $upstreamHost -upstream $upstream -defaultBranch $defaultBranch -headSha $branchCommit.sha -baseSha $baseCommit.sha -compareUrl $compareUrl -syncSettings $syncSettings -isFork ([bool]$repo.fork)

    $issue = GetIssue -gitHubHost $targetHost -repoFullName $issuesRepository -number $issueId
    $approved = ParseApprovalSnapshot -issueBody $issue.body
    $comparison = CompareApprovalSnapshots -approved $approved -current $currentSnapshot

    if ($comparison.changed) {
        Write-Host "The upstream changed since the approval, a new approval is required"

        UpdateIssueBody -gitHubHost $targetHost -repoFullName $issuesRepository -number $issueId -body (UpdateApprovalSnapshotInBody -issueBody $issue.body -snapshot $currentSnapshot)
        RemoveLabelFromIssue -gitHubHost $targetHost -repoFullName $issuesRepository -number $issueId -label "update-fork"

        $message = ":warning: The update was **not** applied. The upstream repository changed since this issue was approved:`r`n- $($comparison.differences -join "`r`n- ")`r`n`r`nReview the incoming changes again and re-apply the **update-fork** label to approve the new version."
        AddCommentToIssue -number $issueId -message $message -repoName $issuesRepository -gitHubHost $targetHost
        return 0
    }

    AddCommentToIssue -number $issueId -message "Updating the fork with the approved changes from the parent repository through [update-workflow]($workflowRunUrl)." -repoName $issuesRepository -gitHubHost $targetHost

    if ($repo.fork) {
        $forkResult = UpdateFork -fork $fork -gitHubHost $targetHost
        if ($forkResult -eq 1) {
            Write-Host "Error with the update of the fork, halting execution"
            AddCommentToIssue -number $issueId -message ":warning: Found merge conflicts, aborting the update" -repoName $issuesRepository -gitHubHost $targetHost
            return 1
        }

        Write-Host "Cleaning up"
        Set-Location ..
        Remove-Item -Force -Recurse $sourceDirectory
    }
    else {
        $refResult = SyncMirrorRefs -mirror $fork -upstream $upstream -sourceHost $sourceHost -targetHost $targetHost -syncSettings $syncSettings
        $null = SyncReleases -mirror $fork -upstream $upstream -sourceHost $sourceHost -targetHost $targetHost -syncSettings $syncSettings

        if (-not $refResult.success) {
            AddCommentToIssue -number $issueId -message ":warning: Some references could not be synced:`r`n- $($refResult.failures -join "`r`n- ")" -repoName $issuesRepository -gitHubHost $targetHost
            return 1
        }
    }

    # make sure we are back where we started (for easier local testing)
    Set-Location $PSScriptRoot

    AddCommentToIssue -number $issueId -message "Fork has been updated" -repoName $issuesRepository -gitHubHost $targetHost
    CloseIssue -number $issueId -issuesRepositoryName $issuesRepository -gitHubHost $targetHost
}

# uncomment for local testing
#$issueTitle = "Parent repository for [rajbos/pickles] has updates available"; $PAT=$env:GitHubPAT; $repoName = "rajbos/github-fork-updater"; $issueId = 24

$result = Main -issueTitle $issueTitle -sourceHost $sourceHost -targetHost $targetHost -issueId $issueId -issuesRepository $issuesRepository
if ($result -eq 1) {
    Write-Host "Error with the update of the fork, returning with failure"
    exit 1
}
