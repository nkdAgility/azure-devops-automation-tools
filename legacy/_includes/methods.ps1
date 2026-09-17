


function FindGroup {
    param(
      [string]$groupLabel,
      [string]$orgUrl,
      [string]$ProcessID,
      [string]$workItemType,
      [string]$queryString,
      [System.Collections.Hashtable]$header
    )
  
    $processEpicLayoutURL = "$orgUrl/_apis/work/processes/$($ProcessID)/workItemTypes/$($workItemType)/layout?$queryString"
    $processEpicLayout = Invoke-RestMethod -Uri $processEpicLayoutURL -Method Get -ContentType "application/json" -Headers $header
    Write-DebugLog "Layout: {layout}" -PropertyValues $processEpicLayout
    foreach ($page in $processEpicLayout.pages)
    {
      foreach ($section in $page.sections)
      {
        foreach ($group in $section.groups)
        {
          Write-DebugLog "Group: {group}" -PropertyValues $group
          if ($group.label -eq $groupLabel) {
            Write-DebugLog "FOUND: Group: {group}" -PropertyValues $group
            Write-InformationLog "FOUND: {group} as {groupid}" -PropertyValues $group.label, $group.id
            return $group
          }
        }
      }
    }
  
  }