
BeforeAll {
    # Import the script containing the function to test
    . $PSScriptRoot\..\library.ps1
    # set logging to debug  
    $DebugPreference = "Continue"
}

AfterAll {
    # reset logging to normal
    $DebugPreference = "SilentlyContinue"
}

Describe "FindAllRepos" {
    It "returns more than repositories for the org 'devops-actions'" {
        # making sure that pagination works
        $gitHubHost = CreateGitHubHost -serverUrl "https://github.com" -token $env:GITHUB_TOKEN
        $result = FindAllRepos -orgName 'devops-actions' -gitHubHost $gitHubHost
        $result.Count | Should -BeGreaterThan 5
    }
}