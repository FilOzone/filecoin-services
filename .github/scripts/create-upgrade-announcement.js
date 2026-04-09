#!/usr/bin/env node
/**
 * Create FWSS Contract Upgrade Release Issue
 *
 * Renders the release issue body from service_contracts/tools/UPGRADE-CHECKLIST.md
 * so the checklist template can evolve on the same branch as the release prep.
 */

const fs = require("fs");
const path = require("path");
const https = require("https");

const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const showHelp = args.includes("--help") || args.includes("-h");

if (showHelp) {
  console.log(`
Create FWSS Contract Upgrade Release Issue

Usage:
  node create-upgrade-announcement.js [options]

Options:
  --dry-run       Output issue text without creating an issue
  --help          Show this help message

Environment variables:
  NETWORK              Target network (Calibnet or Mainnet)
  RELEASE_VERSION      FWSS release version for the issue title (default: vX.Y.Z)
  UPGRADE_TYPE         Type of upgrade (Routine or Breaking Change)
  CHANGELOG_PR         PR number or link for release-prep changelog updates (optional)
  CHANGES_SUMMARY      Summary of changes (use | for multiple lines, optional)
  ACTION_REQUIRED      Action required for integrators (optional, default: TBD)
  GITHUB_TOKEN         GitHub token (required when not using --dry-run)
  GITHUB_REPOSITORY    Repository in format owner/repo (required when not using --dry-run)

Example:
  NETWORK=Mainnet RELEASE_VERSION=v1.2.3 UPGRADE_TYPE=Routine \
  node .github/scripts/create-upgrade-announcement.js --dry-run
`);
  process.exit(0);
}

const config = {
  network: process.env.NETWORK,
  releaseVersion: (process.env.RELEASE_VERSION || "vX.Y.Z").trim(),
  upgradeType: process.env.UPGRADE_TYPE,
  changelogPr: (process.env.CHANGELOG_PR || "").trim(),
  changesSummary: (process.env.CHANGES_SUMMARY || "").trim(),
  actionRequired: (process.env.ACTION_REQUIRED || "TBD").trim(),
  githubToken: process.env.GITHUB_TOKEN,
  githubRepository: process.env.GITHUB_REPOSITORY,
};

function validateConfig() {
  const required = ["network", "upgradeType"];
  const missing = required.filter((key) => !config[key]);

  if (missing.length > 0) {
    console.error(`Error: Missing required environment variables: ${missing.join(", ")}`);
    console.error("Run with --help for usage information.");
    process.exit(1);
  }

  if (!dryRun) {
    if (!config.githubToken) {
      console.error("Error: GITHUB_TOKEN is required when not using --dry-run");
      process.exit(1);
    }
    if (!config.githubRepository) {
      console.error("Error: GITHUB_REPOSITORY is required when not using --dry-run");
      process.exit(1);
    }
  }
}

function formatBulletList(value, fallback = "- TBD") {
  if (!value) {
    return fallback;
  }

  const items = value
    .split("|")
    .map((line) => line.trim())
    .filter(Boolean);

  if (items.length === 0) {
    return fallback;
  }

  return items.map((line) => `- ${line}`).join("\n");
}

function formatActionRequired(value) {
  if (!value) {
    return "TBD";
  }

  if (value.includes("|")) {
    return formatBulletList(value);
  }

  return value;
}

function formatChangelogPr(baseUrl) {
  if (!config.changelogPr) {
    return "TBD (link PR after opening)";
  }

  const normalized = config.changelogPr.replace(/^#/, "");
  if (/^\d+$/.test(normalized)) {
    return `[#${normalized}](${baseUrl}/pull/${normalized})`;
  }

  return config.changelogPr;
}

function loadIssueTemplate() {
  const templatePath = path.resolve(__dirname, "../../service_contracts/tools/UPGRADE-CHECKLIST.md");
  const source = fs.readFileSync(templatePath, "utf8");
  const startMarker = "<!-- ISSUE_TEMPLATE_START -->";
  const endMarker = "<!-- ISSUE_TEMPLATE_END -->";
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker);

  if (start === -1 || end === -1 || end <= start) {
    throw new Error(`Could not find issue template markers in ${templatePath}`);
  }

  return source.slice(start + startMarker.length, end).trim();
}

function replaceAll(template, replacements) {
  let rendered = template;
  for (const [key, value] of Object.entries(replacements)) {
    rendered = rendered.split(`{{${key}}}`).join(value);
  }
  return rendered;
}

