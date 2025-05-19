// scripts/update-deploy-sequence.js
const fs = require('fs');
const path = require('path');

// Path to the sequential-deploy.js file
const sequentialDeployPath = path.join(__dirname, 'sequential-deploy.js');

// New deployment entries to add
const newDeployments = [
    {
        name: "DexRegistry",
        script: "scripts/deploy-dex-registry.js",
        envVars: ["DEX_REGISTRY_ADDRESS"],
        gasUsed: 0
    },
    {
        name: "TokenPriceFeed",
        script: "scripts/deploy-token-price-feed.js",
        envVars: ["TOKEN_PRICE_FEED_ADDRESS"],
        gasUsed: 0
    },
    {
        name: "LiquidityProvisioner",
        script: "scripts/deploy-liquidity-provisioner.js",
        envVars: ["LIQUIDITY_PROVISIONER_ADDRESS"],
        gasUsed: 0
    },
    {
        name: "LiquidityRebalancer",
        script: "scripts/deploy-liquidity-rebalancer.js",
        envVars: ["LIQUIDITY_REBALANCER_ADDRESS"],
        gasUsed: 0
    },
    {
        name: "LiquidityManager",
        script: "scripts/deploy-liquidity-manager.js",
        envVars: ["LIQUIDITY_MANAGER_ADDRESS"],
        gasUsed: 0
    },
    {
        name: "TierManager",
        script: "scripts/deploy-tier-manager.js",
        envVars: ["TIER_MANAGER_ADDRESS"],
        gasUsed: 0
    },
    {
        name: "EmergencyManager",
        script: "scripts/deploy-emergency-manager.js",
        envVars: ["EMERGENCY_MANAGER_ADDRESS"],
        gasUsed: 0
    }
];

// Function to update the deployment sequence
function updateDeploymentSequence() {
    // Read the current file
    let content = fs.readFileSync(sequentialDeployPath, 'utf8');

    // Find the deploymentSequence array
    const sequenceRegex = /const deploymentSequence = \[([\s\S]*?)\];/;
    const match = content.match(sequenceRegex);

    if (!match) {
        console.error("Could not find deploymentSequence array in the file.");
        process.exit(1);
    }

    // Extract the current sequence
    const currentSequence = match[1];

    // Create new deployment entries string
    const newEntries = newDeployments.map(entry => {
        return `
    {
        name: "${entry.name}",
        script: "${entry.script}",
        envVars: ["${entry.envVars}"],
        gasUsed: 0  // Will be populated during deployment
    }`;
    }).join(',');

    // Append new entries to the end of the sequence
    const updatedSequence = currentSequence + ',' + newEntries;

    // Replace the old sequence with the updated one
    const updatedContent = content.replace(sequenceRegex, `const deploymentSequence = [${updatedSequence}];`);

    // Write back to the file
    fs.writeFileSync(sequentialDeployPath + '.updated', updatedContent);

    console.log("Updated deployment sequence written to sequential-deploy.js.updated");
    console.log("Please review the file and rename it to sequential-deploy.js if the changes are correct.");
}

// Run the update function
updateDeploymentSequence();