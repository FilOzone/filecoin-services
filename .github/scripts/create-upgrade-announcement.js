#!/usr/bin/env node
/**
 * Create FWSS Contract Upgrade Announcement Issue
 *
 * Usage:
 *   node create-upgrade-announcement.js [options]
 *
 * Options:
 *   --dry-run       Output issue text without creating an issue
 *   --help          Show this help message
 *
 * Environment variables (required unless --dry-run with minimal output):
 *   NETWORK              Target network (Calibnet or Mainnet)
 *   UPGRADE_TYPE         Type of upgrade (Routine or Breaking Change)
 *   AFTER_EPOCH          Block number after which upgrade can execute
 *   CHANGELOG_PR         PR number with changelog updates
 *   CHANGES_SUMMARY      Summary of changes (use | for multiple lines)
 *   ACTION_REQUIRED      Action required for integrators (default: None)
 *   UPGRADE_FWSS         Upgrading FilecoinWarmStorageService? (true/false)
 *   UPGRADE_REGISTRY     Upgrading ServiceProviderRegistry? (true/false)
 *   UPGRADE_STATE_VIEW   Upgrading FilecoinWarmStorageServiceStateView? (true/false)
 *   RELEASE_TAG          Release tag if already created (optional)
 *
 * GitHub-specific environment variables (required when not using --dry-run):
 *   GITHUB_TOKEN         GitHub token with issues:write permission
 *   GITHUB_REPOSITORY    Repository in format owner/repo
 */

const https = require("https");

// Parse command line arguments
const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const showHelp = args.includes("--help") || args.includes("-h");

if (showHelp) {
  console.log(`
Create FWSS Contract Upgrade Announcement Issue

Usage:
  node create-upgrade-announcement.js [options]

Options:
  --dry-run       Output issue text without creating an issue
  --help          Show this help message

Environment variables:
  NETWORK              Target network (Calibnet or Mainnet)
  UPGRADE_TYPE         Type of upgrade (Routine or Breaking Change)
  AFTER_EPOCH          Block number after which upgrade can execute
  CHANGELOG_PR         PR number with changelog updates
  CHANGES_SUMMARY      Summary of changes (use | for multiple lines)
  ACTION_REQUIRED      Action required for integrators (default: None)
  UPGRADE_FWSS         Upgrading FilecoinWarmStorageService? (true/false, default: true)
  UPGRADE_REGISTRY     Upgrading ServiceProviderRegistry? (true/false, default: false)
  UPGRADE_STATE_VIEW   Upgrading FilecoinWarmStorageServiceStateView? (true/false, default: false)
  RELEASE_TAG          Release tag if already created (optional)
  GITHUB_TOKEN         GitHub token (required when not using --dry-run)
  GITHUB_REPOSITORY    Repository in format owner/repo (required when not using --dry-run)

Example:
  NETWORK=Calibnet UPGRADE_TYPE=Routine AFTER_EPOCH=12345 \\
  CHANGELOG_PR=100 CHANGES_SUMMARY="Fix bug|Add feature" \\
  node create-upgrade-announcement.js --dry-run
`);
  process.exit(0);
}

// Get configuration from environment
const config = {
  network: process.env.NETWORK,
  upgradeType: process.env.UPGRADE_TYPE,
  afterEpoch: process.env.AFTER_EPOCH,
  changelogPr: process.env.CHANGELOG_PR,
  changesSummary: process.env.CHANGES_SUMMARY,
  actionRequired: process.env.ACTION_REQUIRED || "None",
  upgradeFwss: process.env.UPGRADE_FWSS !== "false",
  upgradeRegistry: process.env.UPGRADE_REGISTRY === "true",
  upgradeStateView: process.env.UPGRADE_STATE_VIEW === "true",
  releaseTag: process.env.RELEASE_TAG || "",
  githubToken: process.env.GITHUB_TOKEN,
  githubRepository: process.env.GITHUB_REPOSITORY,
  // Optional: pre-computed time estimate (from workflow)
  timeEstimate: process.env.TIME_ESTIMATE,
};

