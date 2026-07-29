$migrator = 'C:\Users\mhinshelwood\Downloads\DataMigrationTool\Migrator.exe'

$collections = @(
    "http://tfsa1uatvm01:8080/tfs/col1",
    "http://tfsa1uatvm01:8080/tfs/col2"
)

foreach ($collection in $collections) {
    & $migrator Validate /collection:$collection /tenantDomainName:entraid.name /region:CUS /saveprocesses
}