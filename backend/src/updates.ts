// backend/src/updates.ts

export interface UpdateInfo {
  hasUpdate: boolean;
  currentVersion: string;
  latestVersion: string;
  releaseDate: string;
  downloadUrl: string;
  releaseNotes: string;
  minimumOsVersion: string;
  mandatory: boolean;
  sha256?: string;
}

export const LATEST_RELEASE = {
  version: '1.0.1',
  releaseDate: '2026-09-17',
  downloadUrl: '/downloads/Sidebrief.dmg',
  minimumOsVersion: '14.0',
  mandatory: false,
  releaseNotes: [
    '• Frontier Model Support: Claude 5 Sonnet & GPT-5.6 Luna Pro via OpenRouter',
    '• ElevenLabs Scribe v2 streaming STT with real-time VAD overlap deduplication',
    '• Streamlined Single Context Space: Default to "Work" workspace with customized copilot personas',
    '• Native Audio Diagnostics: Interactive VU meters, 440/880Hz test tone, and ScreenCaptureKit loopback test',
    '• Per-User Speaker Reference Directory with instant prompt context injection',
    '• Offline-resilient License Manager & In-App Software Update Checker'
  ].join('\n'),
};

/**
 * Compares two semantic version strings (e.g. "1.0.1" vs "1.0.0").
 * Returns true if remoteVersion is strictly greater than currentVersion.
 */
export function isNewerVersion(remoteVersion: string, currentVersion: string): boolean {
  const cleanRemote = remoteVersion.replace(/^[vV]/, '').trim();
  const cleanCurrent = currentVersion.replace(/^[vV]/, '').trim();

  const rParts = cleanRemote.split('.').map(n => parseInt(n, 10) || 0);
  const cParts = cleanCurrent.split('.').map(n => parseInt(n, 10) || 0);

  const length = Math.max(rParts.length, cParts.length);
  for (let i = 0; i < length; i++) {
    const r = rParts[i] || 0;
    const c = cParts[i] || 0;
    if (r > c) return true;
    if (r < c) return false;
  }
  return false;
}

/**
 * Checks for updates given a client version.
 */
export function checkUpdate(clientVersion: string = '1.0.0', baseUrl: string = ''): UpdateInfo {
  const hasUpdate = isNewerVersion(LATEST_RELEASE.version, clientVersion);
  const fullDownloadUrl = LATEST_RELEASE.downloadUrl.startsWith('http')
    ? LATEST_RELEASE.downloadUrl
    : `${baseUrl}${LATEST_RELEASE.downloadUrl}`;

  return {
    hasUpdate,
    currentVersion: clientVersion,
    latestVersion: LATEST_RELEASE.version,
    releaseDate: LATEST_RELEASE.releaseDate,
    downloadUrl: fullDownloadUrl,
    releaseNotes: LATEST_RELEASE.releaseNotes,
    minimumOsVersion: LATEST_RELEASE.minimumOsVersion,
    mandatory: LATEST_RELEASE.mandatory,
  };
}

/**
 * Sparkle-compatible Appcast Feed JSON.
 */
export function getAppcastFeed(baseUrl: string = ''): object {
  const downloadUrl = LATEST_RELEASE.downloadUrl.startsWith('http')
    ? LATEST_RELEASE.downloadUrl
    : `${baseUrl}${LATEST_RELEASE.downloadUrl}`;

  return {
    version: '1.0',
    title: 'Sidebrief Updates',
    description: 'Latest releases for Sidebrief macOS copilot',
    feed_url: `${baseUrl}/api/v1/updates/appcast.json`,
    items: [
      {
        version: LATEST_RELEASE.version,
        title: `Sidebrief ${LATEST_RELEASE.version}`,
        pub_date: LATEST_RELEASE.releaseDate,
        url: downloadUrl,
        short_version: LATEST_RELEASE.version,
        release_notes: LATEST_RELEASE.releaseNotes,
        minimum_system_version: LATEST_RELEASE.minimumOsVersion,
      },
    ],
  };
}
