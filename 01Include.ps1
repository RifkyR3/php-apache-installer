if (-not (Test-Path -Path .env)) {
    Copy-Item .env.sample .env
    Write-Output "No .env found; copied defaults from .env.sample"
}
else {
    Write-Output "Loaded environment from .env"
}

# Clean legacy environment variables migrated to baseUrl.json to prevent stale session pollution
if (Test-Path env:APACHE_BASE) { Remove-Item env:APACHE_BASE -ErrorAction SilentlyContinue }
if (Test-Path env:NGINX_BASE) { Remove-Item env:NGINX_BASE -ErrorAction SilentlyContinue }

Get-Content .env | ForEach-Object {
    $name, $value = $_.split('=')
    if ([string]::IsNullOrWhiteSpace($name) || $name.Contains('#')) {
        # do nothing
    }
    else {
        Set-Content env:\$name $value
    }
}