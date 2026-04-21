#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const os = require("os");

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
const SETTINGS_FILE = path.join(CLAUDE_DIR, "settings.json");
const STATUSLINE_DEST = path.join(CLAUDE_DIR, "statusline.sh");
const STATUSLINE_SRC = path.resolve(__dirname, "statusline.sh");

const blue = "\x1b[38;2;0;153;255m";
const green = "\x1b[38;2;0;175;80m";
const red = "\x1b[38;2;255;85;85m";
const yellow = "\x1b[38;2;230;200;0m";
const dim = "\x1b[2m";
const reset = "\x1b[0m";

function log(msg) {
  console.log(`  ${msg}`);
}

function success(msg) {
  console.log(`  ${green}✓${reset} ${msg}`);
}

function warn(msg) {
  console.log(`  ${yellow}!${reset} ${msg}`);
}

function fail(msg) {
  console.error(`  ${red}✗${reset} ${msg}`);
}

function checkDeps() {
  const { execSync } = require("child_process");
  const missing = [];
  const missingOptional = [];

  for (const bin of ["jq", "curl", "git"]) {
    try {
      execSync(`which ${bin}`, { stdio: "ignore" });
    } catch {
      missing.push(bin);
    }
  }

  try {
    execSync("which ccusage", { stdio: "ignore" });
  } catch {
    missingOptional.push("ccusage");
  }

  return { missing, missingOptional };
}

function uninstall() {
  console.log();
  console.log(`  ${blue}cc-pretty-statusline uninstaller${reset}`);
  console.log(`  ${dim}────────────────────────────────${reset}`);
  console.log();

  const backup = STATUSLINE_DEST + ".bak";

  if (fs.existsSync(backup)) {
    fs.copyFileSync(backup, STATUSLINE_DEST);
    fs.unlinkSync(backup);
    success(`Restored previous statusline from ${dim}statusline.sh.bak${reset}`);
  } else if (fs.existsSync(STATUSLINE_DEST)) {
    fs.unlinkSync(STATUSLINE_DEST);
    success(`Removed ${dim}statusline.sh${reset}`);
  } else {
    warn("No statusline found — nothing to remove");
  }

  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      const settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf-8"));
      if (settings.statusLine) {
        delete settings.statusLine;
        fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
        success(`Removed statusLine from ${dim}settings.json${reset}`);
      } else {
        success("Settings already clean");
      }
    } catch {
      fail(`Could not parse ${SETTINGS_FILE} — fix it manually`);
      process.exit(1);
    }
  }

  console.log();
  log(`${green}Done!${reset} Restart Claude Code to apply changes.`);
  console.log();
}

function parseThemeFlag() {
  const idx = process.argv.indexOf("--theme");
  if (idx === -1) return null;
  const val = process.argv[idx + 1];
  if (!["auto", "light", "dark"].includes(val)) {
    fail(`Invalid --theme value: ${val || "(missing)"}. Expected auto, light, or dark.`);
    process.exit(1);
  }
  return val;
}

function promptTheme() {
  if (!process.stdin.isTTY) return Promise.resolve("auto");
  const readline = require("readline");
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    console.log(`  Choose a palette:`);
    console.log(`    ${dim}1)${reset} auto   — follow terminal / macOS appearance ${dim}(default)${reset}`);
    console.log(`    ${dim}2)${reset} light`);
    console.log(`    ${dim}3)${reset} dark`);
    rl.question(`  Choice [1-3]: `, (answer) => {
      rl.close();
      const a = String(answer || "").trim().toLowerCase();
      if (a === "2" || a === "light") resolve("light");
      else if (a === "3" || a === "dark") resolve("dark");
      else resolve("auto");
    });
  });
}

function buildStatusLineCommand(theme) {
  const themePrefix = theme === "auto" ? "" : `CLAUDE_STATUSLINE_THEME=${theme} `;
  return `${themePrefix}bash "${STATUSLINE_DEST}"`;
}

async function run() {
  if (process.argv.includes("--uninstall")) {
    uninstall();
    return;
  }

  console.log();
  console.log(`  ${blue}cc-pretty-statusline installer${reset}`);
  console.log(`  ${dim}──────────────────────────────${reset}`);
  console.log();

  const { missing, missingOptional } = checkDeps();
  if (missing.length > 0) {
    fail(`Missing required dependencies: ${missing.join(", ")}`);
    log(`  Install them and try again.`);
    if (missing.includes("jq")) {
      log(`  ${dim}brew install jq${reset}`);
    }
    process.exit(1);
  }
  success("Dependencies found (jq, curl, git)");
  if (missingOptional.includes("ccusage")) {
    warn(`ccusage not found — cost line will be hidden.`);
    log(`  ${dim}npm i -g ccusage${reset}   ${dim}# https://github.com/ryoppippi/ccusage${reset}`);
  }

  let theme = parseThemeFlag();
  if (theme === null) {
    theme = await promptTheme();
  }
  if (theme === "auto") {
    success(`Palette: ${dim}auto${reset} (detected per render)`);
  } else {
    success(`Palette: ${dim}${theme}${reset} (pinned)`);
  }

  if (!fs.existsSync(CLAUDE_DIR)) {
    fs.mkdirSync(CLAUDE_DIR, { recursive: true });
    success(`Created ${CLAUDE_DIR}`);
  }

  const backup = STATUSLINE_DEST + ".bak";
  if (fs.existsSync(STATUSLINE_DEST)) {
    fs.copyFileSync(STATUSLINE_DEST, backup);
    warn(`Backed up existing statusline to ${dim}statusline.sh.bak${reset}`);
  }

  fs.copyFileSync(STATUSLINE_SRC, STATUSLINE_DEST);
  fs.chmodSync(STATUSLINE_DEST, 0o755);
  success(`Installed statusline to ${dim}${STATUSLINE_DEST}${reset}`);

  let settings = {};
  if (fs.existsSync(SETTINGS_FILE)) {
    try {
      settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf-8"));
    } catch {
      fail(`Could not parse ${SETTINGS_FILE} — fix it manually`);
      process.exit(1);
    }
  }

  const statusLineConfig = {
    type: "command",
    command: buildStatusLineCommand(theme),
    padding: 0,
  };

  if (
    settings.statusLine &&
    settings.statusLine.type === "command" &&
    settings.statusLine.command === statusLineConfig.command &&
    settings.statusLine.padding === 0
  ) {
    success("Settings already configured");
  } else {
    settings.statusLine = statusLineConfig;
    fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");
    success(`Updated ${dim}settings.json${reset} with statusLine config`);
  }

  console.log();
  log(`${green}Done!${reset} Restart Claude Code to see your new status line.`);
  if (theme === "auto") {
    log(`${dim}  Tip: for terminals that don't follow macOS appearance,${reset}`);
    log(`${dim}  bind ~/.claude/statusline.sh --set-theme light|dark${reset}`);
    log(`${dim}  to your terminal's theme-toggle action.${reset}`);
  } else {
    log(`${dim}  Re-run with --theme auto to switch to adaptive detection.${reset}`);
  }
  console.log();
}

run().catch((err) => {
  fail(String(err && err.stack || err));
  process.exit(1);
});
