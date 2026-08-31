BeforeAll {
    . $PSScriptRoot\..\library.ps1
    . $PSScriptRoot\..\sync-mirror.ps1
}

Describe "Approval snapshots" {
    BeforeAll {
        $script:tags = @(
            [PSCustomObject]@{ name = "v1.0.0"; sha = "aaa" }
            [PSCustomObject]@{ name = "v1"; sha = "aaa" }
        )
    }

    It "round trips through the issue body" {
        $snapshot = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -tags $tags -releaseTags @("v1.0.0")
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
        $approved = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -releaseTags @("v1.0.0")
        $current = NewApprovalSnapshot -upstream "actions/checkout" -defaultBranch "main" -headSha "abc123" -releaseTags @("v1.0.0", "v1.0.1")

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
