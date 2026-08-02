# scripts/sign-windows-file.ps1
# 被 Tauri 的 bundle.windows.signCommand 在构建过程中自动调用。
# 参数 -FilePath 对应 Tauri 传入的待签名文件路径（替换 %1）。
#
# 工作流程:
#   1. 查找已有自签名证书（CurrentUser\My）
#   2. 若不存在，尝试从 PFX 导入
#   3. 若 PFX 也不存在，创建新的自签名代码签名证书并导出 PFX 供后续复用
#   4. 对文件签名（SHA256）
#
# PFX 存储位置: $env:USERPROFILE\.adm-code-signing.pfx
# 默认密码: adm-self-signed（仅用于本地开发自签名，非生产密钥）

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$FilePath
)

$ErrorActionPreference = "Stop"

$CertSubject = "CN=ADM Self-Signed Cert"
$PfxPath = Join-Path $env:USERPROFILE ".adm-code-signing.pfx"
$PfxPassword = "adm-self-signed"

# 跳过不存在的文件（比如某些中间产物）
if (-not (Test-Path $FilePath)) {
    Write-Host "[sign] 跳过（文件不存在）: $FilePath"
    exit 0
}

# 1. 查找已有证书
$Cert = Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $CertSubject } |
    Select-Object -First 1

# 2. 尝试从 PFX 导入
if (-not $Cert -and (Test-Path $PfxPath)) {
    Write-Host "[sign] 从 PFX 导入证书: $PfxPath"
    $SecurePw = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
    try {
        Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation Cert:\CurrentUser\My -Password $SecurePw -ErrorAction Stop | Out-Null
        $Cert = Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert |
            Where-Object { $_.Subject -eq $CertSubject } |
            Select-Object -First 1
    } catch {
        Write-Host "[sign] PFX 导入失败，将创建新证书: $_"
    }
}

# 3. 创建新证书
if (-not $Cert) {
    Write-Host "[sign] 创建自签名代码签名证书（有效期 10 年）..."
    $Cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $CertSubject `
        -CertStoreLocation Cert:\CurrentUser\My `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -HashAlgorithm SHA256 `
        -NotAfter (Get-Date).AddYears(10)

    # 导出 PFX 供后续构建复用
    $SecurePw = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
    try {
        Export-PfxCertificate -Cert $Cert -FilePath $PfxPath -Password $SecurePw -ErrorAction Stop | Out-Null
        Write-Host "[sign] PFX 已导出: $PfxPath"
    } catch {
        Write-Host "[sign] PFX 导出失败（不影响本次签名）: $_"
    }
}

# 4. 签名
# 注意：自签名证书的根不在系统受信任根存储时，签名虽已正确嵌入，
# 但链验证返回 UnknownError（“在不受信任的根证书处终止”），此时视为成功。
Write-Host "[sign] 签名: $FilePath"
$Result = Set-AuthenticodeSignature -FilePath $FilePath -Certificate $Cert -HashAlgorithm SHA256

$Ok = ($Result.Status -eq "Valid") -or
      ($Result.Status -eq "UnknownError" -and $null -ne $Result.SignerCertificate)

if (-not $Ok) {
    Write-Error "[sign] 签名失败: $($Result.Status) - $($Result.StatusMessage)"
    exit 1
}

Write-Host "[sign] 完成: $FilePath ($($Result.Status))"
