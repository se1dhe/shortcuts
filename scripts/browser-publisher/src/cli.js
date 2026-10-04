#!/usr/bin/env node

import { launchBrowser } from './browser.js';
import { openInteractiveLogin, checkAuthStatus } from './login.js';
import { uploadToTikTok } from './tiktok.js';
import { uploadToInstagram } from './instagram.js';
import { uploadToYouTube } from './youtube.js';
import fs from 'fs';

async function main() {
  const args = process.argv.slice(2);

  // Command: --login
  if (args.includes('--login')) {
    await openInteractiveLogin();
    process.exit(0);
  }

  // Command: --check-auth
  if (args.includes('--check-auth')) {
    const { context } = await launchBrowser({ headless: true });
    const report = await checkAuthStatus(context);
    await context.close().catch(() => {});
    console.log(JSON.stringify({ type: 'auth_report', auth: report }));
    process.exit(0);
  }

  // Command: --upload
  if (args.includes('--upload')) {
    const jobIndex = args.indexOf('--job');
    let jobData;

    if (jobIndex !== -1 && args[jobIndex + 1]) {
      const jobPath = args[jobIndex + 1];
      const raw = fs.readFileSync(jobPath, 'utf8');
      jobData = JSON.parse(raw);
    } else {
      // Parse individual flags
      const getArg = (flag) => {
        const idx = args.indexOf(flag);
        return idx !== -1 ? args[idx + 1] : null;
      };

      jobData = {
        videoPath: getArg('--video'),
        platforms: (getArg('--platforms') || 'tiktok,instagram,youtube').split(',').map((s) => s.trim().toLowerCase()),
        title: getArg('--title') || 'Shorts',
        caption: getArg('--caption') || '',
        hashtags: (getArg('--hashtags') || '').split(',').map((s) => s.trim()).filter(Boolean),
        isPublic: getArg('--public') !== 'false',
        headless: getArg('--headless') !== 'false',
      };
    }

    if (!jobData.videoPath || !fs.existsSync(jobData.videoPath)) {
      console.error(JSON.stringify({ type: 'error', message: `Видеофайл не найден: ${jobData.videoPath}` }));
      process.exit(1);
    }

    const { context, page } = await launchBrowser({ headless: jobData.headless !== false });

    const results = {};

    for (const platform of jobData.platforms) {
      const content = (jobData.platformContent && jobData.platformContent[platform]) || {
        title: jobData.title,
        caption: jobData.caption,
        hashtags: jobData.hashtags
      };

      try {
        if (platform === 'tiktok') {
          await uploadToTikTok(page, {
            videoPath: jobData.videoPath,
            caption: content.caption,
            hashtags: content.hashtags,
            isDraft: !jobData.isPublic,
          });
          results.tiktok = { status: 'success' };
        } else if (platform === 'instagram') {
          await uploadToInstagram(page, {
            videoPath: jobData.videoPath,
            caption: content.caption,
            hashtags: content.hashtags,
          });
          results.instagram = { status: 'success' };
        } else if (platform === 'youtube') {
          await uploadToYouTube(page, {
            videoPath: jobData.videoPath,
            title: content.title || jobData.title,
            caption: content.caption,
            hashtags: content.hashtags,
            isPublic: jobData.isPublic,
            isShort: jobData.isShort === true,
          });
          results.youtube = { status: 'success' };
        }
      } catch (err) {
        console.log(JSON.stringify({
          type: 'error',
          platform,
          message: err.message,
        }));
        results[platform] = { status: 'error', message: err.message };
      }
    }

    await context.close().catch(() => {});

    console.log(JSON.stringify({
      type: 'completed',
      results,
    }));

    process.exit(0);
  }

  console.log(JSON.stringify({
    type: 'help',
    message: 'Usage: cli.js [--login | --check-auth | --upload --job <path>]',
  }));
}

main().catch((err) => {
  console.error(JSON.stringify({ type: 'fatal_error', message: err.message }));
  process.exit(1);
});
