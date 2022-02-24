// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.6.6;

import '../Uniswap/TransferHelper.sol';
import "../We_Made_Future.sol";
import "../We_Made_Future_USD.sol";
import "../Oracle/UniswapPairOracle.sol";
import "./WUSDPoolLibrary.sol";
import "../Owned.sol";
import "../module/ERC20/ERC20.sol";
import "../module/Math/SafeMath.sol";


contract WUSDPool is Owned {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    ERC20 private collateral_token;
    address private collateral_address;

    address private WUSD_contract_address;
    address private WMF_contract_address;
    We_Made_Future private WMF;
    WUSDStablecoin private WUSD;

    UniswapPairOracle private collatEthOracle;
    address public collat_eth_oracle_address;
    address private weth_address;

    uint256 public minting_fee;
    uint256 public redemption_fee;
    uint256 public buyback_fee;
    uint256 public recollat_fee;

    mapping (address => uint256) public redeemWMFBalances;
    mapping (address => uint256) public redeemCollateralBalances;
    uint256 public unclaimedPoolCollateral;
    uint256 public unclaimedPoolWMF;
    mapping (address => uint256) public lastRedeemed;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;
    uint256 private constant COLLATERAL_RATIO_PRECISION = 1e6;
    uint256 private constant COLLATERAL_RATIO_MAX = 1e6;

    // Number of decimals needed to get to 18
    uint256 private immutable missing_decimals;
    
    // Pool_ceiling is the total units of collateral that a pool contract can hold
    uint256 public pool_ceiling = 1000000e18;

    // Stores price of the collateral, if price is paused
    uint256 public pausedPrice = 0;

    // Bonus rate on WMF minted during recollateralizeWUSD(); 6 decimals of precision, set to 0.75% on genesis
    uint256 public bonus_rate = 7500;

    // Number of blocks to wait before being able to collectRedemption()
    uint256 public redemption_delay = 1;
    
    // AccessControl state variables
    bool public mintPaused = false;
    bool public redeemPaused = false;

    /* ========== MODIFIERS ========== */


    modifier notRedeemPaused() {
        require(redeemPaused == false, "Redeeming is paused");
        _;
    }

    modifier notMintPaused() {
        require(mintPaused == false, "Minting is paused");
        _;
    }
 
    /* ========== CONSTRUCTOR ========== */
    
    constructor (
        address _WUSD_contract_address,
        address _WMF_contract_address,
        address _collateral_address,
        address _creator_address
    ) public Owned(_creator_address){
        require(
            (_WUSD_contract_address != address(0))
            && (_WMF_contract_address != address(0))
            && (_collateral_address != address(0))
            && (_creator_address != address(0))
        , "Zero address detected"); 
        WUSD = WUSDStablecoin(_WUSD_contract_address);
        WMF = We_Made_Future(_WMF_contract_address);
        WUSD_contract_address = _WUSD_contract_address;
        WMF_contract_address = _WMF_contract_address;
        collateral_address = _collateral_address;
        collateral_token = ERC20(_collateral_address);
        missing_decimals = uint(18).sub(collateral_token.decimals());
    }

    /* ========== VIEWS ========== */

    // Returns dollar value of collateral held in this WUSD pool
    function collatDollarBalance() public view returns (uint256) {
        uint256 eth_usd_price = WUSD.eth_usd_price();
        uint256 eth_collat_price = collatEthOracle.consult(weth_address, (PRICE_PRECISION * (10 ** missing_decimals)));

        uint256 collat_usd_price = eth_usd_price.mul(PRICE_PRECISION).div(eth_collat_price);
        return (collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral)).mul(10 ** missing_decimals).mul(collat_usd_price).div(PRICE_PRECISION); //.mul(getCollateralPrice()).div(1e6);    
        
    }

    // Returns the value of excess collateral held in this WUSD pool, compared to what is needed to maintain the global collateral ratio
    function availableExcessCollatDV() public view returns (uint256) {
        uint256 total_supply = WUSD.totalSupply();
        uint256 global_collateral_ratio = WUSD.global_collateral_ratio();
        uint256 global_collat_value = WUSD.globalCollateralValue();

        if (global_collateral_ratio > COLLATERAL_RATIO_PRECISION) global_collateral_ratio = COLLATERAL_RATIO_PRECISION; // Handles an overcollateralized contract with CR > 1
        uint256 required_collat_dollar_value_d18 = (total_supply.mul(global_collateral_ratio)).div(COLLATERAL_RATIO_PRECISION); // Calculates collateral needed to back each 1 WUSD with $1 of collateral at current collat ratio
        if (global_collat_value > required_collat_dollar_value_d18) return global_collat_value.sub(required_collat_dollar_value_d18);
        else return 0;
    }

    /* ========== PUBLIC FUNCTIONS ========== */
    
    // Returns the price of the pool collateral in USD
    function getCollateralPrice() public view returns (uint256) {
        uint256 eth_usd_price = WUSD.eth_usd_price();
        return eth_usd_price.mul(PRICE_PRECISION).div(collatEthOracle.consult(weth_address, PRICE_PRECISION * (10 ** missing_decimals)));
        
    }

    function setCollatETHOracle(address _collateral_weth_oracle_address, address _weth_address) external onlyOwner {
        collat_eth_oracle_address = _collateral_weth_oracle_address;
        collatEthOracle = UniswapPairOracle(_collateral_weth_oracle_address);
        weth_address = _weth_address;
    }

    // We separate out the 1t1, fractional and algorithmic minting functions for gas efficiency 
    function mint1t1WUSD(uint256 collateral_amount, uint256 WUSD_out_min) external notMintPaused {
        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals);

        require(WUSD.global_collateral_ratio() >= COLLATERAL_RATIO_MAX, "Collateral ratio must be >= 1");
        require((collateral_token.balanceOf(address(this))).sub(unclaimedPoolCollateral).add(collateral_amount) <= pool_ceiling, "[Pool's Closed]: Ceiling reached");
        
        (uint256 WUSD_amount_d18) = WUSDPoolLibrary.calcMint1t1WUSD(
            getCollateralPrice(),
            collateral_amount_d18
        ); //1 WUSD for each $1 worth of collateral

        WUSD_amount_d18 = (WUSD_amount_d18.mul(uint(1e6).sub(minting_fee))).div(1e6); //remove precision at the end
        require(WUSD_out_min <= WUSD_amount_d18, "Slippage limit reached");

        TransferHelper.safeTransferFrom(address(collateral_token), msg.sender, address(this), collateral_amount);
        WUSD.pool_mint(msg.sender, WUSD_amount_d18);
    }

    // 0% collateral-backed
    function mintAlgorithmicWUSD(uint256 WMF_amount_d18, uint256 WUSD_out_min) external notMintPaused {
        uint256 WMF_price = WUSD.WMF_price();
        require(WUSD.global_collateral_ratio() == 0, "Collateral ratio must be 0");
        
        (uint256 WUSD_amount_d18) = WUSDPoolLibrary.calcMintAlgorithmicWUSD(
            WMF_price, // X WMF / 1 USD
            WMF_amount_d18
        );

        WUSD_amount_d18 = (WUSD_amount_d18.mul(uint(1e6).sub(minting_fee))).div(1e6);
        require(WUSD_out_min <= WUSD_amount_d18, "Slippage limit reached");

        WMF.pool_burn_from(msg.sender, WMF_amount_d18);
        WUSD.pool_mint(msg.sender, WUSD_amount_d18);
    }

    // Will fail if fully collateralized or fully algorithmic
    // > 0% and < 100% collateral-backed
    function mintFractionalWUSD(uint256 collateral_amount, uint256 WMF_amount, uint256 WUSD_out_min) external notMintPaused {
        uint256 WMF_price = WUSD.WMF_price();
        uint256 global_collateral_ratio = WUSD.global_collateral_ratio();

        require(global_collateral_ratio < COLLATERAL_RATIO_MAX && global_collateral_ratio > 0, "Collateral ratio needs to be between .000001 and .999999");
        require(collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral).add(collateral_amount) <= pool_ceiling, "Pool ceiling reached, no more WUSD can be minted with this collateral");

        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals);
        WUSDPoolLibrary.MintFF_Params memory input_params = WUSDPoolLibrary.MintFF_Params(
            WMF_price,
            getCollateralPrice(),
            WMF_amount,
            collateral_amount_d18,
            global_collateral_ratio
        );

        (uint256 mint_amount, uint256 WMF_needed) = WUSDPoolLibrary.calcMintFractionalWUSD(input_params);

        mint_amount = (mint_amount.mul(uint(1e6).sub(minting_fee))).div(1e6);
        require(WUSD_out_min <= mint_amount, "Slippage limit reached");
        require(WMF_needed <= WMF_amount, "Not enough WMF inputted");

        WMF.pool_burn_from(msg.sender, WMF_needed);
        TransferHelper.safeTransferFrom(address(collateral_token), msg.sender, address(this), collateral_amount);
        WUSD.pool_mint(msg.sender, mint_amount);
    }

    // Redeem collateral. 100% collateral-backed
    function redeem1t1WUSD(uint256 WUSD_amount, uint256 COLLATERAL_out_min) external notRedeemPaused {
        require(WUSD.global_collateral_ratio() == COLLATERAL_RATIO_MAX, "Collateral ratio must be == 1");

        // Need to adjust for decimals of collateral
        uint256 WUSD_amount_precision = WUSD_amount.div(10 ** missing_decimals);
        (uint256 collateral_needed) = WUSDPoolLibrary.calcRedeem1t1WUSD(
            getCollateralPrice(),
            WUSD_amount_precision
        );

        collateral_needed = (collateral_needed.mul(uint(1e6).sub(redemption_fee))).div(1e6);
        require(collateral_needed <= collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral), "Not enough collateral in pool");
        require(COLLATERAL_out_min <= collateral_needed, "Slippage limit reached");

        redeemCollateralBalances[msg.sender] = redeemCollateralBalances[msg.sender].add(collateral_needed);
        unclaimedPoolCollateral = unclaimedPoolCollateral.add(collateral_needed);
        lastRedeemed[msg.sender] = block.number;
        
        // Move all external functions to the end
        WUSD.pool_burn_from(msg.sender, WUSD_amount);
    }

    // Will fail if fully collateralized or algorithmic
    // Redeem WUSD for collateral and WMF. > 0% and < 100% collateral-backed
    function redeemFractionalWUSD(uint256 WUSD_amount, uint256 WMF_out_min, uint256 COLLATERAL_out_min) external notRedeemPaused {
        uint256 WMF_price = WUSD.WMF_price();
        uint256 global_collateral_ratio = WUSD.global_collateral_ratio();

        require(global_collateral_ratio < COLLATERAL_RATIO_MAX && global_collateral_ratio > 0, "Collateral ratio needs to be between .000001 and .999999");
        uint256 col_price_usd = getCollateralPrice();

        uint256 WUSD_amount_post_fee = (WUSD_amount.mul(uint(1e6).sub(redemption_fee))).div(PRICE_PRECISION);

        uint256 WMF_dollar_value_d18 = WUSD_amount_post_fee.sub(WUSD_amount_post_fee.mul(global_collateral_ratio).div(PRICE_PRECISION));
        uint256 WMF_amount = WMF_dollar_value_d18.mul(PRICE_PRECISION).div(WMF_price);

        // Need to adjust for decimals of collateral
        uint256 WUSD_amount_precision = WUSD_amount_post_fee.div(10 ** missing_decimals);
        uint256 collateral_dollar_value = WUSD_amount_precision.mul(global_collateral_ratio).div(PRICE_PRECISION);
        uint256 collateral_amount = collateral_dollar_value.mul(PRICE_PRECISION).div(col_price_usd);


        require(collateral_amount <= collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral), "Not enough collateral in pool");
        require(COLLATERAL_out_min <= collateral_amount, "Slippage limit reached [collateral]");
        require(WMF_out_min <= WMF_amount, "Slippage limit reached [WMF]");

        redeemCollateralBalances[msg.sender] = redeemCollateralBalances[msg.sender].add(collateral_amount);
        unclaimedPoolCollateral = unclaimedPoolCollateral.add(collateral_amount);

        redeemWMFBalances[msg.sender] = redeemWMFBalances[msg.sender].add(WMF_amount);
        unclaimedPoolWMF = unclaimedPoolWMF.add(WMF_amount);

        lastRedeemed[msg.sender] = block.number;
        
        // Move all external functions to the end
        WUSD.pool_burn_from(msg.sender, WUSD_amount);
        WMF.pool_mint(address(this), WMF_amount);
    }

    // Redeem WUSD for WMF. 0% collateral-backed
    function redeemAlgorithmicWUSD(uint256 WUSD_amount, uint256 WMF_out_min) external notRedeemPaused {
        uint256 WMF_price = WUSD.WMF_price();
        uint256 global_collateral_ratio = WUSD.global_collateral_ratio();

        require(global_collateral_ratio == 0, "Collateral ratio must be 0"); 
        uint256 WMF_dollar_value_d18 = WUSD_amount;

        WMF_dollar_value_d18 = (WMF_dollar_value_d18.mul(uint(1e6).sub(redemption_fee))).div(PRICE_PRECISION); //apply fees

        uint256 WMF_amount = WMF_dollar_value_d18.mul(PRICE_PRECISION).div(WMF_price);
        
        redeemWMFBalances[msg.sender] = redeemWMFBalances[msg.sender].add(WMF_amount);
        unclaimedPoolWMF = unclaimedPoolWMF.add(WMF_amount);
        
        lastRedeemed[msg.sender] = block.number;
        
        require(WMF_out_min <= WMF_amount, "Slippage limit reached");
        // Move all external functions to the end
        WUSD.pool_burn_from(msg.sender, WUSD_amount);
        WMF.pool_mint(address(this), WMF_amount);
    }

    // After a redemption happens, transfer the newly minted WMF and owed collateral from this pool
    // contract to the user. Redemption is split into two functions to prevent flash loans from being able
    // to take out WUSD/collateral from the system, use an AMM to trade the new price, and then mint back into the system.
    function collectRedemption() external {
        require((lastRedeemed[msg.sender].add(redemption_delay)) <= block.number, "Must wait for redemption_delay blocks before collecting redemption");
        bool sendWMF = false;
        bool sendCollateral = false;
        uint WMFAmount = 0;
        uint CollateralAmount = 0;

        // Use Checks-Effects-Interactions pattern
        if(redeemWMFBalances[msg.sender] > 0){
            WMFAmount = redeemWMFBalances[msg.sender];
            redeemWMFBalances[msg.sender] = 0;
            unclaimedPoolWMF = unclaimedPoolWMF.sub(WMFAmount);

            sendWMF = true;
        }
        
        if(redeemCollateralBalances[msg.sender] > 0){
            CollateralAmount = redeemCollateralBalances[msg.sender];
            redeemCollateralBalances[msg.sender] = 0;
            unclaimedPoolCollateral = unclaimedPoolCollateral.sub(CollateralAmount);

            sendCollateral = true;
        }

        if(sendWMF){
            TransferHelper.safeTransfer(address(WMF), msg.sender, WMFAmount);
        }
        if(sendCollateral){
            TransferHelper.safeTransfer(address(collateral_token), msg.sender, CollateralAmount);
        }
    }


    // When the protocol is recollateralizing, we need to give a discount of WMF to hit the new CR target
    // Thus, if the target collateral ratio is higher than the actual value of collateral, minters get WMF for adding collateral
    // This function simply rewards anyone that sends collateral to a pool with the same amount of WMF + the bonus rate
    // Anyone can call this function to recollateralize the protocol and take the extra WMF value from the bonus rate as an arb opportunity
    function recollateralizeWUSD(uint256 collateral_amount, uint256 WMF_out_min) external {
        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals);
        uint256 WMF_price = WUSD.WMF_price();
        uint256 WUSD_total_supply = WUSD.totalSupply();
        uint256 global_collateral_ratio = WUSD.global_collateral_ratio();
        uint256 global_collat_value = WUSD.globalCollateralValue();

        (uint256 collateral_units, uint256 amount_to_recollat) = WUSDPoolLibrary.calcRecollateralizeWUSDInner(
            collateral_amount_d18,
            getCollateralPrice(),
            global_collat_value,
            WUSD_total_supply,
            global_collateral_ratio
        ); 

        uint256 collateral_units_precision = collateral_units.div(10 ** missing_decimals);

        uint256 WMF_paid_back = amount_to_recollat.mul(uint(1e6).add(bonus_rate).sub(recollat_fee)).div(WMF_price);

        require(WMF_out_min <= WMF_paid_back, "Slippage limit reached");
        TransferHelper.safeTransferFrom(address(collateral_token), msg.sender, address(this), collateral_units_precision);
        WMF.pool_mint(msg.sender, WMF_paid_back);
        
    }

    // Function can be called by an WMF holder to have the protocol buy back WMF with excess collateral value from a desired collateral pool
    // This can also happen if the collateral ratio > 1
    function buyBackWMF(uint256 WMF_amount, uint256 COLLATERAL_out_min) external {
        uint256 WMF_price = WUSD.WMF_price();
    
        WUSDPoolLibrary.BuybackWMF_Params memory input_params = WUSDPoolLibrary.BuybackWMF_Params(
            availableExcessCollatDV(),
            WMF_price,
            getCollateralPrice(),
            WMF_amount
        );

        (uint256 collateral_equivalent_d18) = (WUSDPoolLibrary.calcBuyBackWMF(input_params)).mul(uint(1e6).sub(buyback_fee)).div(1e6);
        uint256 collateral_precision = collateral_equivalent_d18.div(10 ** missing_decimals);

        require(COLLATERAL_out_min <= collateral_precision, "Slippage limit reached");
        // Give the sender their desired collateral and burn the WMF
        WMF.pool_burn_from(msg.sender, WMF_amount);
        TransferHelper.safeTransfer(address(collateral_token), msg.sender, collateral_precision);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function toggleMinting() external {
        require(msg.sender == owner);
        mintPaused = !mintPaused;

        emit MintingToggled(mintPaused);
    }

    function toggleRedeeming() external {
        require(msg.sender == owner);
        redeemPaused = !redeemPaused;

        emit RedeemingToggled(redeemPaused);
    }
    
    // Combined into one function due to 24KiB contract memory limit
    function setPoolParameters(uint256 new_ceiling, uint256 new_bonus_rate, uint256 new_redemption_delay, uint256 new_mint_fee, uint256 new_redeem_fee, uint256 new_buyback_fee, uint256 new_recollat_fee) external onlyOwner {
        pool_ceiling = new_ceiling;
        bonus_rate = new_bonus_rate;
        redemption_delay = new_redemption_delay;
        minting_fee = new_mint_fee;
        redemption_fee = new_redeem_fee;
        buyback_fee = new_buyback_fee;
        recollat_fee = new_recollat_fee;

        emit PoolParametersSet(new_ceiling, new_bonus_rate, new_redemption_delay, new_mint_fee, new_redeem_fee, new_buyback_fee, new_recollat_fee);
    }

    /* ========== EVENTS ========== */

    event PoolParametersSet(uint256 new_ceiling, uint256 new_bonus_rate, uint256 new_redemption_delay, uint256 new_mint_fee, uint256 new_redeem_fee, uint256 new_buyback_fee, uint256 new_recollat_fee);
    event MintingToggled(bool toggled);
    event RedeemingToggled(bool toggled);

}