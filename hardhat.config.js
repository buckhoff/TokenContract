require("@nomicfoundation/hardhat-chai-matchers");
require("@nomicfoundation/hardhat-ethers");
require("@openzeppelin/hardhat-upgrades");
require("dotenv").config();

module.exports = {
  solidity: {
    version: "0.8.29",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    //amoy: {
     // url: process.env.AMOY_RPC_URL || "https://rpc.amoy.network/",
    //  accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    //  chainId: 80002,
    //},
    hardhat: {
      localhost: {
        url: "http://127.0.0.1:8545/"
      }
    }
  },
  // For contract verification
  etherscan: {
    apiKey: {
      amoy: process.env.ETHERSCAN_API_KEY || "",
    },
    customChains: [
      {
        network: "amoy",
        chainId: 80002,
        urls: {
          apiURL: "https://api-amoy.etherscan.io/api",
          browserURL: "https://amoy.etherscan.io",
        },
      },
    ],
  },
  // To avoid timeout issues with complex contracts
  mocha: {
    timeout: 100000,
  },
};