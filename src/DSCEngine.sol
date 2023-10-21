// SPDX-Licence-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title Decentralized Stable Coin Engine
 * @author 0xJayPi
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token = 1 USD peg
 * This stablecoin has the properties:
 * - Exogneous Collateral
 * - Dollar Pegged
 * - Algoritmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by wETH and wBTC
 *
 * Our DSC system should always be overcollateralized. At no point, should the value of all the collateral be less than the value of all the DSC tokens.
 *
 * @notice This DSCEngince contract is a base contract that contains all the logic for the Decentralized Stable Coin system
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////
    // Errors
    ////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngina__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();

    ////////////////
    // State
    ////////////////
    uint256 private constant ADDITION_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // Force the user to be 200% collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collaterlaDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////
    // Events
    ////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    ////////////////
    // Modifiers
    ////////////////
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////
    // Functions
    ////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////
    // External Functions
    ////////////////
    function depositCollateralAndMintDsc() external {}

    /**
     * @notice This function allows a user to deposit collateral into the system
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collaterlaDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    /**
     * @notice This function allows a user to mint DSC tokens
     * @param amountDscToMint The amount of DSC to mint
     * @notice They must have more collateral value than the minimal treasure
     */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}

    ////////////////
    // Private & Internal View Functions
    ////////////////

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @notice This function returns how close to liquidation a user is. If goes below 1, they are liquidated
     * @param user The address of the user
     * @return The health factor of the user
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        // The amount of collateral the user has, adjusted for the liquidation threshold
        // ie 100 * 50 / 100 = 50 -> collateral / 2 -> foce user to be 200% collateralized
        uint256 collaterlaAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collaterlaAdjustedForThreshold * PRECISION) / totalDscMinted; // collataral > 200% = healthFactor > 1
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngina__BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////
    // Public & External View Functions
    ////////////////

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValue) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collaterlaDeposited[user][token];
            totalCollateralValue += getUsdValue(token, amount);
        }

        return totalCollateralValue;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (uint256(price) * ADDITION_FEED_PRECISION * amount) / PRECISION;
    }
}
