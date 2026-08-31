BeforeAll {
    . $PSScriptRoot\..\library.ps1
    . $PSScriptRoot\..\sync-mirror.ps1
    . $PSScriptRoot\..\labels.ps1
}

Describe "GetRequiredLabels" {
    It "defines the <name> label the code applies" -ForEach @(
        @{ name = "update-available" }
        @{ name = "parent-archived" }
        @{ name = "update-fork" }
    ) {
        GetRequiredLabels | Where-Object { $_.name -eq $name } | Should -Not -BeNullOrEmpty
    }

    It "gives every label a colour and a description GitHub accepts" {
        foreach ($label in GetRequiredLabels) {
            $label.color | Should -Match '^[0-9a-f]{6}$'
            $label.description | Should -Not -BeNullOrEmpty
            $label.description.Length | Should -BeLessOrEqual 100
        }
    }
}

Describe "MapCompareStatus" {
    It "maps <status> to <expected>" -ForEach @(
        @{ status = "identical"; expected = "up to date" }
        @{ status = "ahead"; expected = "fast-forward" }
        @{ status = "behind"; expected = "force push required" }
        @{ status = "diverged"; expected = "force push required" }
        @{ status = $null; expected = "unknown" }
    ) {
        MapCompareStatus -status $status | Should -Be $expected
    }
}

Describe "GetTagActions" {
    It "marks a tag the target does not have as new" {
        $result = GetTagActions -upstreamTags @([PSCustomObject]@{ name = "v2"; sha = "aaa" }) -targetTags @()
        $result[0].action | Should -Be "new"
    }

    It "marks a tag that points elsewhere on the target as needing a force push" {
        $result = GetTagActions -upstreamTags @([PSCustomObject]@{ name = "v1"; sha = "bbb" }) -targetTags @([PSCustomObject]@{ name = "v1"; sha = "aaa" })
        $result[0].action | Should -Be "force push required"
    }

    It "marks an identical tag as unchanged" {
        $result = GetTagActions -upstreamTags @([PSCustomObject]@{ name = "v1"; sha = "aaa" }) -targetTags @([PSCustomObject]@{ name = "v1"; sha = "aaa" })
        $result[0].action | Should -Be "unchanged"
    }

    It "treats a target without any tags as new tags" {
        # GetTags returns @() for a repo without tags, which unrolls to $null on the way in
        $result = GetTagActions -upstreamTags @([PSCustomObject]@{ name = "v1"; sha = "aaa" }) -targetTags $null
        $result.Count | Should -Be 1
        $result[0].action | Should -Be "new"
    }

    It "returns nothing when the upstream has no tags" {
        GetTagActions -upstreamTags $null -targetTags $null | Should -BeNullOrEmpty
    }
}

Describe "BuildCompareUrl" {
    It "pins a fork comparison to both commits inside the fork network" {
        $url = BuildCompareUrl -targetServerUrl "https://github.com" -upstreamServerUrl "https://github.com" `
            -repoFullName "jessehouwing/azure-pipelines-tasks" -upstreamFullName "microsoft/azure-pipelines-tasks" `
            -baseSha "aaa111" -headSha "bbb222" -defaultBranch "master" -isFork $true

        $url | Should -Be "https://github.com/jessehouwing/azure-pipelines-tasks/compare/aaa111...microsoft:bbb222"
    }

    It "compares a mirror inside the upstream repository, since it is not in the fork network" {
        $url = BuildCompareUrl -targetServerUrl "https://contoso.ghe.com" -upstreamServerUrl "https://github.com" `
            -repoFullName "mirrors/actions_checkout" -upstreamFullName "actions/checkout" `
            -baseSha "aaa111" -headSha "bbb222" -defaultBranch "main" -isFork $false

        $url | Should -Be "https://github.com/actions/checkout/compare/aaa111...bbb222"
    }

    It "falls back to the commit when the target has no commit yet" {
        $url = BuildCompareUrl -upstreamServerUrl "https://github.com" -upstreamFullName "actions/checkout" `
            -headSha "bbb222" -defaultBranch "main" -isFork $false

        $url | Should -Be "https://github.com/actions/checkout/commit/bbb222"
    }

    It "falls back to the commit list when the upstream head is unknown" {
        $url = BuildCompareUrl -upstreamServerUrl "https://github.com" -upstreamFullName "actions/checkout" `
            -defaultBranch "main" -isFork $false

        $url | Should -Be "https://github.com/actions/checkout/commits/main"
    }
}

