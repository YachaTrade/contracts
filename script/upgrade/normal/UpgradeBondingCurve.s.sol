// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {BondingCurve} from "../../../src/core/BondingCurve.sol";

/// @title UpgradeBondingCurve - deploys a fresh BondingCurve implementation and
///                              upgrades the existing UUPS proxy.
/// @dev BondingCurve uses AccessControl (not Ownable), and `_authorizeUpgrade`
///      requires DEFAULT_ADMIN_ROLE. After deployment that role is held by the
///      multisig, so MULTISIG_PRIVATE_KEY is the only valid upgrade key.
///
///      Environment variables:
///        MULTISIG_PRIVATE_KEY - multisig key holding DEFAULT_ADMIN_ROLE on the proxy
///        V2_BONDING_CURVE     - address of the deployed UUPS proxy
///
///      Run:
///        source .env && forge script script/UpgradeBondingCurve.s.sol:UpgradeBondingCurve \
///            --rpc-url $RPC_URL --broadcast
contract UpgradeBondingCurve is Script {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        uint256 multisigKey = vm.envUint("MULTISIG_PRIVATE_KEY");
        address proxy = vm.envAddress("V2_BONDING_CURVE");

        address multisig = vm.addr(multisigKey);

        BondingCurve bc = BondingCurve(payable(proxy));
        require(bc.hasRole(bc.DEFAULT_ADMIN_ROLE(), multisig), "Upgrade: multisig missing DEFAULT_ADMIN_ROLE");

        address oldImpl = _readImpl(proxy);

        vm.startBroadcast(multisigKey);

        BondingCurve newImpl = new BondingCurve();
        UUPSUpgradeable(proxy).upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        address postImpl = _readImpl(proxy);
        require(postImpl == address(newImpl), "Upgrade: impl slot mismatch");

        _assertSelectorExists(proxy, BondingCurve.getAmountOut.selector);
        _assertSelectorExists(proxy, BondingCurve.getAmountIn.selector);

        console.log("========================================");
        console.log("BondingCurve upgraded");
        console.log("========================================");
        console.log("Proxy:       ", proxy);
        console.log("Old impl:    ", oldImpl);
        console.log("New impl:    ", address(newImpl));
        console.log("Multisig:    ", multisig);
        console.log("========================================");
    }

    function _readImpl(address proxy) internal view returns (address) {
        bytes32 value = vm.load(proxy, IMPL_SLOT);
        return address(uint160(uint256(value)));
    }

    /// @dev Defense-in-depth selector dispatch check. Same pattern as UpgradeRouter.
    function _assertSelectorExists(address proxy, bytes4 selector) internal view {
        (bool ok, bytes memory ret) = proxy.staticcall(abi.encodeWithSelector(selector, address(0), uint256(0), false));
        require(ok || ret.length > 0, "Upgrade: selector dispatch missing");
    }
}
