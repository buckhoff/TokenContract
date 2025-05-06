        // sequential-deploy.js - Run deployments in sequence with pauses to update .env
        const { spawn, execSync } = require('child_process');
        const readline = require('readline');
        const fs = require('fs');
        const path = require('path');
        const dotenv = require('dotenv');

        // Gas tracking configuration
        const TRACK_GAS_USAGE = true;  // Set to false to disable gas tracking
        const GAS_PRICE_GWEI = 30;     // Average gas price on Polygon in Gwei
        const MATIC_PRICE_USD = 0.228;  // Current MATIC price in USD
        
        // Create readline interface for user prompts
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout
        });

        // Load environment variables
        dotenv.config();

        // Define deployment sequence 
        const deploymentSequence = [
            {
                name: "ContractRegistry",
                script: "scripts/deploy-registry.js",
                envVars: ["REGISTRY_ADDRESS"],
                gasUsed: 0  // Will be populated during deployment
            },
            {
                name: "TeachToken",
                script: "scripts/deploy-teach-token.js",
                envVars: ["TOKEN_ADDRESS"],
                gasUsed: 0 // Will be populated during deployment
            },
            {
                name: "RegisterTeachToken",
                script: "scripts/register-token.js",
                envVars: [""],
                gasUsed: 0 // Will be populated during deployment
            },
            {
                name: "TestStableCoin",
                script: "scripts/test-deploy-stablecoin.js",
                envVars: ["STABLE_COIN_ADDRESS"],
                gasUsed: 0  // Will be populated during deployment
            },
            {
                name: "PlatformStabilityFund",
                script: "scripts/deploy-stability-fund.js",
                envVars: ["STABILITY_FUND_ADDRESS"],
                gasUsed: 0  // Will be populated during deployment
            },
            {
                name: "TokenStaking",
                script: "scripts/deploy-token-staking.js",
                envVars: ["TOKEN_STAKING_ADDRESS"],
                gasUsed: 0  // Will be populated during deployment
            },
            {
                name: "TeachTokenVesting",
                script: "scripts/deploy-token-vesting.js",
                envVars: ["TOKEN_VESTING_ADDRESS"],
                gasUsed: 0  // Will be populated during deployment
            },
            {
                name: "PlatformGovernance",
                script: "scripts/deploy-governance.js",
                envVars: ["PLATFORM_GOVERNANCE_ADDRESS"],
                gasUsed: 0  // Will be populated during deployment
            },
            {
                name: "PlatformMarketplace",
                script: "scripts/deploy-marketplace.js",
                envVars: ["PLATFORM_MARKETPLACE_ADDRESS"],
                gasUsed: 0  // Will be populated during deployment
            },
            {
                name: "TeacherReward",
                script: "scripts/deploy-teacher-reward.js",
                envVars: ["TEACHER_REWARD_ADDRESS"],
                gasUsed: 0  // Will be populated during deployment
            },
            {
                name: "TokenCrowdSale",
                script: "scripts/deploy-crowdsale.js",
                envVars: ["TOKEN_CROWDSALE_ADDRESS"],
                gasUsed: 0  // Will be populated during deployment
            }
        ];

        // Helper function to update .env file
        function updateEnvFile(key, value) {
            try {
                let envContent = fs.readFileSync('.env', 'utf8');

                // Check if key already exists
                const regex = new RegExp(`^${key}=.*`, 'm');
                if (regex.test(envContent)) {
                    // Replace existing value
                    envContent = envContent.replace(regex, `${key}=${value}`);
                } else {
                    // Add new key-value pair
                    envContent += `\n${key}=${value}`;
                }

                fs.writeFileSync('.env', envContent);
                console.log(`\x1b[32m✓ Updated .env with ${key}=${value}\x1b[0m`);
            } catch (error) {
                console.error(`\x1b[31mError updating .env file: ${error.message}\x1b[0m`);
            }
        }

        // Function to extract addresses from deployment output
        function extractAddressFromOutput(output, contractName) {
            const regex = new RegExp(`${contractName} deployed to:\\s*([0-9a-fA-Fx]+)`, 'i');
            const match = output.match(regex);
            return match ? match[1] : null;
        }

        // Function to extract gas usage from output
        function extractGasUsedFromOutput(output) {
            // Look for gas usage patterns in the output
            const regexes = [
                /Gas used:\s*([\d,]+)/i,
                /gas used:\s*([\d,]+)/i,
                /gasUsed:\s*([\d,]+)/i,
                /Gas Usage:\s*([\d,]+)/i
            ];

            for (const regex of regexes) {
                const match = output.match(regex);
                if (match) {
                    // Remove commas and convert to number
                    return parseInt(match[1].replace(/,/g, ''));
                }
            }

            // If no direct gas usage is found, look for transaction hash and estimate
            const txHashMatch = output.match(/Transaction hash:\s*([0-9a-fA-Fx]+)/i);
            if (txHashMatch) {
                return 5000000; // Fallback average gas estimate when exact value not found
            }

            return 0; // No gas info found
        }

        // Function to calculate gas cost in MATIC and USD
        function calculateGasCost(gasUsed) {
            const gasCostInMatic = (gasUsed * GAS_PRICE_GWEI) / 1e9;
            const gasCostInUSD = gasCostInMatic * MATIC_PRICE_USD;

            return {
                gas: gasUsed,
                matic: gasCostInMatic.toFixed(6),
                usd: gasCostInUSD.toFixed(2)
            };
        }

        // Function to run a single deployment script
        async function runDeployment(deployment, network = "localhost") {
            return new Promise((resolve) => {
                console.log(`\n\x1b[34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\x1b[0m`);
                console.log(`\x1b[1m🚀 Deploying ${deployment.name}...\x1b[0m`);
                console.log(`\x1b[34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\x1b[0m`);

                try {
                    // Use execSync instead of spawn
                    const command = `npx hardhat run ${deployment.script} --network ${network}`;
                    console.log(`Executing: ${command}`);

                    const output = execSync(command, {
                        encoding: 'utf8',
                        stdio: ['inherit', 'pipe', 'inherit'] // Show stdout in console and capture it
                    });

                    console.log(output);
                    console.log(`\x1b[32m✓ ${deployment.name} deployment completed successfully!\x1b[0m`);

                    // Extract contract address from output
                    const address = extractAddressFromOutput(output, deployment.name);

                    if (address && deployment.envVars && deployment.envVars.length > 0) {
                        const envKey = deployment.envVars[0];
                        updateEnvFile(envKey, address);
                    }

                    // Track gas usage if enabled
                    if (TRACK_GAS_USAGE) {
                        const gasUsed = extractGasUsedFromOutput(output);
                        deployment.gasUsed = gasUsed;

                        if (gasUsed > 0) {
                            const cost = calculateGasCost(gasUsed);
                            console.log(`\x1b[33m📊 Gas used: ${gasUsed.toLocaleString()} (${cost.matic} MATIC / ${cost.usd} USD)\x1b[0m`);
                        }
                    }

                    resolve({ success: true, output });
                } catch (error) {
                    console.error(`\x1b[31m✗ ${deployment.name} deployment failed: ${error.message}\x1b[0m`);
                    resolve({ success: false, output: error.message });
                }
            });
        }

        // Main function to run deployments in sequence
        async function runSequentialDeployments() {
            console.log('\x1b[1m\n📋 Sequential Deployment Process\x1b[0m');
            console.log('This script will run the deployment scripts in sequence,');
            console.log('pausing after each to allow you to update your .env file if needed.\n');

            if (TRACK_GAS_USAGE) {
                console.log('\x1b[33m💰 Gas tracking is enabled:\x1b[0m');
                console.log(`   - Gas Price: ${GAS_PRICE_GWEI} Gwei`);
                console.log(`   - MATIC Price: ${MATIC_PRICE_USD}`);
                console.log('   - Gas costs will be estimated for Polygon network\n');
            }

            // Ask which network to use
            const network = await new Promise((resolve) => {
                rl.question('Which network do you want to deploy to? [localhost]: ', (answer) => {
                    resolve(answer || 'localhost');
                });
            });

            // If using Polygon, ask if gas price should be updated
            if (TRACK_GAS_USAGE && (network === 'polygon' || network === 'mumbai')) {
                const updateGasPrice = await new Promise((resolve) => {
                    rl.question(`Update gas price from ${GAS_PRICE_GWEI} Gwei? (y/n) [n]: `, (ans) => {
                        resolve(ans.toLowerCase() === 'y');
                    });
                });

                if (updateGasPrice) {
                    // Update the global gas price
                    global.GAS_PRICE_GWEI = await new Promise((resolve) => {
                        rl.question('Enter new gas price in Gwei: ', (ans) => {
                            const price = parseFloat(ans);
                            resolve(isNaN(price) ? GAS_PRICE_GWEI : price);
                        });
                    });
                }
            }

            // Ask if user wants to start from a specific deployment
            const startFrom = await new Promise((resolve) => {
                const names = deploymentSequence.map((d, i) => `${i+1}. ${d.name}`).join('\n  ');
                rl.question(`\nStart from which deployment? (1-${deploymentSequence.length})\n  ${names}\n> `, (answer) => {
                    const num = parseInt(answer);
                    if (isNaN(num) || num < 1 || num > deploymentSequence.length) {
                        resolve(1); // Default to first deployment
                    } else {
                        resolve(num);
                    }
                });
            });

            if (startFrom === 1) {
                const clearEnv = await new Promise((resolve) => {
                    rl.question('Do you want to clear existing deployment addresses from .env? (y/n) [n]: ', (ans) => {
                        resolve(ans.toLowerCase() === 'y');
                    });
                });

                if (clearEnv) {
                    await clearEnvDeploymentAddresses();
                }
            }
            
            // Run deployments
            for (let i = startFrom - 1; i < deploymentSequence.length; i++) {
                const deployment = deploymentSequence[i];

                // Run current deployment
                const result = await runDeployment(deployment, network);

                if (!result.success) {
                    const answer = await new Promise((resolve) => {
                        rl.question('\n\x1b[31mDeployment failed. Continue with next deployment? (y/n) [n]: \x1b[0m', (ans) => {
                            resolve(ans.toLowerCase());
                        });
                    });

                    if (answer !== 'y') {
                        console.log('\x1b[31mDeployment sequence aborted.\x1b[0m');
                        break;
                    }
                }

                // Ask if user wants to continue with next deployment
                if (i < deploymentSequence.length - 1) {
                    const answer = await new Promise((resolve) => {
                        rl.question('\nDo you want to continue with the next deployment? (y/n) [y]: ', (ans) => {
                            const input = ans.toLowerCase();
                            resolve(input === '' || input === 'y');
                        });
                    });

                    if (!answer) {
                        console.log('\x1b[33mDeployment sequence paused. Run the script again to continue.\x1b[0m');
                        break;
                    }
                }
            }

            rl.close();
            console.log('\n\x1b[32mDeployment sequence completed!\x1b[0m');

            return network; // Return the network for the gas report
        }

        // Function to display total gas costs at the end
        function displayTotalGasCosts() {
            if (!TRACK_GAS_USAGE) return;

            let totalGas = 0;
            let successfulDeployments = 0;

            console.log('\n\x1b[34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\x1b[0m');
            console.log('\x1b[1m💰 Gas Usage Summary\x1b[0m');
            console.log('\x1b[34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\x1b[0m');

            console.log('\x1b[1m Contract                Gas Used       Cost (MATIC)     Cost (USD)\x1b[0m');
            console.log('─────────────────────────────────────────────────────────────');

            deploymentSequence.forEach(deployment => {
                if (deployment.gasUsed > 0) {
                    const cost = calculateGasCost(deployment.gasUsed);
                    console.log(
                        ` ${deployment.name.padEnd(22)} ${deployment.gasUsed.toLocaleString().padStart(12)} ` +
                        `     ${cost.matic.padStart(8)} MATIC     ${cost.usd.padStart(5)}`
                    );

                    totalGas += deployment.gasUsed;
                    successfulDeployments++;
                }
            });

            if (successfulDeployments > 0) {
                const totalCost = calculateGasCost(totalGas);
                console.log('─────────────────────────────────────────────────────────────');
                console.log(
                    ` \x1b[1mTOTAL\x1b[0m                  ${totalGas.toLocaleString().padStart(12)} ` +
                    `     ${totalCost.matic.padStart(8)} MATIC     ${totalCost.usd.padStart(5)}`
                );

                // Add Polygon network context
                console.log('\n\x1b[90mNote: Gas costs estimated using:');
                console.log(`- Gas Price: ${GAS_PRICE_GWEI} Gwei`);
                console.log(`- MATIC Price: ${MATIC_PRICE_USD}`);
                console.log(`- Polygon network fees are approximately 1/100th of Ethereum fees\x1b[0m`);
            } else {
                console.log('\x1b[90mNo gas usage data collected.\x1b[0m');
            }
        }

        // Function to save gas costs to a file
        function saveGasCostsToFile(network) {
            if (!TRACK_GAS_USAGE) return;

            const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
            const filename = `deployment-gas-costs-${network}-${timestamp}.json`;

            const gasReport = {
                network,
                gasPrice: GAS_PRICE_GWEI,
                maticPrice: MATIC_PRICE_USD,
                timestamp: new Date().toISOString(),
                contracts: {},
                total: 0
            };

            let totalGas = 0;

            deploymentSequence.forEach(deployment => {
                if (deployment.gasUsed > 0) {
                    const cost = calculateGasCost(deployment.gasUsed);
                    gasReport.contracts[deployment.name] = {
                        gasUsed: deployment.gasUsed,
                        maticCost: parseFloat(cost.matic),
                        usdCost: parseFloat(cost.usd)
                    };
                    totalGas += deployment.gasUsed;
                }
            });

            if (totalGas > 0) {
                const totalCost = calculateGasCost(totalGas);
                gasReport.total = {
                    gasUsed: totalGas,
                    maticCost: parseFloat(totalCost.matic),
                    usdCost: parseFloat(totalCost.usd)
                };

                fs.writeFileSync(filename, JSON.stringify(gasReport, null, 2));
                console.log(`\n\x1b[32m✓ Gas cost report saved to ${filename}\x1b[0m`);
            }
        }

        /**
         * @dev Clears deployment addresses from .env file when starting from scratch
         */
        async function clearEnvDeploymentAddresses() {
            try {
                // Read the current .env file
                let envContent = '';
                try {
                    envContent = fs.readFileSync('.env', 'utf8');
                } catch (error) {
                    // If .env doesn't exist, create an empty one
                    fs.writeFileSync('.env', '');
                    return;
                }

                // List of contract address variables to clear
                const addressVars = [
                    'REGISTRY_ADDRESS',
                    'TOKEN_ADDRESS',
                    'STABLE_COIN_ADDRESS',
                    'STABILITY_FUND_ADDRESS',
                    'TOKEN_STAKING_ADDRESS',
                    'TOKEN_VESTING_ADDRESS',
                    'PLATFORM_GOVERNANCE_ADDRESS',
                    'PLATFORM_MARKETPLACE_ADDRESS',
                    'TEACHER_REWARD_ADDRESS',
                    'TOKEN_CROWDSALE_ADDRESS'
                ];

                // Create a new content without these variables
                const lines = envContent.split('\n');
                const filteredLines = lines.filter(line => {
                    const varName = line.split('=')[0];
                    return !addressVars.includes(varName);
                });

                // Write the filtered content back to .env
                fs.writeFileSync('.env', filteredLines.join('\n'));
                console.log('\x1b[33m✓ Cleared deployment addresses from .env file\x1b[0m');
            } catch (error) {
                console.error(`\x1b[31mError clearing .env file: ${error.message}\x1b[0m`);
            }
        }
        
        // Run the main function
        runSequentialDeployments()
            .then((network) => {
                // Display total gas costs at the end
                displayTotalGasCosts();
                // Save gas costs to a file with the network name
                saveGasCostsToFile(network);
            })
            .catch(console.error);