# Reads the repository custom properties that drive the sync behaviour for mirrors

$script:SyncSettingDefaults = @{
    'upstream-url'                 = $null
    'sync-mode'                    = 'approve'
    'sync-branches'                = 'default'
    'sync-floating-tags'           = 'true'
    'sync-releases'                = 'none'
    'sync-release-assets'          = 'false'
    'verify-upstream-attestations' = 'false'
}

$script:SyncSettingAllowedValues = @{
    'sync-mode'                    = @('approve', 'auto')
    'sync-branches'                = @('default', 'all', 'none')
    'sync-floating-tags'           = @('true', 'false')
    'sync-releases'                = @('none', 'all', 'immutable')
    'sync-release-assets'          = @('true', 'false')
    'verify-upstream-attestations' = @('true', 'false')
}

function GetRepoCustomProperties {
    param (
        [object] $gitHubHost,
        [string] $repoFullName
    )

    $properties = @{}

    $values = CallWebRequest -url "repos/$repoFullName/properties/values" -gitHubHost $gitHubHost
    if ($null -eq $values) {
        return $properties
    }

    foreach ($property in $values) {
        if ($null -ne $property.property_name) {
            $properties[$property.property_name] = $property.value
        }
    }

    return $properties
}

function GetSyncSettings {
    param (
        [hashtable] $properties = @{},
        [string] $repoFullName
    )

    $resolved = @{}

    foreach ($key in $script:SyncSettingDefaults.Keys) {
        $value = $script:SyncSettingDefaults[$key]

        if ($properties.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($properties[$key])) {
            $candidate = ([string]$properties[$key]).Trim().ToLowerInvariant()

            if ($script:SyncSettingAllowedValues.ContainsKey($key) -and $script:SyncSettingAllowedValues[$key] -notcontains $candidate) {
                Write-Warning "Repository [$repoFullName] has unsupported value [$candidate] for custom property [$key], falling back to [$value]"
            }
            else {
                # keep the original casing for the url, normalize the enums
                $value = if ($key -eq 'upstream-url') { ([string]$properties[$key]).Trim() } else { $candidate }
            }
        }

        $resolved[$key] = $value
    }

    return [PSCustomObject]@{
        upstreamUrl                = $resolved['upstream-url']
        syncMode                   = $resolved['sync-mode']
        syncBranches               = $resolved['sync-branches']
        syncFloatingTags           = ($resolved['sync-floating-tags'] -eq 'true')
        syncReleases               = $resolved['sync-releases']
        syncReleaseAssets          = ($resolved['sync-release-assets'] -eq 'true')
        verifyUpstreamAttestations = ($resolved['verify-upstream-attestations'] -eq 'true')
    }
}
