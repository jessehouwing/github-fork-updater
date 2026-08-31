# Syncs a mirror repository (no fork relationship) from a public GitHub upstream

. $PSScriptRoot\github-calls.ps1
. $PSScriptRoot\approval.ps1

$script:FloatingTagPattern = '^(v?\d+(\.\d+)?|latest)$'

function CollectApprovalSnapshot {
    param (
        [object] $upstreamHost,
        [object] $targetHost,
        [string] $repoFullName,
        [string] $upstream,
        [string] $defaultBranch,
        [string] $headSha,
        [string] $baseSha,
        [string] $compareUrl,
        [string] $branchAction = "unknown",
        [object] $syncSettings
    )

    # tags are pushed for forks and mirrors alike, so they are part of what gets approved in both cases
    $upstreamTags = GetTags -gitHubHost $upstreamHost -repoFullName $upstream
    $targetTags = GetTags -gitHubHost $targetHost -repoFullName $repoFullName
    $tags = GetTagActions -upstreamTags $upstreamTags -targetTags $targetTags

    $releases = @()
    if ($syncSettings.syncReleases -ne 'none') {
        $upstreamReleases = @(GetUpstreamReleases -gitHubHost $upstreamHost -repoFullName $upstream | Where-Object { $null -ne $_ -and -not $_.isDraft })
        if ($syncSettings.syncReleases -eq 'immutable') {
            $upstreamReleases = @($upstreamReleases | Where-Object { $_.immutable -eq $true })
        }
        $releases = @($upstreamReleases | Where-Object { $null -ne $_.tagName } | ForEach-Object { [PSCustomObject]@{ name = $_.tagName; immutable = [bool]$_.immutable } })
    }

    return NewApprovalSnapshot -upstream $upstream -defaultBranch $defaultBranch -headSha $headSha -baseSha $baseSha -compareUrl $compareUrl -upstreamUrl $upstreamHost.ServerUrl -branchAction $branchAction -tags $tags -releases $releases -releaseMode $syncSettings.syncReleases
}

function TestIsFloatingTag {
    param (
        [string] $tagName
    )

    return $tagName -match $script:FloatingTagPattern
}

function TestImmutableReleaseError {
    param (
        $errorRecord
    )

    $message = ""
    if ($errorRecord.ErrorDetails -and $errorRecord.ErrorDetails.Message) {
        $message = $errorRecord.ErrorDetails.Message
    }
    elseif ($errorRecord.Exception) {
        $message = $errorRecord.Exception.Message
    }

    return $message -match "was used by an immutable release"
}

function GetUpstreamReleases {
    param (
        [object] $gitHubHost,
        [string] $repoFullName
    )

    $owner, $repo = $repoFullName -split '/', 2

    $query = @"
query(`$owner: String!, `$name: String!, `$first: Int!, `$after: String) {
  repository(owner: `$owner, name: `$name) {
    releases(first: `$first, after: `$after, orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo {
        hasNextPage
        endCursor
      }
      nodes {
        name
        tagName
        description
        isPrerelease
        isDraft
        immutable
        isLatest
        releaseAssets(first: 100) {
          nodes {
            name
            downloadUrl
            contentType
          }
        }
      }
    }
  }
}
"@

    $allReleases = @()
    $cursor = $null

    do {
        $variables = @{
            owner = $owner
            name  = $repo
            first = 100
        }
        if ($cursor) {
            $variables['after'] = $cursor
        }

        $data = CallGraphQlRequest -gitHubHost $gitHubHost -query $query -variables $variables
        $releases = $data.repository.releases

        if (-not $releases -or -not $releases.nodes -or $releases.nodes.Count -eq 0) {
            break
        }

        $allReleases += $releases.nodes
        $cursor = if ($releases.pageInfo.hasNextPage) { $releases.pageInfo.endCursor } else { $null }
    } while ($cursor)

    return $allReleases
}

function TestReleaseImmutability {
    param (
        [object] $gitHubHost,
        [string] $repoFullName,
        [string] $tagName
    )

    $owner, $repo = $repoFullName -split '/', 2

    $query = @"
query(`$owner: String!, `$name: String!, `$tag: String!) {
  repository(owner: `$owner, name: `$name) {
    release(tagName: `$tag) {
      tagName
      isDraft
      immutable
    }
  }
}
"@

    $data = CallGraphQlRequest -gitHubHost $gitHubHost -query $query -variables @{ owner = $owner; name = $repo; tag = $tagName }

    if ($data.repository.release) {
        return $data.repository.release.immutable -eq $true
    }

    return $false
}

