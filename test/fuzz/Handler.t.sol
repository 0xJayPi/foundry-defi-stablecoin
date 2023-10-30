// SDPX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timeMintIscalled; // Handler Ghost Variable => https://book.getfoundry.sh/forge/invariant-testing#handler-ghost-variables
    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max;

    address[] public usersWithCollateralDeposited;
    address[] collateralTokens;
    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;

        collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    /**
     * @dev whatever parameter you have will be randominzed
     */
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) external payable {
        collateralSeed = bound(collateralSeed, 0, collateralTokens.length - 1);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) external {
        collateralSeed = bound(collateralSeed, 0, collateralTokens.length - 1);

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) return; // we can use vm.assume instead. https://book.getfoundry.sh/cheatcodes/assume?highlight=vm.assume#assume
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    function mintDsc(uint256 amount, uint256 addressSeed) external {
        // amount = bound(amount, 1, MAX_DEPOSIT_SIZE);

        if (usersWithCollateralDeposited.length == 0) return;

        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUsd) - int256(totalDscMinted));
        if (maxDscToMint < 0) return;

        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) return;

        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();

        timeMintIscalled++;
    }

    /**
     * This breaks our invariants. Now bug? If price plummets, the protocol is broken
     */
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        return ERC20Mock(collateralTokens[collateralSeed]);
    }
}