Describe "Approval snapshots" {
    BeforeAll {
        $script:tags = @(
            [PSCustomObject]@{ name = "v1.0.0"; sha = "aaa" }
            [PSCustomObject]@{ name = "v1"; sha = "aaa" }
        )
    }

    It "round trips through the issue body" {
        $snapshot = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -tags $tags -releases @("v1.0.0")
        $body = UpdateApprovalSnapshotInBody -issueBody "Some description" -snapshot $snapshot

        $parsed = ParseApprovalSnapshot -issueBody $body

        $parsed.upstream | Should -Be "actions/checkout"
        $parsed.headSha | Should -Be "abc123"
        $parsed.tagsDigest | Should -Be $snapshot.tagsDigest
        (CompareApprovalSnapshots -approved $parsed -current $snapshot).changed | Should -BeFalse
    }

    It "keeps the original description above the approval section" {
        $snapshot = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123"
        $body = UpdateApprovalSnapshotInBody -issueBody "Some description" -snapshot $snapshot

        $body | Should -BeLike "Some description*"
    }

    It "replaces an existing approval section instead of appending a second one" {
        $first = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123"
        $second = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "def456"

        $body = UpdateApprovalSnapshotInBody -issueBody "Some description" -snapshot $first
        $body = UpdateApprovalSnapshotInBody -issueBody $body -snapshot $second

        ([regex]::Matches($body, "fork-updater-approval")).Count | Should -Be 1
        (ParseApprovalSnapshot -issueBody $body).headSha | Should -Be "def456"
    }

    It "renders the compare link and shortens the sha in the table" {
        $snapshot = NewApprovalSnapshot -upstream "microsoft/azure-pipelines-tasks" -defaultBranch "master" `
            -headSha "8a4b3907a4717738c646d09c16c57617b5c9f48e" -baseSha "aaa111" `
            -compareUrl "https://github.com/jessehouwing/azure-pipelines-tasks/compare/aaa111...microsoft:8a4b390" `
            -upstreamUrl "https://github.com" -releases @("v1.0.0")

        $body = FormatApprovalSnapshot -snapshot $snapshot

        # -Match, not -BeLike: a backtick is the escape character in wildcard patterns
        $body | Should -Match '`master` at `8a4b390`'
        $body | Should -BeLike '*compare/aaa111...microsoft:8a4b390*'
        $body | Should -BeLike '*releases/tag/v1.0.0*'
        $body | Should -Not -Match '`8a4b3907a4717738c646d09c16c57617b5c9f48e`'
    }

    It "lists the changed tags with their action and a link to the contents at that tag" {
        $changed = @(
            [PSCustomObject]@{ name = "v1.0.0"; sha = "aaa"; action = "new" }
            [PSCustomObject]@{ name = "v1"; sha = "bbb"; action = "force push required" }
        )
        $snapshot = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" `
            -upstreamUrl "https://github.com" -tags $changed

        $body = FormatApprovalSnapshot -snapshot $snapshot

        # -Match with escaped input: [ and ] are character classes in wildcard patterns
        $body | Should -Match ([regex]::Escape('[v1.0.0](https://github.com/actions/checkout/tree/v1.0.0) (new)'))
        $body | Should -Match ([regex]::Escape('[v1](https://github.com/actions/checkout/tree/v1) (force push required)'))
    }

    It "only reports a count when no tag changes" {
        $unchanged = @([PSCustomObject]@{ name = "v1"; sha = "aaa"; action = "unchanged" })
        $snapshot = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -tags $unchanged

        FormatApprovalSnapshot -snapshot $snapshot | Should -BeLike '*| Tags | 1 unchanged |*'
    }

    It "caps the listed tags and links to the rest" {
        $many = 1..40 | ForEach-Object { [PSCustomObject]@{ name = "v1.0.$_"; sha = "sha$_"; action = "new" } }
        $snapshot = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" `
            -upstreamUrl "https://github.com" -tags $many

        $body = FormatApprovalSnapshot -snapshot $snapshot

        $body | Should -Match ([regex]::Escape('and [15 more](https://github.com/actions/checkout/tags)'))
        # the hidden marker must not carry every name either, the issue body is size limited
        (ParseApprovalSnapshot -issueBody $body).tagList.Count | Should -Be 25
        (ParseApprovalSnapshot -issueBody $body).tagCount | Should -Be 40
    }

    It "still detects a moved tag that is not listed by name" {
        $many = 1..40 | ForEach-Object { [PSCustomObject]@{ name = "v1.0.$_"; sha = "sha$_" } }
        $moved = 1..40 | ForEach-Object { [PSCustomObject]@{ name = "v1.0.$_"; sha = if ($_ -eq 40) { "other" } else { "sha$_" } } }

        $approved = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -tags $many
        $current = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -tags $moved

        (CompareApprovalSnapshots -approved $approved -current $current).changed | Should -BeTrue
    }

    It "shows whether the branch fast-forwards or needs a force push" {
        $fastForward = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -branchAction "fast-forward"
        $forced = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -branchAction "force push required"

        FormatApprovalSnapshot -snapshot $fastForward | Should -BeLike '*fast-forward*'
        FormatApprovalSnapshot -snapshot $forced | Should -BeLike '*force push required*'
    }

    It "marks immutable releases with a closed lock and mutable ones with an open lock" {
        $snapshot = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" `
            -upstreamUrl "https://github.com" -releaseMode "all" -releases @(
            [PSCustomObject]@{ name = "v1.0.0"; immutable = $true }
            [PSCustomObject]@{ name = "v1.1.0"; immutable = $false }
        )

        $body = FormatApprovalSnapshot -snapshot $snapshot

        $body | Should -Match "$([char]::ConvertFromUtf32(0x1F512)) \[v1\.0\.0\]"
        $body | Should -Match "$([char]::ConvertFromUtf32(0x1F513)) \[v1\.1\.0\]"
    }

    It "does not count a phantom tag when there are no tags at all" {
        $snapshot = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -tags $null -releases $null
        $snapshot.tagCount | Should -Be 0
        $snapshot.releaseTags.Count | Should -Be 0
    }

    It "says releases are not synced when the property is left at none" {
        $snapshot = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -releaseMode "none"

        FormatApprovalSnapshot -snapshot $snapshot | Should -BeLike '*| Releases | not synced*'
    }

    It "distinguishes no matching releases from releases being switched off" {
        $snapshot = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -releaseMode "immutable"

        FormatApprovalSnapshot -snapshot $snapshot | Should -BeLike '*none matched*immutable*'
    }

    It "keeps the display fields out of the change comparison" {
        $approved = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -baseSha "old" -compareUrl "https://example.com/old"
        $current = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -baseSha "new" -compareUrl "https://example.com/new"

        (CompareApprovalSnapshots -approved $approved -current $current).changed | Should -BeFalse
    }

    It "requires a new approval when the default branch moved" {
        $approved = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123"
        $current = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "def456"

        $result = CompareApprovalSnapshots -approved $approved -current $current
        $result.changed | Should -BeTrue
        $result.differences | Should -Not -BeNullOrEmpty
    }

    It "requires a new approval when a tag was added" {
        $approved = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -tags $tags
        $current = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -tags ($tags + [PSCustomObject]@{ name = "v1.0.1"; sha = "bbb" })

        (CompareApprovalSnapshots -approved $approved -current $current).changed | Should -BeTrue
    }

    It "requires a new approval when a floating tag was moved to another commit" {
        $approved = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -tags $tags
        $moved = @(
            [PSCustomObject]@{ name = "v1.0.0"; sha = "aaa" }
            [PSCustomObject]@{ name = "v1"; sha = "bbb" }
        )
        $current = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -tags $moved

        (CompareApprovalSnapshots -approved $approved -current $current).changed | Should -BeTrue
    }

    It "reports which releases are new" {
        $approved = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -releases @("v1.0.0")
        $current = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -releases @("v1.0.0", "v1.0.1")

        $result = CompareApprovalSnapshots -approved $approved -current $current
        $result.changed | Should -BeTrue
        $result.differences -join ' ' | Should -BeLike "*v1.0.1*"
    }

    It "requires a new approval when the issue has no recorded version" {
        $current = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123"

        (CompareApprovalSnapshots -approved (ParseApprovalSnapshot -issueBody "no marker here") -current $current).changed | Should -BeTrue
    }

    It "is insensitive to the order tags are returned in" {
        $approved = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -tags $tags
        $reversed = @($tags[1], $tags[0])
        $current = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -tags $reversed

        (CompareApprovalSnapshots -approved $approved -current $current).changed | Should -BeFalse
    }
}

