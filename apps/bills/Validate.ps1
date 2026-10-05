function Test-BillsDocument {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Document
    )

    if ($null -eq $Document -or $Document -isnot [System.Management.Automation.PSCustomObject]) {
        throw [ArgumentException]::new("The request body must be a JSON object.")
    }

    $propertyNames = @($Document.PSObject.Properties.Name)
    $hasPeople = $propertyNames -contains "people"
    $hasPersons = $propertyNames -contains "persons"
    if ($hasPeople -eq $hasPersons) {
        throw [ArgumentException]::new("Expected exactly one of 'people' or 'persons'.")
    }

    $collectionName = if ($hasPeople) { "people" } else { "persons" }
    $collection = $Document.$collectionName
    if ($collection -isnot [array]) {
        throw [ArgumentException]::new("'$collectionName' must be an array.")
    }
    $personIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($person in $collection) {
        if ($null -eq $person -or $person -isnot [System.Management.Automation.PSCustomObject]) {
            throw [ArgumentException]::new("Every entry in '$collectionName' must be a JSON object.")
        }
        if ($person.id -isnot [string] -or [string]::IsNullOrWhiteSpace($person.id) -or
            $person.name -isnot [string] -or [string]::IsNullOrWhiteSpace($person.name)) {
            throw [ArgumentException]::new("Every person must have a non-empty string 'id' and 'name'.")
        }
        if (-not $personIds.Add($person.id)) {
            throw [ArgumentException]::new("Person IDs must be unique.")
        }
        foreach ($property in @("phone", "address")) {
            if ($null -ne $person.$property -and $person.$property -isnot [string]) {
                throw [ArgumentException]::new("Person '$property' values must be strings.")
            }
        }
        foreach ($utility in @("water", "electricity")) {
            $entries = $person.$utility
            if ($null -ne $entries -and $entries -isnot [array]) {
                throw [ArgumentException]::new("'$collectionName' entries may only contain '$utility' as an array.")
            }
            $entryIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $baselineId = $null
            if ($entries.Count -gt 0) {
                $baselineId = ($entries | Sort-Object -Property date | Select-Object -First 1).id
            }
            foreach ($entry in $entries) {
                if ($null -eq $entry -or $entry -isnot [System.Management.Automation.PSCustomObject]) {
                    throw [ArgumentException]::new("Every '$utility' entry must be a JSON object.")
                }
                if ($entry.id -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.id) -or
                    -not $entryIds.Add($entry.id)) {
                    throw [ArgumentException]::new("Every '$utility' entry must have a unique non-empty string 'id'.")
                }
                if ($entry.date -isnot [string] -or $entry.date -notmatch '^\d{4}-\d{2}-\d{2}$') {
                    throw [ArgumentException]::new("Every '$utility' entry must have a date in YYYY-MM-DD format.")
                }
                $parsedDate = [datetime]::MinValue
                if (-not [datetime]::TryParseExact(
                        $entry.date,
                        "yyyy-MM-dd",
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::None,
                        [ref]$parsedDate
                    )) {
                    throw [ArgumentException]::new("Every '$utility' entry must have a valid calendar date.")
                }
                $numericProperties = if ($utility -eq "water") {
                    @("read", "averagePrice")
                } else {
                    @("read", "pricePerUnit", "fixedPrice")
                }
                foreach ($property in $numericProperties) {
                    if ($entry.id -eq $baselineId -and $property -ne "read" -and
                        -not $entry.PSObject.Properties[$property]) {
                        continue
                    }
                    $value = $entry.$property
                    if ($value -is [bool] -or $value -isnot [ValueType] -or
                        [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or [double]$value -lt 0) {
                        throw [ArgumentException]::new("'$utility.$property' must be a finite non-negative number.")
                    }
                }
            }
        }
    }
}
