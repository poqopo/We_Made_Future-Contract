// SPDX-License-Identifier: MIT
pragma solidity =0.6.6;

import "../module/Math/SafeMath.sol";
import "../module/ERC20/SafeERC20.sol";
import "../module/Common/Ownable.sol";
import "../module/Utils/ReentrancyGuard.sol";
import "../We_Made_Future.sol";

contract WMFChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of WMF
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accWMFPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accWMFPerShare` (and `lastRewardSecond`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool.
        uint256 lastRewardSecond;  // Last second that WMFs distribution occurs.
        uint256 accWMFPerShare;   // Accumulated WMFs per share, times 1e18. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
        uint256 lpSupply;
    }

    // The WMF TOKEN!
    We_Made_Future public immutable WMF;
    // Dev address.
    address public devaddr;
    // WMF tokens created per second.
    uint256 public WMFPerSecond;
    // Deposit Fee address
    address public feeAddress;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block timestamp when WMF mining starts.
    uint256 public startTime;

    // Maximum WMFPerTime
    uint256 public constant MAX_EMISSION_RATE = 1000000000000000000;

    constructor(
        We_Made_Future _WMF,
        address _devaddr,
        address _feeAddress,
        uint256 _WMFPerTime,
        uint256 _startTime
    ) public {
        WMF = _WMF;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        WMFPerSecond = _WMFPerTime;
        startTime = _startTime;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IERC20 => bool) public poolExistence;
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken, uint16 _depositFeeBP, bool _withUpdate) external onlyOwner nonDuplicated(_lpToken) {
        // valid ERC20 token
        _lpToken.balanceOf(address(this));

        require(_depositFeeBP <= 400, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardSecond = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(
            PoolInfo({
                lpToken : _lpToken,
                allocPoint : _allocPoint,
                lastRewardSecond : lastRewardSecond,
                accWMFPerShare : 0,
                depositFeeBP : _depositFeeBP,
                lpSupply: 0
            })
        );

        emit addingPool(poolInfo.length - 1, address(_lpToken), _allocPoint, _depositFeeBP);
    }

    // Update the given pool's WMF allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) external onlyOwner {
        require(_depositFeeBP <= 400, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;

        emit setPool(_pid, address(poolInfo[_pid].lpToken), _allocPoint, _depositFeeBP);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from);
    }

    // View function to see pending WMFs on frontend.
    function pendingWMF(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accWMFPerShare = pool.accWMFPerShare;
        if (block.timestamp > pool.lastRewardSecond && pool.lpSupply != 0 && totalAllocPoint > 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardSecond, block.timestamp);
            uint256 WMFReward = multiplier.mul(WMFPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
            accWMFPerShare = accWMFPerShare.add(WMFReward.mul(1e18).div(pool.lpSupply));
        }
        return user.amount.mul(accWMFPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardSecond) {
            return;
        }
        if (pool.lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardSecond = block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardSecond, block.timestamp);
        uint256 WMFReward = multiplier.mul(WMFPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
        
        try WMF.pool_mint(address(this), WMFReward) {
        } catch (bytes memory reason) {
            WMFReward = 0;
            emit WMFMintError(reason);
        }

        if (9000000e18 < pool.lpSupply && pool.lpSupply < 18000000e18) {
            pool.depositFeeBP = 200;
        }
        else if (pool.lpSupply > 18000000e18) {
            pool.depositFeeBP = 0;
        }
        
        pool.accWMFPerShare = pool.accWMFPerShare.add(WMFReward.mul(1e18).div(pool.lpSupply));
        pool.lastRewardSecond = block.timestamp;
    }
    
    // Deposit LP tokens to MasterChef for WMF allocation.
    function deposit(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accWMFPerShare).div(1e18).sub(user.rewardDebt);
            if (pending > 0) {
                safeWMFTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            uint256 balanceBefore = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            _amount = pool.lpToken.balanceOf(address(this)).sub(balanceBefore);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
                pool.lpSupply = pool.lpSupply.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
                pool.lpSupply = pool.lpSupply.add(_amount);
            }
        }

        user.rewardDebt = user.amount.mul(pool.accWMFPerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from WMFChef.
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accWMFPerShare).div(1e18).sub(user.rewardDebt);
        if (pending > 0) {
            safeWMFTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
            pool.lpSupply = pool.lpSupply.sub(_amount);
        }

        user.rewardDebt = user.amount.mul(pool.accWMFPerShare).div(1e18);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);

        if (pool.lpSupply >=  amount) {
            pool.lpSupply = pool.lpSupply.sub(amount);
        } else {
            pool.lpSupply = 0;
        }

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe WMF transfer function, just in case if rounding error causes pool to not have enough WMFs.
    function safeWMFTransfer(address _to, uint256 _amount) internal {
        uint256 WMFBal = WMF.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > WMFBal) {
            transferSuccess = WMF.transfer(_to, WMFBal);
        } else {
            transferSuccess = WMF.transfer(_to, _amount);
        }
        require(transferSuccess, "safeWMFTransfer: transfer failed");
    }

    // Update dev address.
    function setDevAddress(address _devaddr) external {
        require(msg.sender == devaddr, "dev: wut?");
        require(_devaddr != address(0), "!nonzero");

        devaddr = _devaddr;
        emit SetDevAddress(msg.sender, _devaddr);
    }

    function setFeeAddress(address _feeAddress) external {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "!nonzero");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

 // Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _WMFPerSecond) external onlyOwner {
        require(_WMFPerSecond <= MAX_EMISSION_RATE, "Too high");
        massUpdatePools();
        WMFPerSecond = _WMFPerSecond;
        emit UpdateEmissionRate(msg.sender, _WMFPerSecond);
    }

    // Only update before start of farm
    function updateStartTime(uint256 _newStartTime) external onlyOwner {
        require(block.timestamp < startTime, "cannot change start time if farm has already started");
        require(block.timestamp < _newStartTime, "cannot set start time in the past");
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            pool.lastRewardSecond = _newStartTime;
        }
        startTime = _newStartTime;

        emit UpdateStartTime(startTime);
    }


    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 WMFPerSecond);
    event addingPool(uint256 indexed pid, address lpToken, uint256 allocPoint, uint256 depositFeeBP);
    event setPool(uint256 indexed pid, address lpToken, uint256 allocPoint, uint256 depositFeeBP);
    event UpdateStartTime(uint256 newStartTime);
    event WMFMintError(bytes reason);

}