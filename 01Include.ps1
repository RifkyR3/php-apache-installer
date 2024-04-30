if (-not(Test-Path -Path .env)) {
    Copy-Item .env.sample .env
}

Get-Content .env | ForEach-Object {
    $name, $value = $_.split('=')
    if ([string]::IsNullOrWhiteSpace($name) || $name.Contains('#')) {
        # do nothing
    }
    else {
        Set-Content env:\$name $value
    }
}