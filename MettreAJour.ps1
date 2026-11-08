# Mise à jour d'EryAddon : télécharge la dernière version publiée sur GitHub et remplace les
# fichiers de ce dossier. Lancé par « Mettre a jour EryAddon.bat » (double-clic).
# Les réglages (dossier WTF) ne sont pas touchés.
$ErrorActionPreference = 'Stop'
$depot = 'Erylis219/EryAddon'
$dest  = $PSScriptRoot

function Version($toc) {
    if (-not (Test-Path $toc)) { return '?' }
    $l = Select-String -Path $toc -Pattern '^## Version:\s*(.+)$' | Select-Object -First 1
    if ($l) { return $l.Matches[0].Groups[1].Value.Trim() } else { return '?' }
}

try {
    if (Test-Path (Join-Path $dest '.git')) {
        Write-Host "Ici c'est le dossier de développement d'EryAddon : rien à mettre à jour." -ForegroundColor Yellow
        return
    }
    $avant = Version (Join-Path $dest 'EryAddon.toc')
    Write-Host "Version installée : $avant"
    Write-Host 'Téléchargement de la dernière version...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path $env:TEMP ('EryAddon_maj_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp 'maj.zip'
    Invoke-WebRequest -Uri "https://github.com/$depot/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tmp
    $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
    $apres = Version (Join-Path $src.FullName 'EryAddon.toc')
    if ($apres -eq $avant) {
        Write-Host "Déjà à jour (version $avant)." -ForegroundColor Green
    } else {
        Copy-Item -Path (Join-Path $src.FullName '*') -Destination $dest -Recurse -Force
        Write-Host "EryAddon mis à jour : $avant -> $apres" -ForegroundColor Green
        Write-Host 'En jeu : tape /reload (si ça ne suffit pas, relance le jeu).'
    }
    Remove-Item -Path $tmp -Recurse -Force
} catch {
    Write-Host "Échec de la mise à jour : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Rien n'a été abîmé ; réessaie plus tard ou préviens Jérémie."
}
