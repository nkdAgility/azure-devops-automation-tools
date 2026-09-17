UPDATE  tbl_JobDefinition
SET     Flags = 2
WHERE   PartitionId = 1
        AND ExtensionName = 'Microsoft.TeamFoundation.JobService.Extensions.Core.IdentitySyncJobExtension'