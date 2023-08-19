
$pat = "kezijdagz574tx7ltunvya57mjk2uo3pkqxe52b6zvqkulmep32a"
$organization = "https://dev.azure.com/nkdagility-preview"

# Create header with PAT
$token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($pat)"))
$header = @{authorization = "Basic $token"}
$queryString = "api-version=7.0"

