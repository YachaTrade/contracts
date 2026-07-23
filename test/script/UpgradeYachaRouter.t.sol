// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {UpgradeYachaRouter} from "../../script/upgrade/normal/UpgradeYachaRouter.s.sol";
import {YachaRouter} from "../../src/router/YachaRouter.sol";

contract UpgradeYachaRouterAuthorityStub {
    address public owner;
    bool public allowed;

    constructor(address owner_, bool allowed_) {
        owner = owner_;
        allowed = allowed_;
    }

    function setAllowed(bool allowed_) external {
        allowed = allowed_;
    }

    function canCall(address caller, address, bytes4) external view returns (bool, uint32) {
        return (allowed && caller == owner, 0);
    }
}

contract UpgradeYachaRouterDependencyStub {}

contract UpgradeYachaRouterAdapterStub {
    address public immutable factory;
    address public immutable tokenRegistry;

    constructor(address factory_, address tokenRegistry_) {
        factory = factory_;
        tokenRegistry = tokenRegistry_;
    }
}

contract UpgradeYachaRouterQuoterStub {
    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }
}

contract UpgradeYachaRouterTest is Test {
    bytes32 private constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant OWNER_KEY = 0xA11CE;

    address private owner;
    UpgradeYachaRouterAuthorityStub private authority;
    YachaRouter private router;
    UpgradeYachaRouter private upgrade;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        authority = new UpgradeYachaRouterAuthorityStub(owner, true);

        UpgradeYachaRouterDependencyStub bondingCurve = new UpgradeYachaRouterDependencyStub();
        UpgradeYachaRouterDependencyStub tokenRegistry = new UpgradeYachaRouterDependencyStub();
        UpgradeYachaRouterDependencyStub wrappedNative = new UpgradeYachaRouterDependencyStub();
        UpgradeYachaRouterDependencyStub factory = new UpgradeYachaRouterDependencyStub();
        UpgradeYachaRouterAdapterStub adapter =
            new UpgradeYachaRouterAdapterStub(address(factory), address(tokenRegistry));
        UpgradeYachaRouterQuoterStub quoter = new UpgradeYachaRouterQuoterStub(address(factory));

        router = YachaRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(new YachaRouter()),
                        abi.encodeCall(
                            YachaRouter.initialize,
                            (
                                address(authority),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(wrappedNative),
                                address(adapter),
                                address(quoter)
                            )
                        )
                    )
                ))
        );
        upgrade = new UpgradeYachaRouter();
    }

    function test_run_rejectsChainIdMismatch() public {
        UpgradeYachaRouter.Config memory config = _config(OWNER_KEY, owner);
        config.chainId = block.chainid + 1;

        vm.expectRevert("UpgradeYachaRouter: CHAIN_ID mismatch");
        upgrade.runWithConfig(config);
    }

    function test_run_rejectsSignerThatIsNotProtocolOwner() public {
        uint256 wrongKey = 0xB0B;

        vm.expectRevert("UpgradeYachaRouter: signer must equal PM.owner");
        upgrade.runWithConfig(_config(wrongKey, vm.addr(wrongKey)));
    }

    function test_run_rejectsMissingUpgradePermission() public {
        authority.setAllowed(false);

        vm.expectRevert("UpgradeYachaRouter: upgrade permission missing");
        upgrade.runWithConfig(_config(OWNER_KEY, owner));
    }

    function test_run_upgradesImplementationAndPreservesDependencies() public {
        address oldImplementation = _implementation(address(router));
        address authorityBefore = router.authority();
        address bondingCurveBefore = router.bondingCurve();
        address tokenRegistryBefore = router.tokenRegistry();
        address wrappedNativeBefore = router.wrappedNative();
        address adapterBefore = router.v3SwapAdapter();
        address quoterBefore = router.quoterV2();

        address newImplementation = upgrade.runWithConfig(_config(OWNER_KEY, owner));

        assertNotEq(newImplementation, oldImplementation);
        assertEq(_implementation(address(router)), newImplementation);
        assertEq(router.authority(), authorityBefore);
        assertEq(router.bondingCurve(), bondingCurveBefore);
        assertEq(router.tokenRegistry(), tokenRegistryBefore);
        assertEq(router.wrappedNative(), wrappedNativeBefore);
        assertEq(router.v3SwapAdapter(), adapterBefore);
        assertEq(router.quoterV2(), quoterBefore);
    }

    function _config(uint256 signerKey, address expectedSigner)
        private
        view
        returns (UpgradeYachaRouter.Config memory)
    {
        return UpgradeYachaRouter.Config({
            chainId: block.chainid,
            signerKey: signerKey,
            expectedSigner: expectedSigner,
            proxy: address(router),
            protocolManager: address(authority)
        });
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }
}
