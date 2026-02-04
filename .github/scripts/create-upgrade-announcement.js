#!/usr/bin/env node
/**
 * Create FWSS Contract Upgrade Release Issue
 *
 * Generates a release issue that combines user-facing upgrade information
 * with a release engineer checklist (similar to Lotus release issues).
 *
 * See help text below for more info.
 */

const https = require("https");

// Parse command line arguments
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
  UPGRADE_TYPE         Type of upgrade (Routine or Breaking Change)
  AFTER_EPOCH          Block number after which upgrade can execute
  CHANGELOG_PR         PR number with changelog updates
  CHANGES_SUMMARY      Summary of changes (use | for multiple lines)
  ACTION_REQUIRED      Action required for integrators (default: None)
  UPGRADE_REGISTRY     Also upgrading ServiceProviderRegistry? (true/false, default: false, rare)
  UPGRADE_STATE_VIEW   Also redeploying StateView? (true/false, default: false, rare)
  RELEASE_TAG          Release tag (optional, usually added after upgrade completes)
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

// Build the list of contracts being upgraded (FWSS is always included)
function buildContractsList() {
  const contracts = ["FilecoinWarmStorageService"];

  if (config.upgradeRegistry) {
    contracts.push("ServiceProviderRegistry");
  }
  if (config.upgradeStateView) {
    contracts.push("FilecoinWarmStorageServiceStateView");
  }

  return contracts;
}

// Generate issue title
function generateTitle() {
  return `[Release] FWSS ${config.network} Upgrade - Epoch ${config.afterEpoch}`;
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
  const isMainnet = config.network === "Mainnet";
  const isBreaking = config.upgradeType === "Breaking Change";

  // Build contracts checklist for the release checklist section
  const deployChecklist = contracts
    .map((c) => {
      if (c === "FilecoinWarmStorageService") {
        return "- [ ] Deploy FWSS implementation: `./warm-storage-deploy-implementation.sh`";
      } else if (c === "ServiceProviderRegistry") {
        return "- [ ] Deploy Registry implementation: `./service-provider-registry-deploy.sh`";
      } else if (c === "FilecoinWarmStorageServiceStateView") {
        return "- [ ] Deploy StateView: `./warm-storage-deploy-view.sh`";
      }
      return `- [ ] Deploy ${c}`;
    })
    .join("\n");

  const announceChecklist = contracts
    .map((c) => {
      if (c === "FilecoinWarmStorageService") {
        return "- [ ] Announce FWSS upgrade: `./warm-storage-announce-upgrade.sh`";
      } else if (c === "ServiceProviderRegistry") {
        return "- [ ] Announce Registry upgrade: `./service-provider-registry-announce-upgrade.sh`";
      }
      return null;
    })
    .filter(Boolean)
    .join("\n");

  const executeChecklist = contracts
    .map((c) => {
      if (c === "FilecoinWarmStorageService") {
        return "- [ ] Execute FWSS upgrade: `./warm-storage-execute-upgrade.sh`";
      } else if (c === "ServiceProviderRegistry") {
        return "- [ ] Execute Registry upgrade: `./service-provider-registry-execute-upgrade.sh`";
      }
      return null;
    })
    .filter(Boolean)
    .join("\n");

  return `## Overview

| Field | Value |
|-------|-------|
| **Network** | ${config.network} |
| **Upgrade Type** | ${config.upgradeType} |
| **Target Epoch** | ${config.afterEpoch} |
| **Estimated Execution** | ${timeEstimate} |
| **Changelog PR** | ${changelogPrLink} |
${releaseLink ? `| **Release** | ${releaseLink} |` : ""}

### Contracts in Scope
${contracts.map((c) => `- ${c}`).join("\n")}

### Changes
${changes}

### Action Required for Integrators
${config.actionRequired}

---

## Release Checklist

> Full process details: [UPGRADE-PROCESS.md](${upgradeProcessLink})

### Phase 1: Prepare
- [ ] Changelog entry prepared in [CHANGELOG.md](${changelogLink})
- [ ] Version string updated in contracts (if applicable)
- [ ] Upgrade PR created: #${config.changelogPr}
${isBreaking ? "- [ ] Migration guide prepared for breaking changes" : ""}

### Phase 2: Calibnet Rehearsal
${isMainnet ? `<details>
<summary>Calibnet steps (expand)</summary>

` : ""}**Deploy Implementation**
${deployChecklist}
- [ ] Commit updated \`deployments.json\`

**Announce Upgrade**
${announceChecklist}

**Execute Upgrade**
${executeChecklist}
- [ ] Verify on Blockscout
${isMainnet ? `
</details>
` : ""}
${
  isMainnet
    ? `### Phase 3: Mainnet Deployment
${deployChecklist}
- [ ] Commit updated \`deployments.json\`

### Phase 4: Announce Mainnet Upgrade
${announceChecklist}
- [ ] Notify stakeholders (post in relevant channels)

### Phase 5: Execute Mainnet Upgrade
> ⏳ Wait until after epoch ${config.afterEpoch}

${executeChecklist}
- [ ] Verify on Blockscout
`
    : ""
}
### Phase ${isMainnet ? "6" : "3"}: Verify and Release
- [ ] Verify upgrade on Blockscout
- [ ] Confirm \`deployments.json\` is up to date
- [ ] Merge changelog PR: #${config.changelogPr}
- [ ] Tag release: \`git tag vX.Y.Z && git push origin vX.Y.Z\`
- [ ] Create GitHub Release with changelog
- [ ] Merge auto-generated PRs in [filecoin-cloud](https://github.com/FilOzone/filecoin-cloud/pulls) so docs.filecoin.cloud and filecoin.cloud reflect new contract versions
- [ ] Create "Upgrade Synapse to use newest contracts" issue
- [ ] Update this issue with release link
- [ ] Close this issue

---

### Resources
- [Changelog](${changelogLink})
- [Upgrade Process Documentation](${upgradeProcessLink})
${releaseLink ? `- [Release](${releaseLink})` : ""}

### Deployed Addresses
<!-- Update after deployments -->
| Contract | Network | Address |
|----------|---------|---------|
| | | |`;
}

// Generate labels for the issue
function generateLabels() {
  const labels = ["release"];
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
