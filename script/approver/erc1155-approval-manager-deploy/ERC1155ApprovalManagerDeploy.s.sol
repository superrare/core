// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Script, console} from "forge-std/Script.sol";

import {ERC1155ApprovalManager} from "../../../src/v2/approver/ERC1155/ERC1155ApprovalManager.sol";

/// @title ERC1155ApprovalManagerDeploy
/// @notice Deploys ERC1155ApprovalManager and grants manager authority to the approval-manager and marketplace deployers.
/// @dev `APPROVAL_MANAGER_KEY` deploys the manager and receives DEFAULT_ADMIN_ROLE + MANAGER_ROLE in the constructor.
contract ERC1155ApprovalManagerDeploy is Script {
    function run() external {
        uint256 approvalManagerPrivateKey = vm.envUint("APPROVAL_MANAGER_KEY");
        uint256 marketplaceDeployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address approvalManagerDeployer = vm.addr(approvalManagerPrivateKey);
        address marketplaceDeployer = vm.addr(marketplaceDeployerPrivateKey);

        vm.startBroadcast(approvalManagerPrivateKey);

        ERC1155ApprovalManager manager = new ERC1155ApprovalManager();

        if (marketplaceDeployer != approvalManagerDeployer) {
            manager.grantRole(manager.MANAGER_ROLE(), marketplaceDeployer);
        }

        vm.stopBroadcast();

        bytes32 managerRole = manager.MANAGER_ROLE();
        bytes32 defaultAdminRole = manager.DEFAULT_ADMIN_ROLE();

        console.log("ERC1155ApprovalManager deployed at:", address(manager));
        console.log("Approval manager deployer:", approvalManagerDeployer);
        console.log("Marketplace deployer:", marketplaceDeployer);
        console.log("Approval manager deployer has DEFAULT_ADMIN_ROLE:", manager.hasRole(defaultAdminRole, approvalManagerDeployer));
        console.log("Approval manager deployer has MANAGER_ROLE:", manager.hasRole(managerRole, approvalManagerDeployer));
        console.log("Marketplace deployer has MANAGER_ROLE:", manager.hasRole(managerRole, marketplaceDeployer));
    }
}
