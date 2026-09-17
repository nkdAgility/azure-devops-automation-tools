# This forces a full conform! Consider only conforming the Categories & Process Configuration
## Conform Projects with https://github.com/microsoft/process-customization-scripts.git
$projectsToConform = @(
    [pscustomobject]@{
        Name       = 'Project 1'
        Collection = 'http://tfsa1uatvm01:8080/tfs/coll1'
        Process    = 'Scrum'
    }
    [pscustomobject]@{
        Name       = 'Project 2'
        Collection = 'http://tfsa1uatvm01:8080/tfs/coll1'
        Process    = 'Scrum'
    }
    [pscustomobject]@{
        Name       = 'TestProject'
        Collection = 'http://tfsa1uatvm01:8080/tfs/coll2'
        Process    = 'Scrum'
    }
)

$processCustScript = "C:\Users\mhinshelwood\source\repos\process-customization-scripts"

$ConformProjectScript = "$processCustScript\Import\ConformProject.ps1"
$ImportLocation = "$processCustScript\Import\"

foreach ($project in $projectsToConform) {
    & $ConformProjectScript $project.Collection $project.Name "$ImportLocation\$($project.Process)"
}
