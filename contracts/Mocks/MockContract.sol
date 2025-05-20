// MockContract.sol - A simple mock contract for testing
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

contract MockContract {
    string public name = "MockContract";

    // Simple function to verify contract code exists
    function getVersion() public pure returns (string memory) {
        return "1.0.0";
    }

    // Function to check for interface support (ERC165-like)
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x00000000;
    }

    // Fallback to allow receiving ETH
    receive() external payable {}
}