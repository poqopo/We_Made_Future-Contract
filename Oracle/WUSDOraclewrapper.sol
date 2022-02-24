
pragma solidity =0.6.6;


import "../module/Math/SafeMath.sol";
import "./AggregatorV3Interface.sol";
import "../Owned.sol";

contract WUSDOracleWrapper is Owned {
    using SafeMath for uint256;

    AggregatorV3Interface private priceFeedWUSDETH;

    uint256 public chainlink_WUSD_eth_decimals;

    uint256 public PRICE_PRECISION = 1e6;
    uint256 public EXTRA_PRECISION = 1e6;
    address public timelock_address;

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == owner || msg.sender == timelock_address, "Not owner or timelock");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor (
        address _creator_address,
        address _timelock_address
    ) public Owned(_creator_address) {
        timelock_address = _timelock_address;

        // WUSD / ETH
        priceFeedWUSDETH = AggregatorV3Interface(0xb48C2315b3D2e64552Ec37d6DaDb542e7E0Adc4c);
        chainlink_WUSD_eth_decimals = priceFeedWUSDETH.decimals();
    }

    /* ========== VIEWS ========== */

    function getWUSDPrice() public view returns (uint256 raw_price, uint256 precise_price) {
        (uint80 roundID, int price, , uint256 updatedAt, uint80 answeredInRound) = priceFeedWUSDETH.latestRoundData();
        require(price >= 0 && updatedAt!= 0 && answeredInRound >= roundID, "Invalid chainlink price");
        
        // E6
        raw_price = uint256(price).mul(PRICE_PRECISION).div(uint256(10) ** chainlink_WUSD_eth_decimals);

        // E12
        precise_price = uint256(price).mul(PRICE_PRECISION).mul(EXTRA_PRECISION).div(uint256(10) ** chainlink_WUSD_eth_decimals);
    }

    // Override the logic of the WUSD-WETH Uniswap TWAP Oracle
    // Expected Parameters: weth address, uint256 1e6
    // Returns: WUSD-WETH Chainlink price (with 1e6 precision)
    function consult(address token, uint amountIn) external view returns (uint amountOut) {
        // safety checks (replacing regular WUSD-WETH oracle in WUSD.sol)
        require(token == 0xc778417E063141139Fce010982780140Aa0cD5Ab, "must use weth address");
        require(amountIn == 1e6, "must call with 1e6");

        // needs to return it inverted
        (, uint256 WUSD_precise_price) = getWUSDPrice(); 
        return PRICE_PRECISION.mul(PRICE_PRECISION).mul(EXTRA_PRECISION).div(WUSD_precise_price);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setChainlinkWUSDETHOracle(address _chainlink_WUSD_eth_oracle) external onlyByOwnGov {
        priceFeedWUSDETH = AggregatorV3Interface(_chainlink_WUSD_eth_oracle);
        chainlink_WUSD_eth_decimals = priceFeedWUSDETH.decimals();
    }

}