Function Download-File($URL, $pathName) {
    $request = [System.Net.WebRequest]::Create($URL)
    $request.AllowAutoRedirect = $true
    $request.UserAgent = 'Mozilla/5.0 (Windows NT; Windows NT 10.0; en-US) AppleWebKit/534.6 (KHTML, like Gecko) Chrome/7.0.500.0 Safari/534.6' #helps with difficult pages...

    try {
        $response = $request.GetResponse()
        $redirectedURL = $response.ResponseUri.AbsoluteUri
        $response.Close()
    }
    catch {
        "Error: $_"
    }

    # echo $redirectedURL;
    # Invoke-WebRequest -URI $redirectedURL -OutFile $pathName -MaximumRedirection 0 -AllowInsecureRedirect
    curl -L -o $pathName $redirectedURL
}

function Check-Download($URL, $path, $name){
    $pathName = $path + $name;
    if (-not(Test-Path -Path $pathName)) {
        Write-Output("Not Found. Download ${name} to ${pathName}");
        
        Download-File $URL $pathName;
    }
}

function Path-Cleaning($default, $path) {
    $string = [string]::IsNullOrWhiteSpace($path) ? [string]$default : [string]$path;
    $string = $string.Replace("/", "\").Split("\");
    $string[0] = $string[0] -eq "." ? ${PWD} : $string[0];
    $string = $string -join "\";

    return $string;
}

function Register-Path-Web ($pathName, $registerPath) {
    $tmpPath = (get-item hkcu:\Environment).GetValue('Path', $null, 'DoNotExpandEnvironmentNames');
    if (Select-String -InputObject $tmpPath -Pattern "%${pathName}%") {
        # Write-Host 'exists';
    }
    else {
        [Environment]::SetEnvironmentVariable('Path', "${tmpPath}%${pathName}%;", 'user')
    }

    [Environment]::SetEnvironmentVariable($pathName, $registerPath, 'user');
}