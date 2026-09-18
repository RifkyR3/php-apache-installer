<?php
$currentPort = !empty($_SERVER['SERVER_PORT']) ? $_SERVER['SERVER_PORT'] : '8082';
$phpVersion = PHP_VERSION;
$sapi = php_sapi_name();
$loadedExtensions = get_loaded_extensions();
sort($loadedExtensions);

$allPorts = [
    '5.4' => 8054,
    '5.5' => 8055,
    '5.6' => 8056,
    '7.0' => 8070,
    '7.1' => 8071,
    '7.2' => 8072,
    '7.3' => 8073,
    '7.4' => 8074,
    '8.0' => 8080,
    '8.1' => 8081,
    '8.2' => 8082,
    '8.3' => 8083,
    '8.4' => 8084,
    '8.5' => 8085,
];

if (isset($_GET['info'])) {
    phpinfo();
    exit;
}

$scanDir = __DIR__;
$rawItems = @scandir($scanDir) ?: [];
$fileList = [];

foreach ($rawItems as $item) {
    if ($item === '.' || $item === '..') {
        continue;
    }
    $fullPath = $scanDir . DIRECTORY_SEPARATOR . $item;
    $isDir = is_dir($fullPath);
    $fileList[] = [
        'name'  => $item,
        'isDir' => $isDir,
        'mtime' => @filemtime($fullPath) ?: 0,
        'size'  => $isDir ? '-' : (@filesize($fullPath) ?: 0),
    ];
}

usort($fileList, function ($a, $b) {
    if ($a['isDir'] !== $b['isDir']) {
        return $a['isDir'] ? -1 : 1;
    }
    return strcasecmp($a['name'], $b['name']);
});

