# winget install Microsoft.SqlPackage
$databases  = @("Db1", "Db2", "Db3")   # Your DB list
$outputDir  = "data\sample\Import"              # Target folder for DACPACs (relative to script location)

# Parameters
$server     = "localhost"             # Change to your SQL Server instance
$sqlPackagePath = "C:\Program Files\Microsoft SQL Server\160\DAC\bin\sqlpackage.exe"

# Get the actual computer name for more reliable connection
$actualServer = if ($server -eq "localhost") { $env:COMPUTERNAME } else { $server }

# Ensure output directory exists
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

foreach ($db in $databases) {
    $timestamp = Get-Date -Format "yyyyMMddHHmm"
    $dacpacPath = Join-Path $outputDir "$db`_$timestamp.dacpac"

    Write-Host "Extracting DACPAC for $db to $dacpacPath..."

    # Build SqlPackage arguments
    $args = @(
        "/Action:Extract",
        "/SourceConnectionString:Server=$actualServer;Database=$db;Integrated Security=true;TrustServerCertificate=true;",
        "/TargetFile:$dacpacPath",
        "/p:ExtractReferencedServerScopedElements=true",
        "/p:IgnorePermissions=true",
        "/p:IgnoreUserLoginMappings=true"
    )

    # Run SqlPackage
    try {
        & "$sqlPackagePath" $args
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Warning "Error executing SqlPackage: $($_.Exception.Message)"
        $exitCode = 1
    }

    if ($exitCode -eq 0 -and (Test-Path $dacpacPath)) {
        Write-Host "✅ Created DACPAC for $db"
    } else {
        Write-Warning "❌ Failed to create DACPAC for $db (Exit code: $exitCode)"
    }
}

Write-Host "All done."