function DownloadReleaseAssets {
    param (
        [object[]] $assets,
        [object] $gitHubHost,
        [string] $targetDirectory
    )

    $headers = GetHeaders -gitHubHost $gitHubHost
    $downloaded = @()

    foreach ($asset in $assets) {
        $path = Join-Path $targetDirectory $asset.name
        Write-Debug "Downloading release asset [$($asset.name)]"
        Invoke-WebRequest -Uri $asset.downloadUrl -Headers $headers -OutFile $path -ErrorAction Stop

        $downloaded += [PSCustomObject]@{
            name        = $asset.name
            path        = $path
            contentType = $asset.contentType
        }
    }

    return $downloaded
}

function UploadReleaseAssets {
    param (
        [object[]] $assets,
        [object] $gitHubHost,
        [string] $uploadUrl
    )

    $headers = GetHeaders -gitHubHost $gitHubHost
    # the api returns a uri template like .../assets{?name,label}
    $baseUrl = $uploadUrl -replace '\{[^}]*\}$', ''

    foreach ($asset in $assets) {
        $url = "$baseUrl`?name=$([uri]::EscapeDataString($asset.name))"
        $contentType = if ($asset.contentType) { $asset.contentType } else { "application/octet-stream" }

        Write-Host "Uploading release asset [$($asset.name)]"
        $null = Invoke-WebRequest -Uri $url -Headers $headers -Method Post -InFile $asset.path -ContentType $contentType -ErrorAction Stop
    }
}

function TestUpstreamAttestations {
    param (
        [object[]] $assets,
        [string] $upstream,
        [object] $sourceHost
    )

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warning "The GitHub CLI is not available, cannot verify attestations for [$upstream]"
        return $false
    }

    if ($assets.Count -eq 0) {
        Write-Warning "Release for [$upstream] has no assets to verify attestations for"
        return $false
    }

    $previousToken = $env:GH_TOKEN
    $env:GH_TOKEN = $sourceHost.Token

    try {
        foreach ($asset in $assets) {
            # attestations are bound to the upstream repository, so they are always verified against it
            $output = & gh attestation verify $asset.path --repo $upstream 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Attestation verification failed for [$($asset.name)] of [$upstream]: $output"
                return $false
            }
        }
    }
    finally {
        $env:GH_TOKEN = $previousToken
    }

    return $true
}

function SyncMirrorRefs {
    param (
        [string] $mirror,
        [string] $upstream,
        [object] $sourceHost,
        [object] $targetHost,
        [object] $syncSettings,
        [string] $workingDirectory = "mirror-source"
    )

    $upstreamCloneUrl = GetCloneUrl -gitHubHost $sourceHost -repoFullName $upstream
    $targetCloneUrl = GetCloneUrl -gitHubHost $targetHost -repoFullName $mirror

    Write-Host "Cloning upstream [$upstream] to sync into mirror [$mirror]"

    if (Test-Path $workingDirectory) {
        Remove-Item -Force -Recurse $workingDirectory
    }

    git clone --bare --quiet $upstreamCloneUrl $workingDirectory
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ success = $false; failures = @("Failed to clone upstream [$upstream]") }
    }

    $previousLocation = Get-Location
    Set-Location $workingDirectory

    $failures = @()

    try {
        git remote add target $targetCloneUrl

        $defaultBranch = (git symbolic-ref --short HEAD)

        switch ($syncSettings.syncBranches) {
            'none' {
                Write-Host "Skipping branch sync for [$mirror], sync-branches is set to [none]"
            }
            'all' {
                Write-Host "Pushing all branches to [$mirror]"
                git push target "refs/heads/*:refs/heads/*" --force --prune
                if ($LASTEXITCODE -ne 0) {
                    $failures += "Failed to push branches to [$mirror]"
                }
            }
            default {
                Write-Host "Pushing default branch [$defaultBranch] to [$mirror]"
                git push target "refs/heads/$defaultBranch`:refs/heads/$defaultBranch" --force
                if ($LASTEXITCODE -ne 0) {
                    $failures += "Failed to push branch [$defaultBranch] to [$mirror]"
                }
            }
        }

        # push tags one by one: a bulk push fails atomically when a single tag is protected
        # by an immutable release on the target
        $tags = git for-each-ref --format="%(refname:short)" refs/tags
        foreach ($tag in $tags) {
            if ([string]::IsNullOrWhiteSpace($tag)) {
                continue
            }

            $isFloating = TestIsFloatingTag -tagName $tag
            if ($isFloating -and -not $syncSettings.syncFloatingTags) {
                Write-Debug "Skipping floating tag [$tag], sync-floating-tags is disabled for [$mirror]"
                continue
            }

            if ($isFloating) {
                $pushOutput = git push target "refs/tags/$tag`:refs/tags/$tag" --force 2>&1
            }
            else {
                $pushOutput = git push target "refs/tags/$tag`:refs/tags/$tag" 2>&1
            }

            if ($LASTEXITCODE -ne 0) {
                $outputText = [string]$pushOutput
                # a pinned tag that already exists on the target is expected, not an error
                if ($outputText -match "already exists" -or $outputText -match "non-fast-forward" -or $outputText -match "immutable") {
                    Write-Debug "Tag [$tag] was not updated on [$mirror]: $outputText"
                }
                else {
                    $failures += "Failed to push tag [$tag] to [$mirror]: $outputText"
                }
            }
        }
    }
    finally {
        Set-Location $previousLocation
        Remove-Item -Force -Recurse $workingDirectory -ErrorAction SilentlyContinue
    }

    foreach ($failure in $failures) {
        Write-Warning $failure
    }

    return [PSCustomObject]@{
        success  = ($failures.Count -eq 0)
        failures = $failures
    }
}