function formatFileSize($bytes) {
    if ($bytes === '-') return '-';
    $units = ['B', 'KB', 'MB', 'GB'];
    $bytes = max((int)$bytes, 0);
    $pow = floor(($bytes ? log($bytes) : 0) / log(1024));
    $pow = min((int)$pow, count($units) - 1);
    $bytes /= pow(1024, $pow);
    return round($bytes, 1) . ' ' . $units[$pow];
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Portable Web Server Dashboard</title>
    <style>
        :root {
            --bg: #0f172a;
            --card-bg: #1e293b;
            --text: #f8fafc;
            --muted: #94a3b8;
            --primary: #38bdf8;
            --accent: #22c55e;
            --border: #334155;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
        body { background: var(--bg); color: var(--text); padding: 32px 16px; min-height: 100vh; }
        .container { max-width: 960px; margin: 0 auto; }
        .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 20px; margin-bottom: 24px; }
        .header h1 { font-size: 24px; color: var(--text); display: flex; align-items: center; gap: 10px; }
        .badge { background: var(--accent); color: #000; font-size: 12px; font-weight: bold; padding: 4px 10px; border-radius: 9999px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; margin-bottom: 24px; }
        .card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px; padding: 20px; }
        .card h2 { font-size: 16px; color: var(--muted); margin-bottom: 12px; text-transform: uppercase; letter-spacing: 0.05em; }
        .stat { font-size: 22px; font-weight: bold; color: var(--primary); }
        .ports-grid { display: flex; flex-wrap: wrap; gap: 8px; }
        .port-btn { display: inline-block; padding: 8px 14px; border-radius: 6px; text-decoration: none; font-size: 13px; font-weight: 500; border: 1px solid var(--border); background: #0f172a; color: var(--text); transition: all 0.15s ease; }
        .port-btn:hover { border-color: var(--primary); color: var(--primary); }
        .port-btn.active { background: var(--primary); color: #000; font-weight: bold; border-color: var(--primary); }
        .actions { margin-top: 16px; display: flex; gap: 12px; }
        .btn { display: inline-block; padding: 8px 16px; border-radius: 6px; background: var(--primary); color: #000; text-decoration: none; font-weight: bold; font-size: 14px; }
        .btn-outline { background: transparent; color: var(--primary); border: 1px solid var(--primary); }
        .ext-list { display: flex; flex-wrap: wrap; gap: 6px; max-height: 180px; overflow-y: auto; padding-right: 4px; }
        .ext-tag { background: #0f172a; border: 1px solid var(--border); padding: 3px 8px; border-radius: 4px; font-size: 11px; color: var(--muted); }
        .file-table { width: 100%; border-collapse: collapse; margin-top: 10px; font-size: 13px; }
        .file-table th { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--border); color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; }
        .file-table td { padding: 8px 10px; border-bottom: 1px solid #273549; }
        .file-table tr:last-child td { border-bottom: none; }
        .file-table tr:hover td { background: rgba(255,255,255,0.02); }
        .file-link { color: var(--primary); text-decoration: none; display: inline-flex; align-items: center; gap: 6px; }
        .file-link:hover { text-decoration: underline; }
        .file-meta { color: var(--muted); font-family: monospace; font-size: 12px; }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <div>
            <h1>Portable Web Environment <span class="badge">ONLINE</span></h1>
            <p style="color: var(--muted); margin-top: 4px;">Self-contained portable stack (XAMPP-Style)</p>
        </div>
        <div>
            <a href="?info=1" target="_blank" class="btn btn-outline">phpinfo()</a>
        </div>
    </div>

    <div class="grid">
        <div class="card">
            <h2>Current PHP Version</h2>
            <div class="stat">PHP <?= htmlspecialchars($phpVersion) ?></div>
            <p style="color: var(--muted); margin-top: 6px; font-size: 13px;">SAPI: <?= htmlspecialchars($sapi) ?> &bull; Port: <?= htmlspecialchars($currentPort) ?></p>
        </div>
        <div class="card">
            <h2>Document Root</h2>
            <div style="font-size: 14px; font-family: monospace; color: var(--text); word-break: break-all; margin-top: 4px;">
                <?= htmlspecialchars(!empty($_SERVER['DOCUMENT_ROOT']) ? $_SERVER['DOCUMENT_ROOT'] : __DIR__) ?>
            </div>
        </div>
    </div>

    <div class="card" style="margin-bottom: 24px;">
        <h2>Switch PHP Version (Virtual Host Ports)</h2>
        <p style="color: var(--muted); font-size: 13px; margin-bottom: 14px;">Click any port below to test code under a different PHP runtime:</p>
        <div class="ports-grid">
            <?php foreach ($allPorts as $ver => $port): ?>
                <a href="http://localhost:<?= $port ?>/" class="port-btn <?= ((int)$currentPort === $port) ? 'active' : '' ?>">
                    PHP <?= $ver ?> (Port <?= $port ?>)
                </a>
            <?php endforeach; ?>
        </div>
    </div>

    <div class="card">
        <h2>Loaded Extensions (<?= count($loadedExtensions) ?>)</h2>
        <div class="ext-list">
            <?php foreach ($loadedExtensions as $ext): ?>
                <span class="ext-tag"><?= htmlspecialchars($ext) ?></span>
            <?php endforeach; ?>
        </div>
    </div>

    <div class="card" style="margin-top: 24px;">
        <h2>Index of <?= htmlspecialchars(!empty($_SERVER['REQUEST_URI']) ? $_SERVER['REQUEST_URI'] : '/') ?></h2>
        <div style="overflow-x: auto;">
            <table class="file-table">
                <thead>
                    <tr>
                        <th>Name</th>
                        <th style="width: 180px;">Last Modified</th>
                        <th style="width: 100px; text-align: right;">Size</th>
                    </tr>
                </thead>
                <tbody>
                    <?php if (empty($fileList)): ?>
                        <tr><td colspan="3" style="color: var(--muted); text-align: center; padding: 16px;">(Directory is empty)</td></tr>
                    <?php else: ?>
                        <?php foreach ($fileList as $f): ?>
                            <tr>
                                <td>
                                    <a href="<?= htmlspecialchars($f['name']) . ($f['isDir'] ? '/' : '') ?>" class="file-link">
                                        <span><?= $f['isDir'] ? '📁' : '📄' ?></span>
                                        <span><?= htmlspecialchars($f['name']) . ($f['isDir'] ? '/' : '') ?></span>
                                    </a>
                                </td>
                                <td class="file-meta"><?= $f['mtime'] ? date('Y-m-d H:i', $f['mtime']) : '-' ?></td>
                                <td class="file-meta" style="text-align: right;"><?= formatFileSize($f['size']) ?></td>
                            </tr>
                        <?php endforeach; ?>
                    <?php endif; ?>
                </tbody>
            </table>
        </div>
    </div>
</div>
</body>
</html>
