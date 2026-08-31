
# pull in the host abstraction
. $PSScriptRoot\github-host.ps1

function CallWebRequest {
    param (
        [string] $url,
        [object] $gitHubHost,
        [string] $verbToUse = "Get",
        [object] $body,
        [switch] $throwOnFailure
    )

    $Headers = GetHeaders -gitHubHost $gitHubHost

    # allow callers to pass a path relative to the host's api url
    if (-not $url.StartsWith("http")) {
        $url = "$($gitHubHost.ApiUrl)/$($url.TrimStart('/'))"
    }

    $info = $null

    try {

        $requestParameters = @{
            Uri         = $url
            Headers     = $Headers
            Method      = $verbToUse
            ErrorAction = "Stop"
            ContentType = "application/json"
        }

        if ($null -ne $body) {
            $requestParameters.Body = ($body | ConvertTo-Json -Depth 10) -replace '\\', '\'
        }

        $result = Invoke-WebRequest @requestParameters

        Write-Host "  StatusCode: $($result.StatusCode)"
        Write-Host "  RateLimit-Limit: $($result.Headers["X-RateLimit-Limit"])"
        Write-Host "  RateLimit-Remaining: $($result.Headers["X-RateLimit-Remaining"])"
        Write-Host "  RateLimit-Reset: $($result.Headers["X-RateLimit-Reset"])"
        Write-Host "  RateLimit-Used: $($result.Headers["x-ratelimit-used"])"

        # convert the response json content
        $info = ($result.Content | ConvertFrom-Json)

        if ($result.Headers["Link"]) {
            Write-Debug "Found pagination link: $($result.Headers["Link"])"
            # load next link from header

            $result.Headers["Link"].Split(',') | ForEach-Object {
                # search for the 'next' link in this list
                $link = $_.Split(';')[0].Trim()
                if ($_.Split(';')[1].Contains("next")) {
                    $nextUrl = $link.Substring(1, $link.Length - 2)

                    # $currentResultCount = $currentResultCount + $info.Count
                    # if ($maxResultCount -ne 0) {
                    #     Write-Host "Loading next page of data, where at [$($currentResultCount)] of max [$maxResultCount]"
                    # }
                    # # and get the results
                    # if ($maxResultCount -ne 0) {
                    #     # check if we need to stop getting more pages
                    #     if ($currentResultCount -gt $maxResultCount) {
                    #         Write-Host "Stopping with [$($currentResultCount)] results, which is more then the max result count [$maxResultCount]"
                    #         return $response
                    #     }
                    # }

                    # continue fetching next page
                    $nextResult = CallWebRequest -url $nextUrl -gitHubHost $gitHubHost -verbToUse $verbToUse -body $body
                    $info += $nextResult
                }
            }
        }

    }
    catch {
        if ($throwOnFailure) {
            throw
        }

        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($statusCode -eq 404) {
            Write-Debug "Call to GitHub Api [$url] returned [not found]"
            return $null
        }

        Write-Host "Error calling api at [$url]: $($_.Exception.Message)"
        Write-Host "  StatusCode: $statusCode"

        $messageData = $null
        if ($_.ErrorDetails.Message) {
            try {
                $messageData = $_.ErrorDetails.Message | ConvertFrom-Json
            }
            catch {
                Write-Host "$($_.ErrorDetails.Message)"
            }
        }

        if ($messageData -and $messageData.message -and $messageData.message.StartsWith("API rate limit exceeded")) {
            Write-Error "Rate limit exceeded. Halting execution"
            throw
        }

        if ($messageData) {
            Write-Host "$($messageData.message)"
        }
    }

    return $info
}

function CallGraphQlRequest {
    param (
        [object] $gitHubHost,
        [string] $query,
        [hashtable] $variables = @{}
    )

    $headers = GetHeaders -gitHubHost $gitHubHost
    $body = @{
        query     = $query
        variables = $variables
    } | ConvertTo-Json -Depth 10

    $response = Invoke-RestMethod -Uri $gitHubHost.GraphQlUrl -Headers $headers -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop

    if ($response.errors) {
        $errorMessages = ($response.errors | ForEach-Object { $_.message }) -join '; '
        throw "GraphQL errors from [$($gitHubHost.GraphQlUrl)]: $errorMessages"
    }

    return $response.data
}

function GetRepoInfo {
    param (
        [object] $gitHubHost,
        [string] $repoFullName
    )

    return CallWebRequest -url "repos/$repoFullName" -gitHubHost $gitHubHost
}

function GetForkCloneUrl {
    param (
        [string] $fork,
        [object] $gitHubHost
    )
    Write-Host "Generate the clone url for [$fork] on [$($gitHubHost.ServerUrl)]"
    return GetCloneUrl -gitHubHost $gitHubHost -repoFullName $fork
}

function GetParentInfo {
    param (
        [string] $fork,
        [object] $gitHubHost
    )

    $info = GetRepoInfo -gitHubHost $gitHubHost -repoFullName $fork

    if ($false -eq $info.fork) {
        Write-Error "Repo [$fork] is not a fork"
        throw
    }

    return [PSCustomObject]@{
        parentUrl = $info.parent.html_url
        parentDefaultBranch = $info.parent.default_branch
    }

}

