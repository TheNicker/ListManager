function Test-ListManagerDocument {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Document
    )

    if ($null -eq $Document -or $Document -isnot [System.Management.Automation.PSCustomObject]) {
        throw [ArgumentException]::new("The request body must be a JSON object.")
    }

    if ($null -eq $Document.schema -or $Document.schema -isnot [System.Management.Automation.PSCustomObject]) {
        throw [ArgumentException]::new("'schema' must be a JSON object.")
    }
    if ($Document.schema.fields -isnot [array]) {
        throw [ArgumentException]::new("'schema.fields' must be an array.")
    }
    $fieldKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($field in $Document.schema.fields) {
        if ($null -eq $field -or $field -isnot [System.Management.Automation.PSCustomObject]) {
            throw [ArgumentException]::new("Every entry in 'schema.fields' must be a JSON object.")
        }
        if ($field.key -isnot [string] -or [string]::IsNullOrWhiteSpace($field.key) -or
            -not $fieldKeys.Add($field.key) -or
            $field.label -isnot [string] -or [string]::IsNullOrWhiteSpace($field.label)) {
            throw [ArgumentException]::new("Every field must have a unique non-empty string 'key' and a non-empty string 'label'.")
        }
        if ($null -ne $field.type -and $field.type -notin @("text", "email", "number", "date", "checkbox")) {
            throw [ArgumentException]::new("Field types must be text, email, number, date, or checkbox.")
        }
        if ($null -ne $field.required -and $field.required -isnot [bool]) {
            throw [ArgumentException]::new("Field 'required' values must be boolean.")
        }
    }
    if ($Document.records -isnot [array]) {
        throw [ArgumentException]::new("'records' must be an array.")
    }
    foreach ($record in $Document.records) {
        if ($null -eq $record -or $record -isnot [System.Management.Automation.PSCustomObject]) {
            throw [ArgumentException]::new("Every entry in 'records' must be a JSON object.")
        }
        foreach ($property in $record.PSObject.Properties) {
            if ($null -ne $property.Value -and
                ($property.Value -is [System.Management.Automation.PSCustomObject] -or $property.Value -is [array])) {
                throw [ArgumentException]::new("Record values must be primitive JSON values.")
            }
        }
    }
}
