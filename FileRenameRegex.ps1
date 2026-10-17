# Example: .\rename.ps1 '^photo_([0-9]+)\.jpg$' 'image_{1}.jpg'
# Run from the folder containing the files to rename.

if ($args.Count -ne 2) {
    [Console]::Error.WriteLine('Usage: .\rename.ps1 <filter_regex> <rename_template>')
    exit 1
}

try {
    # .NET regex matching is case-sensitive by default, like the Bash script.
    $filter = [regex]::new([string]$args[0])
    $template = [string]$args[1]
    $files = @(Get-ChildItem -LiteralPath . -File -Force -ErrorAction Stop)

    foreach ($file in $files) {
        $match = $filter.Match($file.Name)
        if (-not $match.Success) {
            continue
        }

        $new = $template
        for ($i = 1; $i -lt $match.Groups.Count; $i++) {
            $new = $new.Replace(('{' + $i + '}'), $match.Groups[$i].Value)
        }

        if ($new -ceq $file.Name) {
            continue
        }

        if (Test-Path -LiteralPath $new -ErrorAction Stop) {
            [Console]::Error.WriteLine(('Conflict: {0} already exists; file skipped.' -f $new))
            continue
        }

        Move-Item -LiteralPath $file.FullName -Destination $new -ErrorAction Stop
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