function GetBranchCommit {
    param (
        [string] $parent,
        [object] $gitHubHost,
        [string] $branchName
    )

    $info = CallWebRequest -url "repos/$parent/branches/$branchName" -gitHubHost $gitHubHost

    return [PSCustomObject]@{
        sha  = $info.commit.sha
        date = $info.commit.commit.author.date
    }
}

function GetTags {
    param (
        [object] $gitHubHost,
        [string] $repoFullName
    )

    # a repository without any tags responds with a 404 here
    $refs = CallWebRequest -url "repos/$repoFullName/git/refs/tags?per_page=100" -gitHubHost $gitHubHost
    if ($null -eq $refs) {
        return @()
    }

    return @(@($refs) | ForEach-Object {
            [PSCustomObject]@{
                name = $_.ref -replace '^refs/tags/', ''
                sha  = $_.object.sha
            }
        })
}

function SetLabel {
    param (
        [object] $gitHubHost,
        [string] $repoFullName,
        [string] $name,
        [string] $color,
        [string] $description
    )

    $data = [PSCustomObject]@{
        name        = $name
        color       = $color
        description = $description
    }

    $labelUrl = "repos/$repoFullName/labels/$([uri]::EscapeDataString($name))"
    $existing = CallWebRequest -url $labelUrl -gitHubHost $gitHubHost

    if ($null -ne $existing) {
        $result = CallWebRequest -url $labelUrl -gitHubHost $gitHubHost -verbToUse "PATCH" -body $data
        $action = "updated"
    }
    else {
        $result = CallWebRequest -url "repos/$repoFullName/labels" -gitHubHost $gitHubHost -verbToUse "POST" -body $data
        $action = "created"
    }

    if ($null -eq $result) {
        Write-Warning "Could not create or update label [$name] in repository [$repoFullName]"
        return $false
    }

    Write-Host "Label [$name] has been $action in repository [$repoFullName]"
    return $true
}

function GetIssue {
    param (
        [object] $gitHubHost,
        [string] $repoFullName,
        [int] $number
    )

    return CallWebRequest -url "repos/$repoFullName/issues/$number" -gitHubHost $gitHubHost
}

function UpdateIssueBody {
    param (
        [object] $gitHubHost,
        [string] $repoFullName,
        [int] $number,
        [string] $body
    )

    $data = [PSCustomObject]@{
        body = $body
    }

    $null = CallWebRequest -url "repos/$repoFullName/issues/$number" -gitHubHost $gitHubHost -verbToUse "PATCH" -body $data
}

function RemoveLabelFromIssue {
    param (
        [object] $gitHubHost,
        [string] $repoFullName,
        [int] $number,
        [string] $label
    )

    Write-Host "Removing label [$label] from issue [$number] in repository [$repoFullName]"
    $null = CallWebRequest -url "repos/$repoFullName/issues/$number/labels/$([uri]::EscapeDataString($label))" -gitHubHost $gitHubHost -verbToUse "DELETE"
}

function AddCommentToIssue {
    param (
        [string] $repoName,
        [string] $message,
        [int] $number,
        [object] $gitHubHost
    )

    $body = [PSCustomObject]@{
        body = $message
    }

    CallWebRequest -url "repos/$repoName/issues/$number/comments" -gitHubHost $gitHubHost -body $body -verbToUse "POST"
}


function CloseIssue {
    param (
        [string] $issuesRepositoryName,
        [int] $number,
        [object] $gitHubHost
    )    

    $data = [PSCustomObject]@{       
        state = "closed"
    }

    Write-Host "Closing issue with number [$number] in repository [$issuesRepositoryName]"
    $result = CallWebRequest -url "repos/$issuesRepositoryName/issues/$number" -verbToUse "POST" -body $data -gitHubHost $gitHubHost

    if ($null -eq $result) {
        Write-Warning "Could not close issue [$number] in repository [$issuesRepositoryName]"
        return
    }

    Write-Host "Issue has been closed and can be found at this url: ($($result.html_url))"
}


function CreateNewIssueForRepo { 
    param (
        [string] $issuesRepositoryName,
        [string] $title,
        [string] $body,
        [object] $gitHubHost,
        [string] $labels
    )

    $labelsArray = $labels -split ','

    $data = [PSCustomObject]@{
        title = $title
        body = $body
        labels = $labelsArray
    }

    Write-Host "Creating a new issue with title [$title] in repository [$issuesRepositoryName]"
    $result = CallWebRequest -url "repos/$issuesRepositoryName/issues" -verbToUse "POST" -body $data -gitHubHost $gitHubHost

    if ($null -eq $result) {
        Write-Warning "Could not create the issue with title [$title] in repository [$issuesRepositoryName]"
        return
    }

    Write-Host "Issue has been created and can be found at this url: ($($result.html_url))"
}