function SyncReleases {
    param (
        [string] $mirror,
        [string] $upstream,
        [object] $sourceHost,
        [object] $targetHost,
        [object] $syncSettings
    )

    if ($syncSettings.syncReleases -eq 'none') {
        Write-Host "Skipping release sync for [$mirror], sync-releases is set to [none]"
        return [PSCustomObject]@{ success = $true; created = 0; skipped = 0 }
    }

    $upstreamReleases = @(GetUpstreamReleases -gitHubHost $sourceHost -repoFullName $upstream | Where-Object { $null -ne $_ })
    $existingReleases = CallWebRequest -url "repos/$mirror/releases?per_page=100" -gitHubHost $targetHost
    $existingTags = @($existingReleases | Where-Object { $null -ne $_.tag_name } | ForEach-Object { $_.tag_name })

    $created = 0
    $skipped = 0

    $needsAssets = ($syncSettings.syncReleaseAssets -or $syncSettings.verifyUpstreamAttestations)

    foreach ($release in $upstreamReleases) {
        if ($release.isDraft) {
            continue
        }

        if ($syncSettings.syncReleases -eq 'immutable' -and $release.immutable -ne $true) {
            Write-Debug "Skipping mutable release [$($release.tagName)] for [$mirror]"
            continue
        }

        if ($existingTags -contains $release.tagName) {
            $skipped++
            continue
        }

        $assetDirectory = $null
        $localAssets = @()

        try {
            if ($needsAssets) {
                $upstreamAssets = @($release.releaseAssets.nodes)
                if ($upstreamAssets.Count -gt 0) {
                    $assetDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
                    $null = New-Item -ItemType Directory -Path $assetDirectory
                    $localAssets = @(DownloadReleaseAssets -assets $upstreamAssets -gitHubHost $sourceHost -targetDirectory $assetDirectory)
                }
            }

            if ($syncSettings.verifyUpstreamAttestations) {
                if (-not (TestUpstreamAttestations -assets $localAssets -upstream $upstream -sourceHost $sourceHost)) {
                    Write-Warning "Skipping release [$($release.tagName)] for [$mirror] because the upstream attestations could not be verified"
                    $skipped++
                    continue
                }
            }

            $uploadAssets = @()
            if ($syncSettings.syncReleaseAssets) {
                $uploadAssets = $localAssets
            }

            # publish assets before publishing the release, otherwise an immutable release is sealed without them
            $asDraft = ($uploadAssets.Count -gt 0)
            $makeLatest = if ($release.isLatest) { 'true' } else { 'false' }
            $releaseName = if ($release.name) { $release.name } else { $release.tagName }

            $body = [PSCustomObject]@{
                tag_name   = $release.tagName
                name       = $releaseName
                body       = $release.description
                prerelease = [bool]$release.isPrerelease
                draft      = $asDraft
            }

            if (-not $asDraft) {
                $body | Add-Member -NotePropertyName make_latest -NotePropertyValue $makeLatest
            }

            Write-Host "Creating release [$($release.tagName)] on mirror [$mirror]"
            $createdRelease = CallWebRequest -url "repos/$mirror/releases" -gitHubHost $targetHost -verbToUse "POST" -body $body -throwOnFailure

            if ($asDraft) {
                UploadReleaseAssets -assets $uploadAssets -gitHubHost $targetHost -uploadUrl $createdRelease.upload_url

                $publishBody = [PSCustomObject]@{
                    draft       = $false
                    make_latest = $makeLatest
                }
                $null = CallWebRequest -url "repos/$mirror/releases/$($createdRelease.id)" -gitHubHost $targetHost -verbToUse "PATCH" -body $publishBody -throwOnFailure
            }

            $created++
        }
        catch {
            if (TestImmutableReleaseError -errorRecord $_) {
                Write-Warning "Tag [$($release.tagName)] on [$mirror] was used by an immutable release, skipping"
                $skipped++
            }
            else {
                Write-Warning "Failed to create release [$($release.tagName)] on [$mirror]: $($_.Exception.Message)"
            }
        }
        finally {
            if ($assetDirectory -and (Test-Path $assetDirectory)) {
                Remove-Item -Force -Recurse $assetDirectory
            }
        }
    }

    Write-Host "Release sync for [$mirror] created [$created] releases and skipped [$skipped]"
    return [PSCustomObject]@{ success = $true; created = $created; skipped = $skipped }
}