// Validate required fields
function validateConfig() {
  const required = ["network", "upgradeType", "afterEpoch", "changelogPr", "changesSummary"];
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

// Fetch current epoch from Filecoin RPC
async function getCurrentEpoch(network) {
  const rpcUrl =
    network === "Mainnet"
      ? "https://api.node.glif.io/rpc/v1"
      : "https://api.calibration.node.glif.io/rpc/v1";

  return new Promise((resolve, reject) => {
    const url = new URL(rpcUrl);
    const postData = JSON.stringify({
      jsonrpc: "2.0",
      method: "eth_blockNumber",
      params: [],
      id: 1,
    });

    const options = {
      hostname: url.hostname,
      path: url.pathname,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(postData),
      },
    };

    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        try {
          const result = JSON.parse(data);
          if (result.result) {
            resolve(parseInt(result.result, 16));
          } else {
            reject(new Error("Invalid RPC response"));
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

// Calculate estimated execution time
async function calculateTimeEstimate(network, afterEpoch) {
  // If pre-computed estimate is provided, use it
  if (config.timeEstimate) {
    return config.timeEstimate;
  }

  try {
    const currentEpoch = await getCurrentEpoch(network);
    const epochsRemaining = afterEpoch - currentEpoch;

    if (epochsRemaining < 0) {
      return "Immediately (epoch already passed)";
    }

    // Filecoin has ~30 second block times
    const secondsRemaining = epochsRemaining * 30;
    const hours = Math.floor(secondsRemaining / 3600);
    const minutes = Math.floor((secondsRemaining % 3600) / 60);

    const futureDate = new Date(Date.now() + secondsRemaining * 1000);
    const dateStr = futureDate.toISOString().replace("T", " ").substring(0, 16) + " UTC";

    return `~${dateStr} (~${hours}h ${minutes}m from current epoch ${currentEpoch})`;
  } catch (error) {
    console.error("Warning: Could not fetch current epoch:", error.message);
    return "Unknown (could not fetch current epoch)";
  }
}

// Format changes summary from pipe-separated to bullet points
function formatChanges(changesSummary) {
  return changesSummary
    .split("|")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => `- ${line}`)
    .join("\n");
}

// Build the list of contracts being upgraded
function buildContractsList() {
  const contracts = [];

  if (config.upgradeFwss) {
    contracts.push("- FilecoinWarmStorageService");
  }
  if (config.upgradeRegistry) {
    contracts.push("- ServiceProviderRegistry");
  }
  if (config.upgradeStateView) {
    contracts.push("- FilecoinWarmStorageServiceStateView");
  }

  // Default to FilecoinWarmStorageService if none selected
  if (contracts.length === 0) {
    contracts.push("- FilecoinWarmStorageService");
  }

  return contracts.join("\n");
}

// Generate issue title
function generateTitle() {
  return `[Upgrade] FWSS Contract - ${config.network} - Epoch ${config.afterEpoch}`;
}

// Generate issue body
function generateBody(timeEstimate) {
  const [owner, repo] = (config.githubRepository || "OWNER/REPO").split("/");
  const baseUrl = `https://github.com/${owner}/${repo}`;

  const changelogPrLink = `${baseUrl}/pull/${config.changelogPr}`;
  const changelogLink = `${baseUrl}/blob/main/CHANGELOG.md`;
  const upgradeProcessLink = `${baseUrl}/blob/main/service_contracts/tools/UPGRADE-PROCESS.md`;
  const releaseLink = config.releaseTag ? `${baseUrl}/releases/tag/${config.releaseTag}` : null;

  const changes = formatChanges(config.changesSummary);
  const contracts = buildContractsList();

  return `## FWSS Contract Upgrade Announcement

**Network**: ${config.network}
**Upgrade Type**: ${config.upgradeType}
**Scheduled Execution**: After epoch ${config.afterEpoch} (${timeEstimate})

### Changes
${changes}
- [Link to PR/release notes](${changelogPrLink})

### Contracts Planned for Upgrade
${contracts}

### Action Required
${config.actionRequired}

### Resources
${releaseLink ? `- Release: ${releaseLink}` : "- Release: [link] (if applicable)"}
- Changelog: ${changelogLink}
- Upgrade Process: ${upgradeProcessLink}`;
}

// Generate labels for the issue
function generateLabels() {
  const labels = ["upgrade"];
  if (config.upgradeType === "Breaking Change") {
    labels.push("breaking-change");
  }
  return labels;
}

// Create GitHub issue
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

// Main execution
async function main() {
  validateConfig();

  const timeEstimate = await calculateTimeEstimate(config.network, parseInt(config.afterEpoch));
  const title = generateTitle();
  const body = generateBody(timeEstimate);
  const labels = generateLabels();

  if (dryRun) {
    console.log("=== DRY RUN - Issue Preview ===\n");
    console.log(`Title: ${title}\n`);
    console.log(`Labels: ${labels.join(", ")}\n`);
    console.log("--- Body ---");
    console.log(body);
    console.log("\n=== End of Preview ===");

    // Output in GitHub Actions format if running in that context
    if (process.env.GITHUB_OUTPUT) {
      const fs = require("fs");
      fs.appendFileSync(process.env.GITHUB_OUTPUT, `title=${title}\n`);
      fs.appendFileSync(process.env.GITHUB_OUTPUT, `labels=${labels.join(",")}\n`);
      // For multiline body, use delimiter syntax
      fs.appendFileSync(process.env.GITHUB_OUTPUT, `body<<EOF\n${body}\nEOF\n`);
    }
  } else {
    console.log("Creating GitHub issue...");
    try {
      const issue = await createGitHubIssue(title, body, labels);
      console.log(`Created issue #${issue.number}: ${issue.html_url}`);

      // Output for GitHub Actions
      if (process.env.GITHUB_OUTPUT) {
        const fs = require("fs");
        fs.appendFileSync(process.env.GITHUB_OUTPUT, `issue_number=${issue.number}\n`);
        fs.appendFileSync(process.env.GITHUB_OUTPUT, `issue_url=${issue.html_url}\n`);
      }
    } catch (error) {
      console.error("Failed to create issue:", error.message);
      process.exit(1);
    }
  }
}

main();
