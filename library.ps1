# pull in central calls library
. $PSScriptRoot\github-calls.ps1
. $PSScriptRoot\repo-properties.ps1

function FindAllRepos {
    param (
        [string] $orgName,
        [object] $gitHubHost
    )

    Write-Debug "Finding all repos with orgName: [$orgName] on host [$($gitHubHost.ServerUrl)]"
    $actionsLocation = $orgName
    if ($null -ne $orgName -And $orgName.Length -ne 0) {
        Write-Debug "Finding all repos for org with name [$orgName]"
        $info = CallWebRequest -url "orgs/$orgName/repos?per_page=100" -gitHubHost $gitHubHost

        Write-Debug "Found [$($info.Count)] repositories in [$actionsLocation]"
        if ($null -eq $info -or $info -isnot [System.Object[]]) {
            Write-Warning "Error loading information from org with name [$orgName], trying with user based repository list"
            $info = CallWebRequest -url "users/$orgName/repos?per_page=100" -gitHubHost $gitHubHost
        }
    }
    else {
        $actionsLocation = $gitHubHost.UserName
        Write-Debug "Finding all repos for user with name [$actionsLocation]"
        $info = CallWebRequest -url "users/$actionsLocation/repos?per_page=100" -gitHubHost $gitHubHost
    }

    Write-Host "Found [$($info.Count)] repositories in [$actionsLocation]"
    return $info
}

function ParseRepoFullNameFromUrl {
    param (
        [string] $url
    )

    if ([string]::IsNullOrWhiteSpace($url)) {
        return $null
    }

    $trimmed = $url.Trim().TrimEnd('/')
    $trimmed = $trimmed -replace '\.git$', ''

    if ($trimmed -match '(?<owner>[^/:]+)/(?<repo>[^/]+)$') {
        return "$($Matches.owner)/$($Matches.repo)"
    }

    return $null
}

function ResolveUpstream {
    param (
        [object] $repo,
        [object] $syncSettings
    )

    if ($syncSettings -and -not [string]::IsNullOrWhiteSpace($syncSettings.upstreamUrl)) {
        $fromProperty = ParseRepoFullNameFromUrl -url $syncSettings.upstreamUrl
        if ($fromProperty) {
            Write-Debug "Resolved upstream [$fromProperty] for [$($repo.full_name)] from the upstream-url custom property"
            return $fromProperty
        }
        Write-Warning "Repository [$($repo.full_name)] has an upstream-url property that could not be parsed: [$($syncSettings.upstreamUrl)]"
    }

    if ($repo.fork -and $repo.parent -and $repo.parent.full_name) {
        return $repo.parent.full_name
    }

    # mirror naming convention: org_repo, splitting on the first underscore only
    if ($repo.name -match '^(?<org>[^_]+)_(?<repo>.+)$') {
        $fromConvention = "$($Matches.org)/$($Matches.repo)"
        Write-Debug "Resolved upstream [$fromConvention] for [$($repo.full_name)] from the naming convention"
        return $fromConvention
    }

    Write-Warning "Could not resolve an upstream for repository [$($repo.full_name)], skipping it"
    return $null
}

function BuildCompareUrl {
    param (
        [string] $targetServerUrl,
        [string] $upstreamServerUrl,
        [string] $repoFullName,
        [string] $upstreamFullName,
        [string] $baseSha,
        [string] $headSha,
        [string] $defaultBranch,
        [bool] $isFork
    )

    if ([string]::IsNullOrWhiteSpace($headSha)) {
        return "$upstreamServerUrl/$upstreamFullName/commits/$defaultBranch"
    }

    if ([string]::IsNullOrWhiteSpace($baseSha)) {
        return "$upstreamServerUrl/$upstreamFullName/commit/$headSha"
    }

    if ($isFork) {
        $upstreamOwner = ($upstreamFullName -split '/', 2)[0]
        return "$targetServerUrl/$repoFullName/compare/$baseSha...$($upstreamOwner):$headSha"
    }

    # a mirror is not in the upstream's fork network, but its commits are, so compare inside the upstream
    return "$upstreamServerUrl/$upstreamFullName/compare/$baseSha...$headSha"
}

function ResolveRepoAcrossHosts {
    param (
        [string] $repoFullName,
        [object] $targetHost,
        [object] $sourceHost
    )

    # check the target host (ghe.com) first, only fall back to public GitHub when it is not there
    if ($targetHost -and $targetHost.HasToken -and -not $targetHost.IsPublicGitHub) {
        $onTarget = GetRepoInfo -gitHubHost $targetHost -repoFullName $repoFullName
        if ($null -ne $onTarget) {
            return [PSCustomObject]@{
                repo       = $onTarget
                gitHubHost = $targetHost
            }
        }
    }

    $onSource = GetRepoInfo -gitHubHost $sourceHost -repoFullName $repoFullName
    if ($null -ne $onSource) {
        return [PSCustomObject]@{
            repo       = $onSource
            gitHubHost = $sourceHost
        }
    }

    return $null
}