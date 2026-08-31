# Represents a connection to a GitHub host (github.com, a *.ghe.com tenant or GitHub Enterprise Server)

function ResolveGitHubHostUrls {
    param (
        [string] $serverUrl
    )

    if ([string]::IsNullOrWhiteSpace($serverUrl)) {
        $serverUrl = "https://github.com"
    }

    $serverUrl = $serverUrl.TrimEnd('/')

    # accept an api url as input as well and normalize it back to the server url
    $serverUrl = $serverUrl -replace '/api/v3$', ''
    $serverUrl = $serverUrl -replace '/api/graphql$', ''

    $uri = [System.Uri]$serverUrl
    $hostName = $uri.Host

    if ($hostName -eq "api.github.com" -or $hostName -eq "github.com" -or $hostName -eq "www.github.com") {
        return [PSCustomObject]@{
            ServerUrl      = "https://github.com"
            ApiUrl         = "https://api.github.com"
            GraphQlUrl     = "https://api.github.com/graphql"
            IsPublicGitHub = $true
        }
    }

    # ghe.com tenants use api.<slug>.ghe.com instead of the GHES /api/v3 form
    if ($hostName -match '^(?<prefix>api\.)?(?<slug>[^.]+)\.ghe\.com$') {
        $slug = $Matches.slug
        return [PSCustomObject]@{
            ServerUrl      = "https://$slug.ghe.com"
            ApiUrl         = "https://api.$slug.ghe.com"
            GraphQlUrl     = "https://api.$slug.ghe.com/graphql"
            IsPublicGitHub = $false
        }
    }

    # GitHub Enterprise Server
    return [PSCustomObject]@{
        ServerUrl      = "$($uri.Scheme)://$hostName"
        ApiUrl         = "$($uri.Scheme)://$hostName/api/v3"
        GraphQlUrl     = "$($uri.Scheme)://$hostName/api/graphql"
        IsPublicGitHub = $false
    }
}

function CreateGitHubHost {
    param (
        [string] $serverUrl,
        [string] $token,
        [string] $userName
    )

    $urls = ResolveGitHubHostUrls -serverUrl $serverUrl

    return [PSCustomObject]@{
        ServerUrl      = $urls.ServerUrl
        ApiUrl         = $urls.ApiUrl
        GraphQlUrl     = $urls.GraphQlUrl
        IsPublicGitHub = $urls.IsPublicGitHub
        Token          = $token
        UserName       = $userName
        HasToken       = -not [string]::IsNullOrWhiteSpace($token)
    }
}

function GetHeaders {
    param (
        [object] $gitHubHost
    )

    $headers = @{
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    if ([string]::IsNullOrWhiteSpace($gitHubHost.Token)) {
        return $headers
    }

    $headers.Authorization = "Bearer $($gitHubHost.Token)"

    return $headers
}

function GetCloneUrl {
    param (
        [object] $gitHubHost,
        [string] $repoFullName
    )

    if ($gitHubHost.HasToken) {
        return "$($gitHubHost.ServerUrl -replace '^https://', "https://xx:$($gitHubHost.Token)@")/$repoFullName.git"
    }

    return "$($gitHubHost.ServerUrl)/$repoFullName.git"
}
