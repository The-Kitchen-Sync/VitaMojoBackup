param (
    [Parameter(Mandatory)]
    [string]
    $Email,
    [Parameter(Mandatory)]
    [string]
    $Password,
    [string]
    $FallbackExportFromDateTime = "2025-02-26T16:25:00"
)

function Get-VitaMojoAuthenticationToken {
    param (
        [Parameter(Mandatory)]
        [string]
        $Email,
        [Parameter(Mandatory)]
        [string]
        $Password
    )

    $Uri = "https://vmos2.vmos.io/user/v1/auth"
    $Method = "Post"
    $ContentType = "application/json"
    $Body = @{
        "email" = $Email
        "password" = $Password
    } | ConvertTo-Json

    $TokenResponse = Invoke-RestMethod -Uri $Uri -Method $Method -ContentType $ContentType -Body $Body
    $TokenResponse.payload.token.value
}

function Invoke-VitaMojoAPIRequest {
    param (
        [Parameter(Mandatory)]
        [string]
        $EndpointName,
        [Parameter(Mandatory)]
        [string]
        $Method,
        [string]
        $Body
    )
       
    $Uri = "https://reporting.data.vmos.io/cubejs-api/v1/$($EndpointName)"
    $Headers = @{
        'Authorization' = Get-VitaMojoAuthenticationToken -Email $Email -Password $Password
    }
    $ContentType = "application/json"

    Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -ContentType $ContentType -Body $Body
}

# The list of cubes that hold transactional data and so will be exported incrementally.
$TransactionalDataCubeNames = @(
    "CashManagement",
    "OrderItems",
    "OrderTransactions",
    "ReconciliationReports"
)

# The maximum number of records to return from each request to the Vita Mojo API.
$PageSize = 10000

# Get the cubes metadata
$MetaResponse = Invoke-VitaMojoAPIRequest -EndpointName "meta" -Method "Get"    

# Loop through each cube and export the data.
$MetaResponse.cubes | ForEach-Object {
    $CubeName = $_.name
    Write-Host "Exporting cube $($CubeName)"    

    # For debugging only
    If ($CubeName -ne "Stores") {
        return
    }

    $IsTransactionalDataCube = $TransactionalDataCubeNames -contains $CubeName

    # Get the path of the folder in which to write the exported cube data.
    $OutputFolder = "Output/$($CubeName)"

    # Ensure the output folder exists.
    New-Item -Path $OutputFolder -Type Directory -Force > $null

    # Get a list of all of the cube's dimensions.
    $Dimensions = @($_ | ForEach-Object {
        $_.dimensions | Select-Object -ExpandProperty name
    })    

    If ($IsTransactionalDataCube) {

        # Get the name of the file which contains the updated date/time of the latest data to have been exported.
        $LatestDataDateTimeFilename = "$($OutputFolder)/latest-data-date-time.txt"

        # If the latest data file exists use the date/time from that file, if it doesn't exist then use the default date/time.
        If (Test-Path -Path $LatestDataDateTimeFilename) {
            $LatestDataDateTime = Get-Content -Path $LatestDataDateTimeFilename -First 1       
        }
        Else {
            $LatestDataDateTime = $ExportStartDateTime
        }        
        
        $UpdatedAtFieldName = "$($CubeName).updatedAt"

        # Tell the query to order by the updated at field. The order isn't that important but not specifying one causes issues with paged results.
        $Order = @{                     
            $UpdatedAtFieldName = "asc"                     
        }        

        # Tell the query to only return records that have been updated (or created) after the latest export date/time.
        $Filters = @(
            @{
                "member" = $UpdatedAtFieldName
                "operator" = "afterDate"
                "values" = @(
                    $LatestDataDateTime
                )
            }
        )                
    }
    Else {
        # Tell the query to order by the first dimension field. The order isn't that important but not specifying one causes issues with paged results.
        $Order = @{                     
            $Dimensions[0] = "asc"                     
        }

        $Filters = @()
    }  

    # Get a list of all of the cube's measures.
    $Measures = @($_ | ForEach-Object {
        $_.measures | Select-Object -ExpandProperty name
    })    
        
    $PageIndex = 0    

    # Keep requesting the cube's data until the number of rows returned is less than the page size which indicates that there are no more pages.
    Do {        

        # Get the body of the query as JSON.
        $Body = @{
            "query" = @{
                "measures" = $Measures
                "dimensions" = $Dimensions
                "filters" = $Filters
                "limit" = $PageSize
                "offset" = $PageIndex * $PageSize
                "order" = $Order    
            }
        } | ConvertTo-Json -Depth 100        

        # Keep requesting the page of data until a non-wait response is received.
        Do {        
            $LoadResponse = Invoke-VitaMojoAPIRequest -EndpointName "load" -Method "Post" -Body $Body            
        } While ($LoadResponse.error -eq "Continue wait")
                
        If ($IsTransactionalDataCube) {            

            # Get the latest file index by enumerating the existing files.
            $OutputFileLatestIndex = [int](Get-ChildItem -Path $OutputFolder -Filter "*.json" |
                ForEach-Object { [int]($_.BaseName) } |
                Measure-Object -Maximum |
                Select-Object -ExpandProperty Maximum) 
        }
        Else {

            # Use the page number as the latest file index.
            $OutputFileLatestIndex = $PageIndex
        }
                
        # If some data has been returned then export it.
        If ($LoadResponse.data.Count -gt 0) {

            # Get the filename in which to store the exported data.
            $OutputFilename = "$($OutputFolder)/$('{0:d7}' -f ($OutputFileLatestIndex + 1)).json"

            # Write the data to the file.
            $LoadResponse | ConvertTo-Json -Depth 100 | Out-File $OutputFilename

            If ($IsTransactionalDataCube) {

                # Get the updated date/time of the latest data.
                $LastLoadedDateTime = $LoadResponse.data | Measure-Object -Property $UpdatedAtFieldName -Maximum | Select-Object -ExpandProperty Maximum            
            }

            Write-Host "Data written to $($OutputFilename)"
        }        
        
        $PageIndex = $PageIndex + 1            
    } While ($LoadResponse.data.Count -eq $PageSize)        

    # Write the updated date/time of the latest data to file.
    If ($IsTransactionalDataCube) {
        $LastLoadedDateTime.ToString("yyyy-MM-ddTHH:mm:ss") | Out-File -Path $LatestDataDateTimeFilename
    }
}