Describe "CreateGitHubHost" {
    BeforeEach {
        $script:previousToken = $env:GITHUB_TOKEN
        $script:previousServer = $env:GITHUB_SERVER_URL
        $env:GITHUB_TOKEN = "actions-token"
    }

    AfterEach {
        $env:GITHUB_TOKEN = $script:previousToken
        $env:GITHUB_SERVER_URL = $script:previousServer
    }

    It "uses the supplied token as-is" {
        $env:GITHUB_SERVER_URL = "https://github.com"

        (CreateGitHubHost -serverUrl "https://github.com" -token "explicit").Token | Should -Be "explicit"
    }

    It "falls back to the Actions token when talking to the host it runs on" {
        $env:GITHUB_SERVER_URL = "https://contoso.ghe.com"

        $result = CreateGitHubHost -serverUrl "https://contoso.ghe.com"
        $result.Token | Should -Be "actions-token"
        $result.HasToken | Should -BeTrue
    }

    It "does not use the Actions token for another host" {
        $env:GITHUB_SERVER_URL = "https://contoso.ghe.com"

        $result = CreateGitHubHost -serverUrl "https://github.com"
        $result.Token | Should -BeNullOrEmpty
        $result.HasToken | Should -BeFalse
    }

    It "falls back to the Actions token for public GitHub when running on public GitHub" {
        $env:GITHUB_SERVER_URL = "https://github.com"

        (CreateGitHubHost -serverUrl "https://github.com").Token | Should -Be "actions-token"
    }
}

