<#
.SYNOPSIS
    Calculates the new version for a workload based on the version increment declared in the pull request.
.DESCRIPTION
    This script calculates the new version for a workload based on the version increment declared in the pull request.
    The script uses the GitHub API to get the labels of the pull request and the existing tags of the workload.
    The script then uses the labels and tags to determine the type of update and the new version.
    The script outputs the new version for a tag.
.EXAMPLE
.INPUTS
    The script requires the following parameters:
    - Repository: The repository name in the format 'organization/repository'.
    - GitHubToken: The GitHub token used to authenticate with the GitHub API.
    - WorkloadName: The name of the workload.
    - WorkloadType: The type of the workload.
    - ModuleType: The type of the module.
    - PullRequestNumber: The number of the pull request.
.OUTPUTS
    The script outputs the new version for a tag.
.NOTES
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter()]
    [string]$Repository = $env:REPOSITORY,

    [Parameter()]
    [AllowEmptyString()]
    [string]$GitHubToken,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Prefix,

    [Parameter()]
    [int]$PullRequestNumber
)

if (!$GitHubToken) {
    $GitHubToken = $env:GH_TOKEN
}

$gitHubAuthenticationHeader = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($GitHubToken)")) }

if ((!$PullRequestNumber) -and ($env:GH_REF -match "\d+\/merge")) {
    $PullRequestNumber = $GitHubRef | Select-String -Pattern "\d+(?=\/merge)" | ForEach-Object { $_.Matches.Value }
} else {
    $params = @{
        uri               = "https://api.github.com/repos/$Repository/pulls?state=closed"
        Method            = 'GET'
        Headers           = $gitHubAuthenticationHeader
        RetryIntervalSec  = 2
        MaximumRetryCount = 5
    }
    $PullRequestNumber = (Invoke-RestMethod @params) | Where-Object { $_.merge_commit_sha -eq $env:GH_SHA } | Select-Object -ExpandProperty number
}

if (!$PullRequestNumber) {
    Write-Error "Can't find pull request. Run this from a merge commit or enter a pull request number."
}


# Find PR based on ID
$params = @{
    uri               = "https://api.github.com/repos/$Repository/pulls/$($PullRequestNumber)?state=closed"
    Method            = "GET"
    Headers           = $gitHubAuthenticationHeader
    RetryIntervalSec  = 2
    MaximumRetryCount = 5
}
$pullRequest = Invoke-RestMethod @Params

# Filter the labels to only include the ones that are used to determine the version increment
$labels = $pullRequest.labels.name | Where-Object { $_ -match 'patch|minor|major' }
if ($labels.Count -gt 1) {
    Write-Error 'Only one of the following labels can be added to the pull request: patch, minor, major'
} elseif ($labels.Count -eq 0) {
    Write-Error 'Add one of the following labels to the pull request: patch, minor, major'
}

# Determine the type of update based on the label
if ($labels) {
    $changeType = switch ($labels) {
        { $_ -contains "patch" -and $_ -notcontains "minor", "major" } {
            Write-Host "This update adds a fix`n"
            "patch"
            break
        }
        { $_ -contains "minor" -and $_ -notcontains "patch", "major" } {
            Write-Host "This update adds a feature`n"
            "minor"
            break
        }
        { $_ -contains "major" -and $_ -notcontains "patch", "minor" } {
            Write-Host "This update adds a big feature`n"
            "major"
            break
        }
        default {
            Write-Error "Add one of the following labels to the pull request: patch, minor, major"
        }
    }
}

# Find existing tags of the workload
$page = 1
$allTags = @()
do {
    $getTagsParameters = @{
        Uri               = "https://api.github.com/repos/$Repository/tags?per_page=100&page=$page"
        Method            = "GET"
        Headers           = $gitHubAuthenticationHeader
        ContentType       = "application/vnd.github+json"
        RetryIntervalSec  = 2
        MaximumRetryCount = 5
    }
    $response = Invoke-RestMethod @getTagsParameters
    $allTags += $response
    $page++
    Start-Sleep -Seconds 1
} while ($response)

$tags = $allTags | Where-Object { $_.name -match "^$Prefix" }

Write-Host "Calculating new version for $Prefix"

foreach ($tag in $tags) {
    $params = @{
        Uri               = "https://api.github.com/repos/$Repository/git/commits/$($tag.commit.sha)"
        Method            = "GET"
        Headers           = $gitHubAuthenticationHeader
        ContentType       = "application/vnd.github+json"
        RetryIntervalSec  = 2
        MaximumRetryCount = 5
    }
    $commit = Invoke-RestMethod @params

    $tag | Add-Member -NotePropertyName date -NotePropertyValue $commit.committer.date -Force
}

# If the pull request is closed, use the closed_at date, otherwise use the created_at date
if ($pullRequest.closed_at) {
    $tags = $tags | Where-Object { ($pullRequest.closed_at - $_.date).TotalMinutes -ge 1 } | Select-Object -ExpandProperty name
} else {
    $tags = $tags | Where-Object { ($pullRequest.created_at - $_.date).TotalMinutes -ge 1 } | Select-Object -ExpandProperty name
}

# If there are no tags, this is the first tag of the workload
if (!$tags) {
    Write-Host "$Prefix has no tags yet"
    $newVersion = "$($Prefix)v1.0.0"
    Write-Host "New version is: $newVersion`n"
    Write-Output "newVersion=$newVersion" >> $env:GITHUB_OUTPUT
    exit
}

# CurrentVersion is the latest tag, use regex to increment this number based on the type of update to get the NewVersion
$currentVersion = $tags | Sort-Object { $_.name -replace "$($Prefix)v" -as [Version] } -Descending | Select-Object -First 1
$currentVersion -match "$($Prefix)v(?<Major>\d+)\.(?<Minor>\d+)\.(?<Patch>\d+)" > $null
Write-Host "Current version is: $currentVersion"

[int]$currentPatch = [int]$matches["Patch"]
[int]$currentMinor = [int]$matches["Minor"]
[int]$currentMajor = [int]$matches["Major"]

# Increment the version based on the type of update
switch ($changeType) {
    { $_ -eq "patch" } {
        $currentPatch = $currentPatch + 1
        break
    }
    { $_ -eq "minor" } {
        $currentMinor = $currentMinor + 1
        $currentPatch = 0
        break
    }
    { $_ -eq "major" } {
        $currentMajor = $currentMajor + 1
        $currentMinor = 0
        $currentPatch = 0
        break
    }
    default {
        Write-Error "Add one of the following labels to the pull request: patch, minor, major"
    }
}

# If the new version is different from the current version, output the new version
$newVersion = "$($Prefix)v$currentMajor.$currentMinor.$currentPatch"
if ($currentVersion -ne $newVersion) {
    Write-Host "New version is: $newVersion`n"
}

# Output the new version
Write-Output "newVersion=$newVersion" >> $env:GITHUB_OUTPUT
