// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {INadFunRouter} from "../../src/interfaces/INadFunRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {NadFunRouter} from "../../src/router/NadFunRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract NadFunRouterNativeQuoteGuardTest is SetUp {
    NadFunRouter internal nativeRouter;
    MockERC20 internal usdc;
    address internal foreignQuoteToken;

    function setUp() public override {
        super.setUp();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        wmon = new MockWMON();

        vm.startPrank(admin);
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1_000_000_000 ether, 800_000_000 ether, 0, 0, 0, 0, 0);
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(this));

        NadFunRouter routerImpl = new NadFunRouter();
        nativeRouter = NadFunRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(routerImpl),
                        abi.encodeCall(
                            NadFunRouter.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(wmon),
                                address(0)
                            )
                        )
                    )
                ))
        );
        vm.stopPrank();

        usdc.mint(address(this), 100e6);
        usdc.transfer(address(bondingCurve), 100e6);
        (foreignQuoteToken,) = bondingCurve.create(_usdcCurveParams());
    }

    function test_buyWithNative_revertsForForeignQuoteToken() public {
        vm.deal(user1, 1 ether);

        vm.prank(user1);
        vm.expectRevert(INadFunRouter.InvalidNativeQuoteToken.selector);
        nativeRouter.buyWithNative{value: 1 ether}(
            INadFunRouter.BuyWithNativeParams({
                amountOutMin: 0, token: foreignQuoteToken, to: user1, deadline: block.timestamp + 1
            })
        );
    }

    function test_exactOutBuyWithNative_revertsForForeignQuoteToken() public {
        vm.deal(user1, 1 ether);

        vm.prank(user1);
        vm.expectRevert(INadFunRouter.InvalidNativeQuoteToken.selector);
        nativeRouter.exactOutBuyWithNative{value: 1 ether}(
            INadFunRouter.ExactOutBuyWithNativeParams({
                amountOut: 1 ether, token: foreignQuoteToken, to: user1, deadline: block.timestamp + 1
            })
        );
    }

    function _usdcCurveParams() internal view returns (IBondingCurve.CreateTokenParams memory params) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVault), bps: 10_000, setupData: abi.encode(feeReceiver)
        });

        params = IBondingCurve.CreateTokenParams({
            name: "ForeignQuote",
            symbol: "FQ",
            tokenURI: "",
            quoteToken: address(usdc),
            creatorFeeRate: 100,
            vaults: vaults,
            salt: keccak256("foreign-quote-native-buy-guard"),
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: creator,
            buyQuoteAmount: 0
        });
    }
}
