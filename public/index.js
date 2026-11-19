const REPO_OWNER = 'TheLanc3';
const REPO_NAME = 'WebCadroid';

const apiUrl = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest`;
const repoUrl = `https://github.com/${REPO_OWNER}/${REPO_NAME}`;
const releasesUrl = repoUrl + '/releases'

document.getElementById('repo-link').href = repoUrl;

function formatBytes(bytes) {
    if (!bytes) return '';
    const mb = (bytes / (1024 * 1024)).toFixed(1);
    return `${mb} MB`;
}

function formatCount(count) {
    if (!count) return '';
    let formattedCount = count.toString();
    if (count >= 1000 && count <= 1000000) {
        formattedCount = (count / 1000).toFixed(1) + "K";
    }
    if (count >= 1000000) {
        formattedCount = (count / 1000000).toFixed(1) + "M";
    }
    return formattedCount;
}

function setupButton(btnId, metaId, downloadCntId, asset) {
    const btn = document.getElementById(btnId);
    const downloadCnt = document.getElementById(downloadCntId);
    const meta = document.getElementById(metaId);

    if (asset) {
        btn.href = asset.browser_download_url;
        btn.classList.remove('disabled');
        meta.textContent = `${formatBytes(asset.size)}`;
        downloadCnt.textContent = `${formatCount(asset.download_count)} Downloads`
    } else {
        btn.href = releasesUrl;
        btn.classList.remove('disabled');
        meta.textContent = 'Release soon';
    }
}

function setupReleaseNotes(bodyText) {
    const parsedHtml = marked.parse(bodyText);
    const contentEl = document.getElementById('changelog-content');
    contentEl.innerHTML = parsedHtml;

    const detailsEl = document.getElementById('changelog-details');
    const MAX_HEIGHT = 150;

    setTimeout(() => {
        if (contentEl.scrollHeight > MAX_HEIGHT) {
            detailsEl.classList.add('is-collapsible');
        } else {
            detailsEl.setAttribute('open', 'true');
            detailsEl.classList.add('is-expanded');
        }
    }, 50);
}

fetch(apiUrl)
    .then(response => {
    if (!response.ok) throw new Error('Release not found');
    return response.json();
    })
    .then(data => {
        document.getElementById('version').textContent = `Latest version: ${data.tag_name}`;

        const assets = data.assets || [];
        const bodyText = data.body || "";

        const winAsset = assets.find(a => a.name.endsWith('.exe'));
        const winMsiAsset = assets.find(a => a.name.endsWith('.msi'));
        const winZipAsset = assets.find(a => a.name.endsWith('.zip'));
        const linuxAsset = assets.find(a => a.name.endsWith('.AppImage') || a.name.endsWith('.deb') || a.name.endsWith('.tar'));
        const linuxDebAsset = assets.find(a => a.name.endsWith('.deb'));
        const linuxTarAsset = assets.find(a => a.name.endsWith('.tar'));
        const androidAsset = assets.find(a => a.name.endsWith('.apk'))

        setupReleaseNotes(bodyText);

        setupButton('btn-win', 'meta-win', 'dwn-win', winAsset);
        setupButton('btn-win-msi', 'meta-win-msi', 'dwn-win-msi', winMsiAsset);
        setupButton('btn-win-zip', 'meta-win-zip', 'dwn-win-zip', winZipAsset);
        setupButton('btn-linux', 'meta-linux', 'dwn-linux', linuxAsset);
        setupButton('btn-linux-deb', 'meta-linux-deb', 'dwn-linux-deb', linuxDebAsset);
        setupButton('btn-linux-tar', 'meta-linux-tar', 'dwn-linux-tar', linuxTarAsset);
        setupButton('btn-android', 'meta-android', 'dwn-android', androidAsset);
    })
    .catch(error => {
    console.error('Error while checking latest release:', error);
    document.getElementById('version').textContent = 'Latest release on GitHub';
    
    ['win', 'linux', 'android'].forEach(os => {
        const btn = document.getElementById(`btn-${os}`);
        const meta = document.getElementById(`meta-${os}`);
        btn.href = repoUrl;
        btn.classList.remove('disabled');
        meta.textContent = 'Go to download';
    });
});