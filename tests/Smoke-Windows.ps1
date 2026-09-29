[CmdletBinding()]
param(
    [string]$InstallRoot='C:\Program Files\Immich',
    [string]$DataRoot='C:\ProgramData\Immich',
    [string]$PostgresRoot='C:\Program Files\PostgreSQL\18',
    [string[]]$SharpFixture,
    [switch]$AllowUnqualifiedSharp
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\runtime\Common.psm1') -Force
$current=(Resolve-Path -LiteralPath (Join-Path $InstallRoot 'current')).Path
$manifest=Get-Content -Raw -LiteralPath (Join-Path $current 'manifest.json')|ConvertFrom-Json
if(-not $manifest.mediaStack.productionQualified -and -not $AllowUnqualifiedSharp){throw 'Installed package is marked productionQualified=false because it uses stock Sharp/libvips.'}

$envs=Read-EnvFile (Join-Path $DataRoot 'immich.env')
$serverPort=if($envs.IMMICH_PORT){[int]$envs.IMMICH_PORT}else{2283}
$mlPort=if($envs.IMMICH_PORT_ML){[int]$envs.IMMICH_PORT_ML}else{3003}
$redisMode=if($envs.IMMICH_WINDOWS_REDIS_MODE){$envs.IMMICH_WINDOWS_REDIS_MODE}else{'BundledValkey'}
if($redisMode -notin @('BundledValkey','External')){throw "Unknown IMMICH_WINDOWS_REDIS_MODE: $redisMode"}
if ($envs.IMMICH_WINDOWS_INSTALL_SCOPE -eq 'CurrentUser') {
    $expectedProcesses=@('ImmichMachineLearning','ImmichServer')
    if($redisMode -eq 'BundledValkey'){$expectedProcesses += 'ImmichValkey'}
    foreach($name in $expectedProcesses){
        $pidFile=Join-Path $DataRoot "services\$name.pid"
        if(-not(Test-Path -LiteralPath $pidFile)){throw "Process $name has no PID file."}
        $process=Get-Process -Id ([int](Get-Content -Raw -LiteralPath $pidFile)) -ErrorAction SilentlyContinue
        if(-not $process){throw "Process $name is not running."}
    }
} else {
    $expectedServices=@('ImmichMachineLearning','ImmichServer')
    if($redisMode -eq 'BundledValkey'){$expectedServices += 'ImmichValkey'}
    foreach($name in $expectedServices){
        $svc=Get-Service -Name $name -ErrorAction Stop
        if($svc.Status -ne 'Running'){throw "Service $name is $($svc.Status), expected Running."}
    }
}
Wait-HttpOk "http://127.0.0.1:$mlPort/ping" 30
Wait-HttpOk "http://127.0.0.1:$serverPort/api/server/ping" 30

$psql=Join-Path $PostgresRoot 'bin\psql.exe'
if(-not(Test-Path $psql)){throw "psql.exe missing: $psql"}
$env:PGPASSWORD=[string]$envs.DB_PASSWORD
try{
    $rows=@(& $psql -h $envs.DB_HOSTNAME -p $envs.DB_PORT -U $envs.DB_USERNAME -d $envs.DB_DATABASE_NAME -At -F '|' -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('vector','vchord') ORDER BY extname")
    if($LASTEXITCODE -ne 0){throw 'PostgreSQL extension probe failed.'}
}finally{Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue}
if(-not($rows -match '^vchord\|')){throw 'VectorChord extension is not installed in the Immich database.'}
if(-not($rows -match '^vector\|')){throw 'pgvector extension is not installed in the Immich database.'}
$rows|ForEach-Object{Write-Host "PostgreSQL extension: $_"}

$valkeyCli=Join-Path $current 'dependencies\valkey\valkey-cli.exe'
$pong=(& $valkeyCli -h $envs.REDIS_HOSTNAME -p $envs.REDIS_PORT ping).Trim()
if($LASTEXITCODE -ne 0 -or $pong -ne 'PONG'){throw "Redis-compatible service ping failed at $($envs.REDIS_HOSTNAME):$($envs.REDIS_PORT): $pong"}

$vcRuntime=Join-Path $current 'runtime\vc-runtime'
foreach($name in @('vcruntime140.dll','msvcp140.dll')){if(-not(Test-Path -LiteralPath (Join-Path $vcRuntime $name) -PathType Leaf)){throw "Packaged MSVC runtime is missing $name"}}
$sharpLib=Join-Path $current 'server\node_modules\@img\sharp-win32-x64\lib'
if(-not(Test-Path -LiteralPath $sharpLib -PathType Container)){throw "Sharp runtime is missing: $sharpLib"}
$env:PATH=(@($sharpLib,$vcRuntime,(Join-Path $current 'runtime\node'),(Join-Path $current 'runtime\ffmpeg'),$env:PATH)|Where-Object{$_}) -join ';'
$node=Join-Path $current 'runtime\node\node.exe'
$bullProbe=@'
const { createRequire } = require('node:module');
const path = require('node:path');
(async () => {
  const serverRoot = process.argv[1];
  const redisHost = process.argv[2];
  const redisPort = Number(process.argv[3]);
  const req = createRequire(path.join(serverRoot, 'package.json'));
  const { Queue, Worker, QueueEvents } = req('bullmq');
  const queueName = `immich-windows-compat-${process.pid}-${Date.now()}`;
  const connection = { host: redisHost, port: redisPort, maxRetriesPerRequest: null };
  const queue = new Queue(queueName, { connection });
  const events = new QueueEvents(queueName, { connection });
  await events.waitUntilReady();
  const worker = new Worker(queueName, async (job) => ({ value: job.data.value + 1 }), { connection });
  try {
    const job = await queue.add('probe', { value: 41 });
    const result = await job.waitUntilFinished(events, 15000);
    if (!result || result.value !== 42) throw new Error(`unexpected BullMQ result: ${JSON.stringify(result)}`);
    console.log('BullMQ/Redis protocol compatibility probe OK');
  } finally {
    await worker.close();
    await events.close();
    await queue.obliterate({ force: true }).catch(() => undefined);
    await queue.close();
  }
})().catch((error) => { console.error(error); process.exit(1); });
'@
& $node -e $bullProbe (Join-Path $current 'server') $envs.REDIS_HOSTNAME $envs.REDIS_PORT
if($LASTEXITCODE -ne 0){throw "BullMQ compatibility probe failed against Redis-compatible endpoint $($envs.REDIS_HOSTNAME):$($envs.REDIS_PORT)."}

$ffmpeg=Join-Path $current 'runtime\ffmpeg\ffmpeg.exe'
$python=Get-ChildItem (Join-Path $current 'machine-learning\python-runtime') -Filter python.exe -File -Recurse|Where-Object{$_.FullName -notmatch '\\Scripts\\'}|Select-Object -First 1
$nodeVersion=& $node --version; if($LASTEXITCODE -ne 0){throw 'Node runtime failed.'}; Write-Host "Node $nodeVersion"
$ffmpegVersion=& $ffmpeg -version; if($LASTEXITCODE -ne 0){throw 'FFmpeg runtime failed.'}; Write-Host ($ffmpegVersion|Select-Object -First 1)
$pythonVersion=& $python.FullName --version; if($LASTEXITCODE -ne 0){throw 'Python runtime failed.'}; Write-Host $pythonVersion

$statfsProbe=@'
const fs = require('node:fs/promises');
(async () => {
  const root = process.argv[1];
  const stats = await fs.statfs(root);
  if (!(stats.blocks > 0) || !(stats.bsize > 0)) throw new Error(`invalid statfs result for ${root}`);
  console.log(`statfs OK: ${root} blockSize=${stats.bsize} blocks=${stats.blocks}`);
})().catch((error) => { console.error(error); process.exit(1); });
'@
& $node -e $statfsProbe $envs.IMMICH_MEDIA_LOCATION
if($LASTEXITCODE -ne 0){throw "Node fs.statfs failed for native media root $($envs.IMMICH_MEDIA_LOCATION)."}

$probe=@'
const { createRequire } = require('node:module');
const path = require('node:path');
(async () => {
  const root = process.argv[1];
  const fixtures = process.argv.slice(2);
  const req = createRequire(path.join(root, 'package.json'));
  const sharp = req('sharp');
  console.log(`sharp ${sharp.versions.sharp}, libvips ${sharp.versions.vips}`);
  for (const fixture of fixtures) {
    const metadata = await sharp(fixture).metadata();
    await sharp(fixture).resize({ width: 64, height: 64, fit: 'inside' }).jpeg().toBuffer();
    console.log(`sharp fixture OK: ${fixture} ${metadata.format} ${metadata.width}x${metadata.height}`);
  }
})().catch((error) => { console.error(error); process.exit(1); });
'@
& $node -e $probe (Join-Path $current 'server') @SharpFixture
if($LASTEXITCODE -ne 0){throw 'Sharp/libvips runtime capability test failed.'}

& (Join-Path $current 'migration\Schema-Check.ps1') -EnvFile (Join-Path $DataRoot 'immich.env') -InstallRoot $InstallRoot
Write-Host "Native Windows smoke test passed for Immich $($manifest.immichVersion)."
