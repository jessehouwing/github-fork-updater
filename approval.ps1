# Records which upstream versions an issue was approved for, so approval can be invalidated when the upstream moves

$script:ApprovalMarkerPattern = '(?s)<!--\s*fork-updater-approval:\s*(?<json>.*?)\s*-->'
$script:ApprovalSectionHeading = "### Versions submitted for approval"

# an issue body is capped at 65536 characters, so only this many refs are listed by name
$script:MaxListedRefs = 25

# padlocks live outside the BMP, so [char] cannot hold them
$script:LockedIcon = [char]::ConvertFromUtf32(0x1F512)
$script:UnlockedIcon = [char]::ConvertFromUtf32(0x1F513)

function GetContentDigest {
    param (
        [string[]] $values = @()
    )

    $joined = (@($values) | Sort-Object) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))
        return [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function NewApprovalSnapshot {
    param (
        [string] $upstream,
        [string] $defaultBranch,
        [string] $headSha,
        [string] $baseSha,
        [string] $compareUrl,
        [string] $upstreamUrl,
        [string] $branchAction = "unknown",
        [string] $releaseMode = "none",
        [object[]] $tags = @(),
        [object[]] $releases = @()
    )

    $tagEntries = @(@($tags) | ForEach-Object { "$($_.name)@$($_.sha)" })

    # a release may be passed as a plain tag name or as an object carrying its immutability
    $releaseItems = @(@($releases) | ForEach-Object {
            if ($_ -is [string]) { [PSCustomObject]@{ name = $_; immutable = $null } }
            else { [PSCustomObject]@{ name = $_.name; immutable = $_.immutable } }
        } | Sort-Object -Property name)

    $changedTags = @(@($tags) | Where-Object { $_.action -and $_.action -ne 'unchanged' } | Sort-Object -Property name)

    # everything except the digests, counts and shas is only used to render the issue, it is never compared
    return [PSCustomObject]@{
        upstream           = $upstream
        defaultBranch      = $defaultBranch
        headSha            = $headSha
        baseSha            = $baseSha
        compareUrl         = $compareUrl
        upstreamUrl        = $upstreamUrl
        branchAction       = $branchAction
        releaseMode        = $releaseMode
        tagCount           = $tagEntries.Count
        tagChangedCount    = $changedTags.Count
        tagList            = @($changedTags | Select-Object -First $script:MaxListedRefs | ForEach-Object { [PSCustomObject]@{ name = $_.name; action = $_.action } })
        tagsDigest         = GetContentDigest -values $tagEntries
        releaseTags        = @($releaseItems | ForEach-Object { $_.name })
        releaseList        = @($releaseItems | Select-Object -First $script:MaxListedRefs)
        releasesDigest     = GetContentDigest -values @($releaseItems | ForEach-Object { $_.name })
    }
}

function FormatRefLinks {
    param (
        [string[]] $names = @(),
        [int] $total,
        [string] $baseUrl,
        [string] $path,
        [string] $overflowUrl
    )

    $shown = @(@($names) | Select-Object -First $script:MaxListedRefs)
    if ($shown.Count -eq 0) {
        return ""
    }

    $links = @($shown | ForEach-Object {
            if ($baseUrl) { "[$_]($baseUrl/$path/$([uri]::EscapeDataString($_)))" } else { "``$_``" }
        })

    $rendered = $links -join ', '

    $remaining = $total - $shown.Count
    if ($remaining -gt 0) {
        $rendered += if ($overflowUrl) { " and [$remaining more]($overflowUrl)" } else { " and $remaining more" }
    }

    return $rendered
}

function FormatTagCell {
    param (
        [object] $snapshot,
        [string] $upstreamBase
    )

    if ($snapshot.tagCount -eq 0) {
        return "none"
    }

    $unchanged = $snapshot.tagCount - $snapshot.tagChangedCount

    if ($snapshot.tagChangedCount -eq 0) {
        return "$($snapshot.tagCount) unchanged"
    }

    # tree/<tag> links to the repository contents at that tag
    $links = @(@($snapshot.tagList) | ForEach-Object {
            $name = if ($upstreamBase) { "[$($_.name)]($upstreamBase/tree/$([uri]::EscapeDataString($_.name)))" } else { "``$($_.name)``" }
            "$name ($($_.action))"
        })

    $rendered = $links -join ', '

    $notListed = $snapshot.tagChangedCount - @($snapshot.tagList).Count
    if ($notListed -gt 0) {
        $rendered += if ($upstreamBase) { " and [$notListed more]($upstreamBase/tags)" } else { " and $notListed more" }
    }

    if ($unchanged -gt 0) {
        $rendered += ", $unchanged unchanged"
    }

    return $rendered
}

function GetShortSha {
    param (
        [string] $sha
    )

    if ([string]::IsNullOrWhiteSpace($sha)) {
        return ""
    }

    if ($sha.Length -le 7) {
        return $sha
    }

    return $sha.Substring(0, 7)
}

function FormatApprovalSnapshot {
    param (
        [object] $snapshot
    )

    $json = $snapshot | ConvertTo-Json -Depth 5 -Compress

    $lines = @()
    $lines += $script:ApprovalSectionHeading
    $lines += ""
    $lines += "| What | Approved version |"
    $lines += "| --- | --- |"

    if ($snapshot.upstreamUrl) {
        $lines += "| Upstream | [``$($snapshot.upstream)``]($($snapshot.upstreamUrl)/$($snapshot.upstream)) |"
    }
    else {
        $lines += "| Upstream | ``$($snapshot.upstream)`` |"
    }

    $branch = "``$($snapshot.defaultBranch)`` at ``$(GetShortSha -sha $snapshot.headSha)``"
    if ($snapshot.branchAction -and $snapshot.branchAction -ne 'unknown') {
        $branch += ", $($snapshot.branchAction)"
    }
    if ($snapshot.compareUrl) {
        $branch += " ([review the incoming commits]($($snapshot.compareUrl)))"
    }
    $lines += "| Branch | $branch |"

    $upstreamBase = if ($snapshot.upstreamUrl) { "$($snapshot.upstreamUrl)/$($snapshot.upstream)" } else { "" }

    $lines += "| Tags | $(FormatTagCell -snapshot $snapshot -upstreamBase $upstreamBase) |"

    if ($snapshot.releaseList.Count -gt 0) {
        $releases = @($snapshot.releaseList | ForEach-Object {
                $lock = if ($null -eq $_.immutable) { "" } elseif ($_.immutable) { "$script:LockedIcon " } else { "$script:UnlockedIcon " }
                if ($upstreamBase) { "$lock[$($_.name)]($upstreamBase/releases/tag/$([uri]::EscapeDataString($_.name)))" } else { "$lock``$($_.name)``" }
            })

        $remaining = $snapshot.releaseTags.Count - $snapshot.releaseList.Count
        $rendered = $releases -join ', '
        if ($remaining -gt 0) {
            $rendered += if ($upstreamBase) { " and [$remaining more]($upstreamBase/releases)" } else { " and $remaining more" }
        }

        $lines += "| Releases | $rendered |"
    }
    elseif ($snapshot.releaseMode -eq 'none') {
        $lines += "| Releases | not synced, set the ``sync-releases`` custom property to change that |"
    }
    else {
        $lines += "| Releases | none matched ``sync-releases: $($snapshot.releaseMode)`` |"
    }

    $lines += ""
    $lines += "$script:LockedIcon immutable release, $script:UnlockedIcon mutable release."

    $lines += ""
    $lines += "Approving this issue applies exactly these versions. If the upstream changes before the **update-fork** label is applied, the label is removed and the changes have to be reviewed again."
    $lines += ""
    $lines += "<!-- fork-updater-approval: $json -->"

    return ($lines -join "`r`n")
}

function ParseApprovalSnapshot {
    param (
        [string] $issueBody
    )

    if ([string]::IsNullOrWhiteSpace($issueBody)) {
        return $null
    }

    if ($issueBody -notmatch $script:ApprovalMarkerPattern) {
        return $null
    }

    try {
        return $Matches.json | ConvertFrom-Json
    }
    catch {
        Write-Warning "Could not read the approved version information from the issue body"
        return $null
    }
}

function UpdateApprovalSnapshotInBody {
    param (
        [string] $issueBody,
        [object] $snapshot
    )

    $section = FormatApprovalSnapshot -snapshot $snapshot

    if ([string]::IsNullOrWhiteSpace($issueBody)) {
        return $section
    }

    $index = $issueBody.IndexOf($script:ApprovalSectionHeading)
    if ($index -ge 0) {
        return "$($issueBody.Substring(0, $index))$section"
    }

    return "$($issueBody.TrimEnd())`r`n`r`n$section"
}

function CompareApprovalSnapshots {
    param (
        [object] $approved,
        [object] $current
    )

    if ($null -eq $approved) {
        return [PSCustomObject]@{
            changed     = $true
            differences = @("No approved version information was found on the issue")
        }
    }

    $differences = @()

    if ($approved.upstream -ne $current.upstream) {
        $differences += "The upstream changed from ``$($approved.upstream)`` to ``$($current.upstream)``"
    }

    if ($approved.defaultBranch -ne $current.defaultBranch) {
        $differences += "The default branch changed from ``$($approved.defaultBranch)`` to ``$($current.defaultBranch)``"
    }

    if ($approved.headSha -ne $current.headSha) {
        $differences += "The default branch moved from ``$($approved.headSha)`` to ``$($current.headSha)``"
    }

    if ($approved.tagsDigest -ne $current.tagsDigest) {
        $differences += "The tags changed, the upstream now has $($current.tagCount) tags where $($approved.tagCount) were approved"
    }

    if ($approved.releasesDigest -ne $current.releasesDigest) {
        $newReleases = @(@($current.releaseTags) | Where-Object { @($approved.releaseTags) -notcontains $_ })
        if ($newReleases.Count -gt 0) {
            $differences += "New releases are available: $($newReleases -join ', ')"
        }
        else {
            $differences += "The set of releases changed since the approval"
        }
    }

    return [PSCustomObject]@{
        changed     = ($differences.Count -gt 0)
        differences = $differences
    }
}
