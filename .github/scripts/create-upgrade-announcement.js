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
  RELEASE_VERSION      FWSS release version for the issue title (default: vX.Y.Z)
  UPGRADE_TYPE         Type of upgrade (Routine or Breaking Change)
  CHANGES_SUMMARY      Summary of changes (use | for multiple lines, optional at issue creation)
  ACTION_REQUIRED      Action required for integrators (optional, default: TBD)
  UPGRADE_REGISTRY     Also upgrading ServiceProviderRegistry? (true/false, default: false, rare)
  UPGRADE_STATE_VIEW   Also redeploying StateView? (true/false, default: false, rare)
  GITHUB_TOKEN         GitHub token (required when not using --dry-run)
  GITHUB_REPOSITORY    Repository in format owner/repo (required when not using --dry-run)

Example:
  NETWORK=Calibnet UPGRADE_TYPE=Routine CHANGES_SUMMARY="Fix bug|Add feature" \\
  node create-upgrade-announcement.js --dry-run
`);
  process.exit(0);
}

// Get configuration from environment
const config = {
  network: process.env.NETWORK,
  releaseVersion: (process.env.RELEASE_VERSION || "vX.Y.Z").trim(),
  upgradeType: process.env.UPGRADE_TYPE,
  changesSummary: (process.env.CHANGES_SUMMARY || "").trim(),
  actionRequired: (process.env.ACTION_REQUIRED || "TBD").trim(),
  upgradeRegistry: process.env.UPGRADE_REGISTRY === "true",
  upgradeStateView: process.env.UPGRADE_STATE_VIEW === "true",
  githubToken: process.env.GITHUB_TOKEN,
  githubRepository: process.env.GITHUB_REPOSITORY,
};

// Validate required fields
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

// Format changes summary from pipe-separated to bullet points
function formatChanges(changesSummary) {
  if (!changesSummary) {
    return "- TBD";
  }
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
  const mainnetSuffix = config.network === "Mainnet" ? " (includes Calibnet)" : "";
  return `[Release] FWSS ${config.releaseVersion} ${config.network} Upgrade${mainnetSuffix}`;
}

// Generate issue body
function generateBody() {
  const [owner, repo] = (config.githubRepository || "OWNER/REPO").split("/");
  const baseUrl = `https://github.com/${owner}/${repo}`;

  const changelogLink = `${baseUrl}/blob/main/CHANGELOG.md`;
  const fwssContractLink = `${baseUrl}/blob/main/service_contracts/src/FilecoinWarmStorageService.sol`;
  const upgradeProcessLink = `${baseUrl}/blob/main/service_contracts/tools/UPGRADE-PROCESS.md`;
  const deployWorkflowLink = `${baseUrl}/actions/workflows/deploy-contract.yml`;
  const fwssCalibnetProxy = "0x02925630df557F957f70E112bA06e50965417CA0";
  const fwssMainnetProxy = "0x8408502033C418E1bbC97cE9ac48E5528F371A9f";

  const changes = formatChanges(config.changesSummary);
  const recommendedPrTitle = `feat: FWSS ${config.releaseVersion} upgrade`;
  const mainnetWaitLine = "> ⏳ Set AFTER_EPOCH after deployments, then execute mainnet upgrade";
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
| **Version** | ${config.releaseVersion} |
| **Network** | ${config.network} |
| **Upgrade Type** | ${config.upgradeType} |
| **Target Epoch** | TBD (set after deployment) |
| **Changelog PR** | TBD (set after PR is opened) |

### Contracts in Scope
${contracts.map((c) => `- ${c}`).join("\n")}

### Changes
${changes}

### Action Required for Integrators
${config.actionRequired || "TBD"}

---

## Release Checklist

> Full process details: [UPGRADE-PROCESS.md](${upgradeProcessLink})

### Phase 1: Branch, PR, and Checks
- [ ] All intended contract changes are merged into \`main\`
- [ ] Create release branch from \`main\`, called \`release-vX.Y.Z\`
- [ ] Changelog entry prepared in [CHANGELOG.md](${changelogLink})
- [ ] Version string updated in [FilecoinWarmStorageService.sol](${fwssContractLink})
- [ ] Upgrade PR created (update this issue with PR number)
- [ ] Upgrade PR title uses \`${recommendedPrTitle}\`
- [ ] Upgrade checks run (tests + storage layout checks)
- [ ] Update this issue placeholders as values become known (\`AFTER_EPOCH\`, PR number, summary, action required)
${isBreaking ? "- [ ] Migration guide prepared for breaking changes" : ""}

### Phase 2: Deploy Implementations
Deploy to both networks before any announce/execute.

**Calibnet**
- [ ] Run [Deploy Contract workflow](${deployWorkflowLink}) with \`network=Calibnet\`, \`contract=FWSS Implementation\`, \`dry_run=true\`
- [ ] Re-run with \`dry_run=false\`
${deployChecklist}
- [ ] Capture Calibnet implementation address(es)

**Mainnet**
- [ ] Run [Deploy Contract workflow](${deployWorkflowLink}) with \`network=Mainnet\`, \`contract=FWSS Implementation\`, \`dry_run=true\`
- [ ] Re-run with \`dry_run=false\`
${isMainnet ? `${deployChecklist}
- [ ] Capture Mainnet implementation address(es)` : "- [ ] Skip for Calibnet-only release"}

### Phase 3: Calibnet Announce + Execute
**Announce**
${announceChecklist}
- [ ] Generate calldata with \`CALLDATA_ONLY=true\` and submit/sign/execute in Safe UI (Transaction Builder, value=\`0\`)

\`\`\`bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="${fwssCalibnetProxy}"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"
export AFTER_EPOCH="TBD"
CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
\`\`\`

**Execute**
${executeChecklist}
- [ ] Wait for \`AFTER_EPOCH\`, then generate calldata with \`CALLDATA_ONLY=true\` and submit/sign/execute in Safe UI

\`\`\`bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="${fwssCalibnetProxy}"
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="$CALI_NEW_IMPL"
CALLDATA_ONLY=true ./warm-storage-execute-upgrade.sh
\`\`\`

- [ ] Verify on Blockscout

${
  isMainnet
    ? `### Phase 4: Mainnet Announce + Execute
**Announce**
${announceChecklist}
- [ ] Notify stakeholders (post in relevant channels)
- [ ] Generate calldata with \`CALLDATA_ONLY=true\` and submit/sign/execute in Safe UI

\`\`\`bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="${fwssMainnetProxy}"
export NEW_FWSS_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"
export AFTER_EPOCH="TBD"
CALLDATA_ONLY=true ./warm-storage-announce-upgrade.sh
\`\`\`

**Execute**
${mainnetWaitLine}

${executeChecklist}
- [ ] Generate calldata with \`CALLDATA_ONLY=true\` and submit/sign/execute in Safe UI

\`\`\`bash
cd service_contracts/tools
export ETH_RPC_URL="https://api.node.glif.io/rpc/v1"
export FWSS_PROXY_ADDRESS="${fwssMainnetProxy}"
export NEW_WARM_STORAGE_IMPLEMENTATION_ADDRESS="$MAIN_NEW_IMPL"
CALLDATA_ONLY=true ./warm-storage-execute-upgrade.sh
\`\`\`

- [ ] Verify on Blockscout
`
    : ""
}
### Phase ${isMainnet ? "5" : "4"}: Merge and Release
- [ ] Merge changelog/upgrade PR
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
