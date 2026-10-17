function Show-Usage {
    [Console]::Error.WriteLine('Usage:')
    [Console]::Error.WriteLine('  .\FileRenameRegex.ps1 [--order=name|update|create] <folder> <filter> <template> [<filter> <template> ...]')
    [Console]::Error.WriteLine('  .\FileRenameRegex.ps1 [--order=name|update|create] <folder> <sample.json>')
    [Console]::Error.WriteLine('JSON mode reads the inputs array. Templates accept {1}, $1, and $file_index placeholders.')
}

function ConvertTo-Filter {
    param([string]$Value)

    $pattern = $Value
    $options = [System.Text.RegularExpressions.RegexOptions]::None
    if ($Value -match '^/([\s\S]*)/([dgimsuvy]*)$') {
        $pattern = $Matches[1]
        $flags = $Matches[2]
        if ($flags.Contains('i')) { $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
        if ($flags.Contains('m')) { $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::Multiline }
        if ($flags.Contains('s')) { $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::Singleline }
        if ($flags.Contains('y')) {
            throw 'Sticky regex flag (y) is not supported by this PowerShell script.'
        }
        if ($flags.Contains('v')) {
            throw 'The Unicode sets regex flag (v) is not supported by this PowerShell script.'
        }
    }

    return [System.Text.RegularExpressions.Regex]::new($pattern, $options)
}

$scriptArgs = @($args)
$order = 'name'
if ($scriptArgs.Count -gt 0 -and $scriptArgs[0] -match '^--order=(.*)$') {
    $order = $Matches[1]
    if ($order -notin @('name', 'update', 'create')) {
        [Console]::Error.WriteLine("Invalid order '$order'; choose name, update, or create.")
        Show-Usage
        exit 1
    }
    $scriptArgs = @($scriptArgs | Select-Object -Skip 1)
}
if ($scriptArgs | Where-Object { $_ -match '^--order=' }) {
    [Console]::Error.WriteLine('The --order option must be the first argument.')
    Show-Usage
    exit 1
}

if ($scriptArgs.Count -lt 1) {
    Show-Usage
    exit 1
}

$folder = $null
$filterTemplatePairs = @()

try {
    if ($scriptArgs.Count -lt 1) {
        Show-Usage
        exit 1
    }
    $folder = [System.IO.Path]::GetFullPath([string]$scriptArgs[0])
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        throw "Folder does not exist: $folder"
    }

    if ($scriptArgs.Count -eq 2 -and [string]$scriptArgs[1] -match '\.json$') {
        $sampleArgument = [string]$scriptArgs[1]
        if ([System.IO.Path]::IsPathRooted($sampleArgument)) {
            $samplePath = $sampleArgument
        }
        elseif ([System.IO.Path]::GetFileName($sampleArgument) -eq $sampleArgument) {
            $folderSample = Join-Path $folder $sampleArgument
            $scriptSample = Join-Path $PSScriptRoot $sampleArgument
            if (Test-Path -LiteralPath $folderSample -PathType Leaf) {
                $samplePath = $folderSample
            }
            elseif (Test-Path -LiteralPath $scriptSample -PathType Leaf) {
                $samplePath = $scriptSample
            }
            else {
                throw "JSON config not found: $sampleArgument (checked target folder and script folder)."
            }
        }
        else {
            $samplePath = [System.IO.Path]::GetFullPath($sampleArgument)
        }
        if (-not (Test-Path -LiteralPath $samplePath -PathType Leaf)) {
            throw "JSON config not found: $sampleArgument"
        }

        $sample = Get-Content -LiteralPath $samplePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($sample -is [System.Array]) {
            $inputs = @($sample)
        }
        elseif ($sample.PSObject.Properties['inputs']) {
            $inputs = @($sample.inputs)
        }
        else {
            $inputs = $null
        }
        if ($null -eq $inputs) {
            throw 'JSON must contain an inputs array.'
        }

        foreach ($inputStep in $inputs) {
            if ($null -eq $inputStep -or $inputStep -is [System.Array] -or $inputStep -isnot [pscustomobject]) {
                throw 'Each item in inputs must be an object.'
            }
            $filterProperties = @($inputStep.PSObject.Properties | Where-Object { $_.Name -match '^filter-regex-(\d+)$' } | Sort-Object { [int]([regex]::Match($_.Name, '\d+$').Value) })
            if ($filterProperties.Count -eq 0) {
                throw 'Each input object needs at least one filter-regex-N field.'
            }
            foreach ($filterProperty in $filterProperties) {
                $number = [regex]::Match($filterProperty.Name, '\d+$').Value
                $templateProperty = $inputStep.PSObject.Properties["rename-template-$number"]
                if ($null -eq $templateProperty) {
                    throw "Missing rename-template-$number for $($filterProperty.Name)."
                }
                $filterTemplatePairs += ,@([string]$filterProperty.Value, [string]$templateProperty.Value)
            }
        }
    }
    else {
        if ($scriptArgs.Count -lt 3 -or (($scriptArgs.Count - 1) % 2) -ne 0) {
            Show-Usage
            exit 1
        }
        for ($i = 1; $i -lt $scriptArgs.Count; $i += 2) {
            $filterTemplatePairs += ,@([string]$scriptArgs[$i], [string]$scriptArgs[$i + 1])
        }
    }

    if ($filterTemplatePairs.Count -eq 0) {
        throw 'Provide at least one complete filter/template pair.'
    }

    $pipeline = @()
    foreach ($pair in $filterTemplatePairs) {
        $pipeline += ,@((ConvertTo-Filter -Value $pair[0]), [string]$pair[1])
    }

    $files = @(Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction Stop)
    switch ($order) {
        name { $files = @($files | Sort-Object -Property Name) }
        update { $files = @($files | Sort-Object -Property LastWriteTime, Name) }
        create { $files = @($files | Sort-Object -Property CreationTime, Name) }
    }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outputFolder = Join-Path $folder "file-rename-regex-$timestamp"
    if (Test-Path -LiteralPath $outputFolder) {
        throw "Output folder already exists: $outputFolder"
    }
    New-Item -ItemType Directory -Path $outputFolder -ErrorAction Stop | Out-Null
    [Console]::WriteLine(('Output folder: {0}' -f $outputFolder))

    $fileIndex = 1
    foreach ($file in $files) {
        $newName = $file.Name
        $matchedAnyFilter = $false
        foreach ($step in $pipeline) {
            $filter = $step[0]
            $match = $filter.Match($newName)
            if (-not $match.Success) {
                continue
            }
            $matchedAnyFilter = $true

            $replacement = [regex]::Replace([string]$step[1], '\{(\d+)\}|\$(\d+)|\$file_index', {
                param($placeholder)
                if ($placeholder.Value -ceq '$file_index') {
                    return [string]$fileIndex
                }
                $groupNumber = if ($placeholder.Groups[1].Success) { [int]$placeholder.Groups[1].Value } else { [int]$placeholder.Groups[2].Value }
                if ($groupNumber -lt $match.Groups.Count) {
                    return $match.Groups[$groupNumber].Value
                }
                return $placeholder.Value
            })
            $newName = $newName.Substring(0, $match.Index) + $replacement + $newName.Substring($match.Index + $match.Length)
        }

        if ($matchedAnyFilter) {
            $fileIndex++
        }

        if ($newName -ceq $file.Name) {
            $targetPath = Join-Path $outputFolder $newName
        }
        else {
            if ([string]::IsNullOrWhiteSpace($newName) -or $newName -eq '.' -or $newName -eq '..' -or $newName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $newName.Contains('/') -or $newName.Contains('\')) {
                [Console]::Error.WriteLine(('Invalid output filename for {0}; file skipped.' -f $file.Name))
                continue
            }
            $targetPath = Join-Path $outputFolder $newName
        }

        if (Test-Path -LiteralPath $targetPath -ErrorAction Stop) {
            [Console]::Error.WriteLine(('Conflict: {0} already exists in output; file skipped.' -f $newName))
            continue
        }

        Copy-Item -LiteralPath $file.FullName -Destination $targetPath -ErrorAction Stop
        [Console]::WriteLine(('{0} -> {1}' -f $file.Name, $newName))
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
