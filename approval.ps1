# Records which upstream versions an issue was approved for, so approval can be invalidated when the upstream moves

$script:ApprovalMarkerPattern = '(?s)<!--\s*fork-updater-approval:\s*(?<json>.*?)\s*-->'
$script:ApprovalSectionHeading = "### Versions submitted for approval"

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
        [string] $releaseMode = "none",
        [object[]] $tags = @(),
        [string[]] $releaseTags = @()
    )

    $tagEntries = @(@($tags) | ForEach-Object { "$($_.name)@$($_.sha)" })
    $sortedReleaseTags = @(@($releaseTags) | Sort-Object)

    # baseSha, compareUrl, upstreamUrl and releaseMode are only used to render the issue, they are never compared
    return [PSCustomObject]@{
        upstream       = $upstream
        defaultBranch  = $defaultBranch
        headSha        = $headSha
        baseSha        = $baseSha
        compareUrl     = $compareUrl
        upstreamUrl    = $upstreamUrl
        releaseMode    = $releaseMode
        tagCount       = $tagEntries.Count
        tagsDigest     = GetContentDigest -values $tagEntries
        releaseTags    = $sortedReleaseTags
        releasesDigest = GetContentDigest -values $sortedReleaseTags
    }
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
    if ($snapshot.compareUrl) {
        $branch += " ([review the incoming commits]($($snapshot.compareUrl)))"
    }
    $lines += "| Branch | $branch |"

    $tags = "$($snapshot.tagCount)"
    if ($snapshot.tagCount -gt 0 -and $snapshot.upstreamUrl) {
        $tags = "[$($snapshot.tagCount)]($($snapshot.upstreamUrl)/$($snapshot.upstream)/tags)"
    }
    $lines += "| Tags | $tags |"

    if ($snapshot.releaseTags.Count -gt 0) {
        $releases = @($snapshot.releaseTags)
        if ($snapshot.upstreamUrl) {
            $releases = @($releases | ForEach-Object { "[$_]($($snapshot.upstreamUrl)/$($snapshot.upstream)/releases/tag/$([uri]::EscapeDataString($_)))" })
        }
        $lines += "| Releases | $($releases -join ', ') |"
    }
    elseif ($snapshot.releaseMode -eq 'none') {
        $lines += "| Releases | not synced, set the ``sync-releases`` custom property to change that |"
    }
    else {
        $lines += "| Releases | none matched ``sync-releases: $($snapshot.releaseMode)`` |"
    }

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
