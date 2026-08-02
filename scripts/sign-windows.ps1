# scripts/sign-windows.ps1
# 构建完成后的手动签名脚本，查找并签名所有 Windows 产物。
# 用于 pnpm release:windows 流程中 tauri build 之后的补签。
#
# 如果已在 tauri.conf.json 中配置了 signCommand，构建时已自动签名，
# 此脚本可作为验证/补签工具使用。

$ErrorActionPreference = "Stop"

$Target = "x86_64-pc-windows-msvc"
$BundleDir = "src-tauri\target\$Target\release\bundle"
$ReleaseDir = "src-tauri\target\$Target\release"
$CertSubject = "CN=ADM Self-Signed Cert"
$PfxPath = Join-Path $env:USERPROFILE ".adm-code-signing.pfx"
$PfxPassword = "adm-self-signed"

Write-Host "=== ADM Windows 签名脚本 ===" -ForegroundColor Cyan

# 查找证书（与 sign-windows-file.ps1 相同逻辑）
$Cert = Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $CertSubject } |
    Select-Object -First 1

if (-not $Cert -and (Test-Path $PfxPath)) {
    $SecurePw = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
    try {
        Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation Cert:\CurrentUser\My -Password $SecurePw -ErrorAction Stop | Out-Null
        $Cert = Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert |
            Where-Object { $_.Subject -eq $CertSubject } |
            Select-Object -First 1
    } catch { }
}

if (-not $Cert) {
    $Cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $CertSubject -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(10)
    $SecurePw = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
    try { Export-PfxCertificate -Cert $Cert -FilePath $PfxPath -Password $SecurePw | Out-Null } catch { }
    Write-Host "已创建自签名证书" -ForegroundColor Yellow
} else {
    Write-Host "使用已有证书: $($Cert.Thumbprint)" -ForegroundColor Green
}

# 收集所有需要签名的文件
$FilesToSign = @()

# 主程序 exe
$MainExe = Join-Path $ReleaseDir "ADM.exe"
if (Test-Path $MainExe) { $FilesToSign += $MainExe }

# NSIS 安装包
$NsisDir = Join-Path $BundleDir "nsis"
if (Test-Path $NsisDir) {
    $FilesToSign += Get-ChildItem -Path $NsisDir -Filter "*-setup.exe" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
}

# MSI 安装包（如有）
$MsiDir = Join-Path $BundleDir "msi"
if (Test-Path $MsiDir) {
    $FilesToSign += Get-ChildItem -Path $MsiDir -Filter "*.msi" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
}

# 也检查不带 target 的默认 release 目录
$DefaultRelease = "src-tauri\target\release"
$DefaultBundle = "src-tauri\target\release\bundle"
if (-not (Test-Path $ReleaseDir) -and (Test-Path $DefaultRelease)) {
    $MainExe2 = Join-Path $DefaultRelease "ADM.exe"
    if (Test-Path $MainExe2) { $FilesToSign += $MainExe2 }
    $NsisDir2 = Join-Path $DefaultBundle "nsis"
    if (Test-Path $NsisDir2) {
        $FilesToSign += Get-ChildItem -Path $NsisDir2 -Filter "*-setup.exe" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    }
}

if ($FilesToSign.Count -eq 0) {
    Write-Host "未找到需要签名的文件，请先运行 pnpm tauri:build:windows" -ForegroundColor Red
    exit 1
}

# 去重
$FilesToSign = $FilesToSign | Sort-Object -Unique

Write-Host "`n找到 $($FilesToSign.Count) 个文件待签名:" -ForegroundColor Green
foreach ($f in $FilesToSign) { Write-Host "  $f" }
Write-Host ""

# 逐个签名（自签名证书未入受信任根存储时链验证为 UnknownError，签名已嵌入，视为成功）
$Success = 0
$Failed = 0
foreach ($file in $FilesToSign) {
    $Result = Set-AuthenticodeSignature -FilePath $file -Certificate $Cert -HashAlgorithm SHA256
    $Ok = ($Result.Status -eq "Valid") -or
          ($Result.Status -eq "UnknownError" -and $null -ne $Result.SignerCertificate)
    if ($Ok) {
        Write-Host "[OK] $file ($($Result.Status))" -ForegroundColor Green
        $Success++
    } else {
        Write-Host "[FAIL] $file - $($Result.Status): $($Result.StatusMessage)" -ForegroundColor Red
        $Failed++
    }
}

Write-Host "`n=== 签名完成: $Success 成功, $Failed 失败 ===" -ForegroundColor Cyan

# 验证签名（已签名但根不受信任时显示 UnknownError，属预期行为）
Write-Host "`n验证签名状态:" -ForegroundColor Yellow
foreach ($file in $FilesToSign) {
    $Sig = Get-AuthenticodeSignature -FilePath $file
    $SigOk = ($Sig.Status -eq "Valid") -or ($Sig.Status -eq "UnknownError" -and $null -ne $Sig.SignerCertificate)
    Write-Host "  $($Sig.Status) - $(Split-Path $file -Leaf)" -ForegroundColor $(if ($SigOk) { "Green" } else { "Red" })
}

if ($Failed -gt 0) { exit 1 }
