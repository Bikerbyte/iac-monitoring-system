$ErrorActionPreference = "Stop"

$ansibleRoot = "D:\Program Files (x86)\Ansible"
$distroName = "Ansible-Ubuntu"
$distroLocation = Join-Path $ansibleRoot "Ubuntu"
$binDir = Join-Path $ansibleRoot "bin"

New-Item -ItemType Directory -Force -Path $ansibleRoot | Out-Null
New-Item -ItemType Directory -Force -Path $distroLocation | Out-Null
New-Item -ItemType Directory -Force -Path $binDir | Out-Null

Write-Host "Checking WSL status..."
wsl --status

$registeredDistros = @(wsl --list --quiet | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ })

if ($registeredDistros -notcontains $distroName) {
    Write-Host "Installing Ubuntu 24.04 WSL distro to $distroLocation ..."
    wsl --install Ubuntu-24.04 --name $distroName --location $distroLocation --no-launch --web-download
}
else {
    Write-Host "WSL distro $distroName already exists."
}

Write-Host "Installing Ansible inside $distroName ..."
wsl -d $distroName -u root -- bash -lc @'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-pip python3-venv openssh-client
python3 -m venv /opt/ansible-venv
/opt/ansible-venv/bin/pip install --upgrade pip
/opt/ansible-venv/bin/pip install ansible-core
/opt/ansible-venv/bin/ansible --version
'@

$ansibleCmd = @"
@echo off
wsl -d $distroName -- /opt/ansible-venv/bin/ansible %*
"@

$ansiblePlaybookCmd = @"
@echo off
wsl -d $distroName -- /opt/ansible-venv/bin/ansible-playbook %*
"@

Set-Content -LiteralPath (Join-Path $binDir "ansible.cmd") -Value $ansibleCmd -Encoding ASCII
Set-Content -LiteralPath (Join-Path $binDir "ansible-playbook.cmd") -Value $ansiblePlaybookCmd -Encoding ASCII

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$pathParts = @($userPath -split ";" | Where-Object { $_ -and $_.Trim() })

if ($pathParts -notcontains $binDir) {
    [Environment]::SetEnvironmentVariable("Path", (($pathParts + $binDir) -join ";"), "User")
    Write-Host "Added $binDir to user PATH."
}
else {
    Write-Host "$binDir is already in user PATH."
}

Write-Host "Ansible install finished."
Write-Host "Open a new PowerShell window and run: ansible-playbook --version"
