// Vercel Serverless Function — Real-time O3 from AirNow S3
// Endpoint: /api/realtime?aqs=28-033-0002

// The only monitors this dashboard shows. Keep in step with
// r-pipeline/sites_config.R (exported as data/sites_config.json). Anything else
// is refused before any download: an unknown id used to walk all 8 hourly files
// (~5 MB) and, as a fresh cache key, bypass the CDN cache on every request.
const SITES = new Set([
  '28-033-0002', // Hernando
  '28-049-0020', // Jackson NCORE
  '28-049-0021', // Hinds CC
  '28-045-0003', // Waveland
  '28-047-0008', // Gulfport
  '28-059-0006', // Pascagoula
]);

// Per-file and whole-request time limits, so a slow S3 can't hold the function.
const FETCH_TIMEOUT_MS = 4000;
const DEADLINE_MS = 9000;

export default async function handler(req, res) {
  const aqsId = req.query.aqs;
  if (!aqsId) {
    return res.status(400).json({ error: 'Missing ?aqs= parameter' });
  }
  // A repeated parameter (?aqs=a&aqs=b) arrives as an array.
  if (typeof aqsId !== 'string' || !SITES.has(aqsId)) {
    return res.status(400).json({ error: 'Unknown ?aqs= site' });
  }

  const cleanAqs = aqsId.replace(/-/g, '');
  const now = new Date();

  for (let offset = -1; offset <= 6; offset++) {
    const timeLeft = DEADLINE_MS - (Date.now() - now.getTime());
    if (timeLeft <= 0) break;
    const checkTime = new Date(now.getTime() - offset * 3600000);
    const yStr = checkTime.getUTCFullYear().toString();
    const ymdStr = checkTime.toISOString().slice(0, 10).replace(/-/g, '');
    const hStr = checkTime.getUTCHours().toString().padStart(2, '0');

    const url = `https://s3-us-west-1.amazonaws.com/files.airnowtech.org/airnow/${yStr}/${ymdStr}/HourlyData_${ymdStr}${hStr}.dat`;

    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(Math.min(FETCH_TIMEOUT_MS, timeLeft)) });
      if (!response.ok) continue;

      const text = await response.text();
      for (const line of text.split('\n')) {
        const parts = line.split('|');
        if (parts.length >= 8 && parts[2].trim() === cleanAqs && parts[5].trim() === 'OZONE') {
          const valPpm = parseFloat(parts[7].trim()) / 1000;
          res.setHeader('Cache-Control', 's-maxage=300, stale-while-revalidate=600');
          return res.status(200).json({ value: valPpm, time: `${ymdStr} ${hStr}:00 UTC` });
        }
      }
    } catch {
      continue;
    }
  }

  res.setHeader('Cache-Control', 's-maxage=120');
  return res.status(200).json({ value: null, time: null });
}
