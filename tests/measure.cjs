// Peak RSS includes Node runtime, input bytes and codec allocations.
// The timer starts immediately before loading the CLI, after Node has bootstrapped.
const fs = require('node:fs');
const path = require('node:path');
const [cli, report, ...args] = process.argv.slice(2);
const start = process.hrtime.bigint();
process.on('exit', (code) => {
  fs.writeFileSync(report, JSON.stringify({
    exit_code: code,
    seconds: Number(process.hrtime.bigint() - start) / 1e9,
    peak_rss_mib: process.resourceUsage().maxRSS / 1024,
    node: process.version,
    platform: process.platform,
  }));
});
process.argv = [process.argv[0], path.resolve(cli), ...args];
require(path.resolve(cli));
