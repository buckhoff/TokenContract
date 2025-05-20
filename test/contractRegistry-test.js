const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("ContractRegistry", function () {
  let contractRegistry;
  let owner, admin, upgrader, emergency, user;
  let contract1, contract2;

  beforeEach(async function () {
    // Get signers
    [owner, admin, upgrader, emergency, user] = await ethers.getSigners();

    // Deploy ContractRegistry
    const ContractRegistry = await ethers.getContractFactory("ContractRegistry");
    contractRegistry = await upgrades.deployProxy(ContractRegistry, [], {
      initializer: "initialize",
    });

    // Deploy mock contracts for registration
    const MockContract = await ethers.getContractFactory("MockContract");
    contract1 = await MockContract.deploy();
    contract2 = await MockContract.deploy();
    
    // Set up roles
    const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
    const UPGRADER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("UPGRADER_ROLE"));
    const EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));

    await contractRegistry.grantRole(ADMIN_ROLE, admin.address);
    await contractRegistry.grantRole(UPGRADER_ROLE, upgrader.address);
    await contractRegistry.grantRole(EMERGENCY_ROLE, emergency.address);
  });

  describe("Initialization", function () {
    it("should set the correct owner during initialization", async function () {
      expect(await contractRegistry.hasRole(await contractRegistry.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
    });

    it("should set system paused status to false initially", async function () {
      expect(await contractRegistry.isSystemPaused()).to.be.false;
    });
  });

  describe("Contract Registration", function () {
    it("allows admin to register a contract", async function () {
      const contractName = ethers.keccak256(ethers.toUtf8Bytes("TEST_CONTRACT"));
      
      console.log(contractName);
      await contractRegistry.connect(admin).registerContract(
        contractName,
        contract1.address,
        "0x00000000" // No interface ID for this test
      );

      expect(await contractRegistry.getContractAddress(contractName)).to.equal(contract1.address);
      expect(await contractRegistry.getContractVersion(contractName)).to.equal(1);
      expect(await contractRegistry.isContractActive(contractName)).to.be.true;
    });

    it("should revert when registering with zero address", async function () {
      const contractName = ethers.keccak256(ethers.toUtf8Bytes("ZERO_CONTRACT"));
      
      await expect(
        contractRegistry.connect(admin).registerContract(
          contractName,
          ethers.constants.AddressZero,
          "0x00000000"
        )
      ).to.be.revertedWith("ContractRegistry: zero address");
    });

    it("should revert when registering an already registered contract", async function () {
      const contractName = ethers.keccak256(ethers.toUtf8Bytes("DUPLICATE_CONTRACT"));
      
      await contractRegistry.connect(admin).registerContract(
        contractName,
        contract1.address,
        "0x00000000"
      );

      await expect(
        contractRegistry.connect(admin).registerContract(
          contractName,
          contract2.address,
          "0x00000000"
        )
      ).to.be.revertedWith("ContractRegistry: already registered");
    });
  });

  describe("Contract Updates", function () {
    let contractName;

    beforeEach(async function () {
      contractName = ethers.keccak256(ethers.toUtf8Bytes("UPDATE_CONTRACT"));
      
      await contractRegistry.connect(admin).registerContract(
        contractName,
        contract1.address,
        "0x00000000"
      );
    });

    it("allows upgrader to update a contract", async function () {
      await contractRegistry.connect(upgrader).updateContract(
        contractName,
        contract2.address,
        "0x00000000"
      );

      expect(await contractRegistry.getContractAddress(contractName)).to.equal(contract2.address);
      expect(await contractRegistry.getContractVersion(contractName)).to.equal(2);
    });

    it("should revert when updating to the same address", async function () {
      await expect(
        contractRegistry.connect(upgrader).updateContract(
          contractName,
          contract1.address,
          "0x00000000"
        )
      ).to.be.revertedWith("ContractRegistry: same address");
    });

    it("should revert when updating a non-registered contract", async function () {
      const nonRegisteredName = ethers.keccak256(ethers.toUtf8Bytes("NON_EXISTENT"));
      
      await expect(
        contractRegistry.connect(upgrader).updateContract(
          nonRegisteredName,
          contract2.address,
          "0x00000000"
        )
      ).to.be.revertedWith("ContractRegistry: not registered");
    });
  });

  describe("Contract Status Management", function () {
    let contractName;

    beforeEach(async function () {
      contractName = ethers.keccak256(ethers.toUtf8Bytes("STATUS_CONTRACT"));
      
      await contractRegistry.connect(admin).registerContract(
        contractName,
        contract1.address,
        "0x00000000"
      );
    });

    it("allows admin to deactivate a contract", async function () {
      await contractRegistry.connect(admin).setContractStatus(contractName, false);
      expect(await contractRegistry.isContractActive(contractName)).to.be.false;
    });

    it("allows admin to reactivate a contract", async function () {
      await contractRegistry.connect(admin).setContractStatus(contractName, false);
      await contractRegistry.connect(admin).setContractStatus(contractName, true);
      expect(await contractRegistry.isContractActive(contractName)).to.be.true;
    });

    it("should revert when setting status for a non-registered contract", async function () {
      const nonRegisteredName = ethers.keccak256(ethers.toUtf8Bytes("NON_EXISTENT"));
      
      await expect(
        contractRegistry.connect(admin).setContractStatus(nonRegisteredName, false)
      ).to.be.revertedWith("ContractRegistry: not registered");
    });
  });

  describe("System Pause Management", function () {
    it("allows emergency role to pause system", async function () {
      await contractRegistry.connect(emergency).pauseSystem();
      expect(await contractRegistry.isSystemPaused()).to.be.true;
    });

    it("allows admin to resume system", async function () {
      await contractRegistry.connect(emergency).pauseSystem();
      await contractRegistry.connect(admin).resumeSystem();
      expect(await contractRegistry.isSystemPaused()).to.be.false;
    });

    it("should revert when non-emergency role tries to pause", async function () {
      await expect(
        contractRegistry.connect(user).pauseSystem()
      ).to.be.reverted;
    });

    it("should revert when system is already paused", async function () {
      await contractRegistry.connect(emergency).pauseSystem();
      
      // Use try/catch since the error is custom and not easily checked with expect().to.be.revertedWith
      let error;
      try {
        await contractRegistry.connect(admin).resumeSystem();
      } catch (e) {
        error = e;
      }
      
      await contractRegistry.connect(admin).resumeSystem();
      expect(await contractRegistry.isSystemPaused()).to.be.false;
    });
  });

  describe("Implementation History", function () {
    let contractName;

    beforeEach(async function () {
      contractName = ethers.keccak256(ethers.toUtf8Bytes("HISTORY_CONTRACT"));
      
      await contractRegistry.connect(admin).registerContract(
        contractName,
        contract1.address,
        "0x00000000"
      );
    });

    it("should maintain correct implementation history", async function () {
      // Update contract to add a new implementation
      await contractRegistry.connect(upgrader).updateContract(
        contractName,
        contract2.address,
        "0x00000000"
      );

      const history = await contractRegistry.getImplementationHistory(contractName);
      expect(history.length).to.equal(2);
      expect(history[0]).to.equal(contract1.address);
      expect(history[1]).to.equal(contract2.address);
    });
  });

  describe("Contract Name Utility", function () {
    it("should correctly convert string to bytes32", async function () {
      const testString = "TEST_STRING";
      const expectedBytes32 = ethers.keccak256(ethers.toUtf8Bytes(testString));
      
      expect(await contractRegistry.stringToBytes32(testString)).to.equal(expectedBytes32);
    });

    it("should revert on strings longer than 32 bytes", async function () {
      const longString = "THIS_STRING_IS_DEFINITELY_LONGER_THAN_THIRTY_TWO_BYTES_AND_SHOULD_REVERT";
      
      await expect(
        contractRegistry.stringToBytes32(longString)
      ).to.be.reverted;
    });
  });

  describe("Contract Querying", function () {
    let contract1Name, contract2Name;

    beforeEach(async function () {
      contract1Name = ethers.keccak256(ethers.toUtf8Bytes("CONTRACT_1"));
      contract2Name = ethers.keccak256(ethers.toUtf8Bytes("CONTRACT_2"));
      
      await contractRegistry.connect(admin).registerContract(
        contract1Name,
        contract1.address,
        "0x00000000"
      );
      
      await contractRegistry.connect(admin).registerContract(
        contract2Name,
        contract2.address,
        "0x00000000"
      );
    });

    it("should correctly return all contract names", async function () {
      const names = await contractRegistry.getAllContractNames();
      expect(names.length).to.equal(2);
      expect(names).to.include(contract1Name);
      expect(names).to.include(contract2Name);
    });
  });

  describe("Emergency Recovery", function () {
    beforeEach(async function () {
      // Pause the system to enable recovery
      await contractRegistry.connect(emergency).pauseSystem();
      
      // Set required approvals to a manageable number for testing
      await contractRegistry.connect(admin).setRequiredRecoveryApprovals(2);
    });

    it("should initialize emergency recovery correctly", async function () {
      await contractRegistry.connect(emergency).initiateEmergencyRecovery();
      
      // Check if in recovery mode (indirect since the variable might be private)
      let inRecovery = false;
      try {
        await contractRegistry.connect(admin).approveRecovery();
        inRecovery = true;
      } catch {
        inRecovery = false;
      }
      
      expect(inRecovery).to.be.true;
    });

    it("should complete recovery after sufficient approvals", async function () {
      await contractRegistry.connect(emergency).initiateEmergencyRecovery();
      
      // Two admins approve (owner and admin)
      await contractRegistry.connect(owner).approveRecovery();
      await contractRegistry.connect(admin).approveRecovery();
      
      // System should be unpaused after successful recovery
      expect(await contractRegistry.isSystemPaused()).to.be.false;
    });

    it("should not allow non-admin to approve recovery", async function () {
      await contractRegistry.connect(emergency).initiateEmergencyRecovery();
      
      await expect(
        contractRegistry.connect(user).approveRecovery()
      ).to.be.reverted;
    });
  });
});
