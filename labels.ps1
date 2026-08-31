# The labels this tool relies on, kept in one place so the init workflow and the code cannot drift apart

function GetRequiredLabels {
    return @(
        [PSCustomObject]@{
            name        = "update-available"
            color       = "0e8a16"
            description = "The upstream repository has changes that are not in this fork or mirror yet"
        }
        [PSCustomObject]@{
            name        = "parent-archived"
            color       = "b60205"
            description = "The upstream repository has been archived, consider finding an alternative"
        }
        [PSCustomObject]@{
            name        = "update-fork"
            color       = "1d76db"
            description = "Add this label to approve the recorded versions and sync the fork or mirror"
        }
    )
}