Describe "ResolveGitHubHostUrls" {
    It "uses the api.github.com endpoints for public GitHub" {
        $result = ResolveGitHubHostUrls -serverUrl "https://github.com"
        $result.ApiUrl | Should -Be "https://api.github.com"
        $result.GraphQlUrl | Should -Be "https://api.github.com/graphql"
        $result.IsPublicGitHub | Should -BeTrue
    }

    It "defaults to public GitHub when no server url is given" {
        (ResolveGitHubHostUrls -serverUrl "").ApiUrl | Should -Be "https://api.github.com"
    }

    It "uses the api.<slug>.ghe.com endpoints for a ghe.com tenant" {
        $result = ResolveGitHubHostUrls -serverUrl "https://contoso.ghe.com"
        $result.ServerUrl | Should -Be "https://contoso.ghe.com"
        $result.ApiUrl | Should -Be "https://api.contoso.ghe.com"
        $result.GraphQlUrl | Should -Be "https://api.contoso.ghe.com/graphql"
        $result.IsPublicGitHub | Should -BeFalse
    }

    It "normalizes an api url for a ghe.com tenant back to the server url" {
        (ResolveGitHubHostUrls -serverUrl "https://api.contoso.ghe.com").ServerUrl | Should -Be "https://contoso.ghe.com"
    }

    It "uses the /api/v3 endpoints for GitHub Enterprise Server" {
        $result = ResolveGitHubHostUrls -serverUrl "https://github.contoso.com"
        $result.ApiUrl | Should -Be "https://github.contoso.com/api/v3"
        $result.GraphQlUrl | Should -Be "https://github.contoso.com/api/graphql"
    }
}

Describe "GetSyncSettings" {
    It "applies the defaults when no properties are set" {
        $settings = GetSyncSettings -properties @{} -repoFullName "org/repo"
        $settings.syncMode | Should -Be "approve"
        $settings.syncBranches | Should -Be "default"
        $settings.syncFloatingTags | Should -BeTrue
        $settings.syncReleases | Should -Be "none"
        $settings.syncReleaseAssets | Should -BeFalse
        $settings.verifyUpstreamAttestations | Should -BeFalse
        $settings.upstreamUrl | Should -BeNullOrEmpty
    }

    It "reads the configured values" {
        $settings = GetSyncSettings -properties @{
            'sync-mode'                    = 'auto'
            'sync-branches'                = 'all'
            'sync-floating-tags'           = 'false'
            'sync-releases'                = 'immutable'
            'sync-release-assets'          = 'true'
            'verify-upstream-attestations' = 'true'
            'upstream-url'                 = 'https://github.com/actions/checkout'
        } -repoFullName "org/repo"

        $settings.syncMode | Should -Be "auto"
        $settings.syncBranches | Should -Be "all"
        $settings.syncFloatingTags | Should -BeFalse
        $settings.syncReleases | Should -Be "immutable"
        $settings.syncReleaseAssets | Should -BeTrue
        $settings.verifyUpstreamAttestations | Should -BeTrue
        $settings.upstreamUrl | Should -Be "https://github.com/actions/checkout"
    }

    It "falls back to the default for an unsupported value" {
        $settings = GetSyncSettings -properties @{ 'sync-releases' = 'everything' } -repoFullName "org/repo" -WarningAction SilentlyContinue
        $settings.syncReleases | Should -Be "none"
    }
}