function generateTitle() {
  const mainnetSuffix = config.network === "Mainnet" ? " (includes Calibnet)" : "";
  return `[Release] FWSS ${config.releaseVersion} ${config.network} Upgrade${mainnetSuffix}`;
}

function generateBody() {
  const [owner, repo] = (config.githubRepository || "FilOzone/filecoin-services").split("/");
  const baseUrl = `https://github.com/${owner}/${repo}`;
  const recommendedPrTitle = `feat: FWSS ${config.releaseVersion} upgrade`;
  const releaseBranch = `release-${config.releaseVersion}`;

  const replacements = {
    RELEASE_VERSION: config.releaseVersion,
    UPGRADE_TYPE: config.upgradeType,
    CHANGELOG_PR: formatChangelogPr(baseUrl),
    CHANGES_SUMMARY: formatBulletList(config.changesSummary),
    ACTION_REQUIRED: formatActionRequired(config.actionRequired),
    RELEASE_BRANCH: releaseBranch,
    RECOMMENDED_PR_TITLE: recommendedPrTitle,
    CHANGELOG_LINK: `${baseUrl}/blob/main/CHANGELOG.md`,
    FWSS_CONTRACT_LINK: `${baseUrl}/blob/main/service_contracts/src/FilecoinWarmStorageService.sol`,
    UPGRADE_PROCESS_LINK: `${baseUrl}/blob/main/service_contracts/tools/UPGRADE-PROCESS.md`,
    CHECKLIST_LINK: `${baseUrl}/blob/main/service_contracts/tools/UPGRADE-CHECKLIST.md`,
    DEPLOY_WORKFLOW_LINK: `${baseUrl}/actions/workflows/deploy-contract.yml`,
    CREATE_ISSUE_WORKFLOW_LINK: `${baseUrl}/actions/workflows/create-upgrade-announcement-issue.yml`,
  };

  return replaceAll(loadIssueTemplate(), replacements);
}

function generateLabels() {
  const labels = ["release"];
  if (config.upgradeType === "Breaking Change") {
    labels.push("breaking-change");
  }
  return labels;
}

async function createGitHubIssue(title, body, labels) {
  const [owner, repo] = config.githubRepository.split("/");

  return new Promise((resolve, reject) => {
    const postData = JSON.stringify({ title, body, labels });

    const options = {
      hostname: "api.github.com",
      path: `/repos/${owner}/${repo}/issues`,
      method: "POST",
      headers: {
        Authorization: `Bearer ${config.githubToken}`,
        Accept: "application/vnd.github+json",
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(postData),
        "User-Agent": "create-upgrade-announcement-script",
        "X-GitHub-Api-Version": "2022-11-28",
      },
    };

    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        try {
          const result = JSON.parse(data);
          if (res.statusCode === 201) {
            resolve(result);
          } else {
            reject(new Error(`GitHub API error: ${res.statusCode} - ${result.message || data}`));
          }
        } catch (e) {
          reject(e);
        }
      });
    });

    req.on("error", reject);
    req.write(postData);
    req.end();
  });
}

async function main() {
  validateConfig();

  const title = generateTitle();
  const body = generateBody();
  const labels = generateLabels();

  if (dryRun) {
    console.log("=== DRY RUN - Issue Preview ===\n");
    console.log(`Title: ${title}\n`);
    console.log(`Labels: ${labels.join(", ")}\n`);
    console.log("--- Body ---");
    console.log(body);
    console.log("\n=== End of Preview ===");

    if (process.env.GITHUB_OUTPUT) {
      fs.appendFileSync(process.env.GITHUB_OUTPUT, `title=${title}\n`);
      fs.appendFileSync(process.env.GITHUB_OUTPUT, `labels=${labels.join(",")}\n`);
      fs.appendFileSync(process.env.GITHUB_OUTPUT, `body<<EOF\n${body}\nEOF\n`);
    }
    return;
  }

  console.log("Creating GitHub issue...");
  try {
    const issue = await createGitHubIssue(title, body, labels);
    console.log(`Created issue #${issue.number}: ${issue.html_url}`);

    if (process.env.GITHUB_OUTPUT) {
      fs.appendFileSync(process.env.GITHUB_OUTPUT, `issue_number=${issue.number}\n`);
      fs.appendFileSync(process.env.GITHUB_OUTPUT, `issue_url=${issue.html_url}\n`);
    }
  } catch (error) {
    console.error("Failed to create issue:", error.message);
    process.exit(1);
  }
}

main();
