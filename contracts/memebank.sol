// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPriceOracle {
    function getMemecoinPrice() external view returns (uint256);
}

contract MemecoinLendingBorrowing {
    IERC20 public memecoin;
    IERC20 public stablecoin;
    IPriceOracle public priceOracle;

    // Updated UserData struct to include lending info
    struct UserData {
        uint256 collateralAmount;
        uint256 borrowedAmount;
        uint256 borrowTimestamp;
        uint256 stabledDeposited;    // New: Amount of stablecoins deposited
        uint256 depositTimestamp;     // New: When they deposited
    }

    mapping(address => UserData) public users;

    // Contract state variables
    uint256 public interestRate = 10; // Annual interest rate for borrowing in %
    uint256 public lendingInterestRate = 8; // Annual interest rate for lenders in %
    uint256 public collateralizationRatio = 166; // 166% over-collateralization
    uint256 public liquidationRatio = 150; // Liquidation ratio (150% collateral)
    uint256 public totalStableDeposits; // Track total deposits

    address public owner;

    // Events
    event StableDeposited(address indexed user, uint256 amount);
    event StableWithdrawn(address indexed user, uint256 amount, uint256 interest);
    event InterestEarned(address indexed user, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    constructor(address _memecoin, address _stablecoin, address _priceOracle) {
        memecoin = IERC20(_memecoin);
        stablecoin = IERC20(_stablecoin);
        priceOracle = IPriceOracle(_priceOracle);
        owner = msg.sender;
    }

    // New function: Deposit stablecoins to earn interest
    function depositStable(uint256 _amount) external {
        require(_amount > 0, "Amount must be greater than 0");
        
        // Transfer stablecoins from user to contract
        require(stablecoin.transferFrom(msg.sender, address(this), _amount), "Transfer failed");

        // If first time deposit, set timestamp
        if (users[msg.sender].stabledDeposited == 0) {
            users[msg.sender].depositTimestamp = block.timestamp;
        }

        // Update user's deposit
        users[msg.sender].stabledDeposited += _amount;
        totalStableDeposits += _amount;

        emit StableDeposited(msg.sender, _amount);
    }

    // New function: Calculate lending interest earned
    function calculateLendingInterest(address _user) public view returns (uint256) {
        UserData storage user = users[_user];
        if (user.stabledDeposited == 0) return 0;

        uint256 timeElapsed = block.timestamp - user.depositTimestamp;
        
        // Interest = Principal * Rate * Time (in years) / 100
        uint256 interest = (user.stabledDeposited * lendingInterestRate * timeElapsed) / (365 days * 100);
        
        return interest;
    }

    // New function: Withdraw deposited stablecoins with interest
    function withdrawStable(uint256 _amount) external {
        UserData storage user = users[msg.sender];
        require(user.stabledDeposited > 0, "No deposits found");
        
        uint256 interest = calculateLendingInterest(msg.sender);
        uint256 totalAvailable = user.stabledDeposited + interest;
        
        require(_amount <= totalAvailable, "Insufficient balance");
        require(_amount <= stablecoin.balanceOf(address(this)), "Contract has insufficient funds");

        // Update state before transfer
        if (_amount == totalAvailable) {
            // Full withdrawal
            user.stabledDeposited = 0;
            user.depositTimestamp = 0;
            totalStableDeposits -= user.stabledDeposited;
        } else {
            // Partial withdrawal
            uint256 principalWithdrawn = _amount > user.stabledDeposited ? user.stabledDeposited : _amount;
            user.stabledDeposited -= principalWithdrawn;
            totalStableDeposits -= principalWithdrawn;
        }

        // Transfer funds to user
        require(stablecoin.transfer(msg.sender, _amount), "Transfer failed");

        emit StableWithdrawn(msg.sender, _amount, interest);
    }

    // New function: View total earnings (principal + interest)
    function getTotalEarnings(address _user) external view returns (uint256) {
        UserData storage user = users[_user];
        return user.stabledDeposited + calculateLendingInterest(_user);
    }

    // Modified borrowStablecoins function to check available liquidity
    function borrowStablecoins(uint256 _amount) public {
        require(stablecoin.balanceOf(address(this)) >= _amount, "Insufficient lending liquidity");
        
        uint256 collateralValue = getCollateralValue(msg.sender);
        uint256 maxBorrowAmount = (collateralValue * 60) / 100;
        require(_amount <= maxBorrowAmount, "Borrow amount exceeds collateral limit");

        users[msg.sender].borrowTimestamp = block.timestamp;
        users[msg.sender].borrowedAmount += _amount;

        require(stablecoin.transfer(msg.sender, _amount), "Transfer failed");
    }

    // Owner function to adjust lending interest rate
    function setLendingInterestRate(uint256 _rate) external onlyOwner {
        require(_rate <= 100, "Rate must be <= 100");
        lendingInterestRate = _rate;
    }

    // New view function to get platform stats
    function getPlatformStats() external view returns (
        uint256 totalDeposits,
        uint256 totalBorrowed,
        uint256 availableLiquidity
    ) {
        return (
            totalStableDeposits,
            getTotalBorrowed(),
            stablecoin.balanceOf(address(this))
        );
    }

    // Helper function to get total borrowed amount
    function getTotalBorrowed() public view returns (uint256 totalBorrowed) {
        // This could be optimized with a state variable that tracks total borrows
        // For simplicity, we're calculating it on demand
        return users[msg.sender].borrowedAmount;
    }

    // Function to deposit Memecoins as collateral
    function depositCollateral(uint256 _amount) public {
        require(_amount > 0, "Amount must be greater than 0");
        memecoin.transferFrom(msg.sender, address(this), _amount);
        users[msg.sender].collateralAmount += _amount;
    }

    // Calculate interest based on time the loan has been active
    function calculateInterest(address _user) public view returns (uint256) {
        UserData storage user = users[_user];
        uint256 borrowed = user.borrowedAmount;
        uint256 timeElapsed = block.timestamp - user.borrowTimestamp;
        uint256 interest = (borrowed * interestRate * timeElapsed) / (365 days * 100);
        return borrowed + interest;
    }

    // Repay loan function
    function repayLoan(uint256 _amount) public {
        uint256 totalOwed = calculateInterest(msg.sender);
        require(_amount <= totalOwed, "Repay amount exceeds total owed");
        require(_amount > 0, "Amount must be greater than 0");
        
        // Transfer stablecoins from user to contract
        stablecoin.transferFrom(msg.sender, address(this), _amount);
        
        // Update borrowed amount
        users[msg.sender].borrowedAmount = totalOwed - _amount;
    }

    // Function to check user's collateral and borrowed amounts
    function getUserData(address _user) external view returns (
        uint256 collateralAmount, 
        uint256 borrowedAmount,
        uint256 stabledDeposited,
        uint256 depositTimestamp
    ) {
        UserData storage user = users[_user];
        return (
            user.collateralAmount,
            user.borrowedAmount,
            user.stabledDeposited,
            user.depositTimestamp
        );
    }

    // Fetch the USD value of the user's Memecoin collateral
    function getCollateralValue(address _user) public view returns (uint256) {
        uint256 memecoinPrice = priceOracle.getMemecoinPrice();
        uint256 collateralAmount = users[_user].collateralAmount;
        return (collateralAmount * memecoinPrice) / 1e18;
    }
}