Describe "ResolveUpstream" {
    It "prefers the upstream-url custom property" {
        $repo = [PSCustomObject]@{ name = "other_name"; full_name = "mirrors/other_name" }
        $settings = GetSyncSettings -properties @{ 'upstream-url' = 'https://github.com/actions/checkout' } -repoFullName $repo.full_name

        ResolveUpstream -repo $repo -syncSettings $settings | Should -Be "actions/checkout"
    }

    It "uses the parent of a real fork" {
        $repo = [PSCustomObject]@{
            name      = "checkout"
            full_name = "mirrors/checkout"
            fork      = $true
            parent    = [PSCustomObject]@{ full_name = "actions/checkout" }
        }

        ResolveUpstream -repo $repo -syncSettings (GetSyncSettings -properties @{}) | Should -Be "actions/checkout"
    }

    It "cannot resolve a fork that was loaded without its parent" {
        # the repository list endpoints omit the parent, callers have to reload the fork in full first
        $repo = [PSCustomObject]@{ name = "trufflehog"; full_name = "jessehouwing/trufflehog"; fork = $true }

        ResolveUpstream -repo $repo -syncSettings (GetSyncSettings -properties @{}) -WarningAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It "splits the naming convention on the first underscore only" {
        $repo = [PSCustomObject]@{ name = "actions_setup_node"; full_name = "mirrors/actions_setup_node" }

        ResolveUpstream -repo $repo -syncSettings (GetSyncSettings -properties @{}) | Should -Be "actions/setup_node"
    }

    It "returns nothing when no upstream can be determined" {
        $repo = [PSCustomObject]@{ name = "standalone"; full_name = "mirrors/standalone" }

        ResolveUpstream -repo $repo -syncSettings (GetSyncSettings -properties @{}) -WarningAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe "TestIsFloatingTag" {
    It "treats <tag> as floating" -ForEach @(
        @{ tag = "v1" }
        @{ tag = "v1.2" }
        @{ tag = "latest" }
        @{ tag = "2" }
    ) {
        TestIsFloatingTag -tagName $tag | Should -BeTrue
    }

    It "treats <tag> as pinned" -ForEach @(
        @{ tag = "v1.2.3" }
        @{ tag = "v1.2.3-preview" }
        @{ tag = "release-1" }
    ) {
        TestIsFloatingTag -tagName $tag | Should -BeFalse
    }
}

Describe "TestImmutableReleaseError" {
    It "detects the immutable release conflict" {
        $errorRecord = [PSCustomObject]@{
            ErrorDetails = [PSCustomObject]@{
                Message = '{"message":"Validation Failed","errors":[{"field":"tag_name","message":"tag_name was used by an immutable release"}]}'
            }
        }

        TestImmutableReleaseError -errorRecord $errorRecord | Should -BeTrue
    }

    It "ignores unrelated errors" {
        $errorRecord = [PSCustomObject]@{
            ErrorDetails = [PSCustomObject]@{ Message = '{"message":"Not Found"}' }
        }

        TestImmutableReleaseError -errorRecord $errorRecord | Should -BeFalse
    }
}

Describe "ParseRepoFullNameFromUrl" {
    It "parses <url> into <expected>" -ForEach @(
        @{ url = "https://github.com/actions/checkout"; expected = "actions/checkout" }
        @{ url = "https://github.com/actions/checkout/"; expected = "actions/checkout" }
        @{ url = "https://github.com/actions/checkout.git"; expected = "actions/checkout" }
        @{ url = "git@github.com:actions/checkout.git"; expected = "actions/checkout" }
    ) {
        ParseRepoFullNameFromUrl -url $url | Should -Be $expected
    }
}
