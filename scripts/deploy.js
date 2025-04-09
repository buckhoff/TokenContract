async function main() {
    const TeachToken = await ethers.getContractFactory("TeachToken");
    console.log("Deploying TeachToken...");
    const teachToken = await TeachToken.deploy();
    await teachToken.deployed();
    console.log("TeachToken deployed to:", teachToken.address);
  }
  
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });