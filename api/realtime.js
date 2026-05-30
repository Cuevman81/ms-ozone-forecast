// Vercel Serverless Function — Real-time O3 from AirNow S3
// Endpoint: /api/realtime?aqs=28-033-0002

export default async function handler(req, res) {
  const aqsId = req.query.aqs;
  if (!aqsId) {
    return res.status(400).json({ error: 'Missing ?aqs= parameter' });
  }

  const cleanAqs = aqsId.replace(/-/g, '');
  const now = new Date();

  for (let offset = -1; offset <= 6; offset++) {
    const checkTime = new Date(now.getTime() - offset * 3600000);
    const yStr = checkTime.getUTCFullYear().toString();
    const ymdStr = checkTime.toISOString().slice(0, 10).replace(/-/g, '');
    const hStr = checkTime.getUTCHours().toString().padStart(2, '0');

    const url = `https://s3-us-west-1.amazonaws.com/files.airnowtech.org/airnow/${yStr}/${ymdStr}/HourlyData_${ymdStr}${hStr}.dat`;

    try {
      const response = await fetch(url);
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
