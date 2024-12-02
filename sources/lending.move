module memepoolbank::lending_V2 {
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use aptos_framework::coin;
    use aptos_std::simple_map::{Self, SimpleMap};
    use memepoolbank::vault_V2;

    friend memepoolbank::liquidation_V2;

    /// Error codes
    const ENOT_AUTHORIZED: u64 = 1;
    const EALREADY_INITIALIZED: u64 = 2;
    const EASSET_NOT_SUPPORTED: u64 = 3;
    const EINSUFFICIENT_COLLATERAL: u64 = 4;
    const EBORROW_LIMIT_EXCEEDED: u64 = 5;
    const EINVALID_AMOUNT: u64 = 6;
    const EUSER_NO_POSITION: u64 = 7;
    const ESTALE_PRICE: u64 = 8;
    const ETOKEN_NOT_REGISTERED: u64 = 9;
    const EINSUFFICIENT_BALANCE: u64 = 10;

    /// Constants
    const BASIS_POINTS: u64 = 10000;
    const MAX_LTV: u64 = 500; // 5x leverage
    const LIQUIDATION_THRESHOLD: u64 = 8000; // 80%
    const PRICE_STALE_THRESHOLD: u64 = 300; // 5 minutes

    const DOGE_LTV_RATIO: u64 = 500; // 5x leverage
    const DOGE_LIQUIDATION_THRESHOLD: u64 = 8000; // 80%
    const DOGE_INITIAL_PRICE: u64 = 1000000; // $1.00 with 6 decimals
    const DOGE_PAIR_ID: u32 = 3; // Supra oracle pair ID for DOGE


    /// Asset configuration
    struct AssetConfig has store, drop, copy {
        ltv_ratio: u64,
        liquidation_threshold: u64,
        is_active: bool,
        pair_id: u32,  // Supra Oracle pair ID
        last_price: u64,
        last_update: u64,
    }

    /// User position
    struct Position has store {
        collateral: SimpleMap<String, u64>,
        debt: SimpleMap<String, u64>,
        last_update: u64,
    }

    struct LendingPool has key {
        assets: SimpleMap<String, AssetConfig>,
        positions: SimpleMap<address, Position>,
        active_assets: vector<String>,
        signer_cap: SignerCapability,
        deposit_events: event::EventHandle<DepositEvent>,
        borrow_events: event::EventHandle<BorrowEvent>,
    }

    struct DepositEvent has drop, store {
        user: address,
        asset: String,
        amount: u64,
        timestamp: u64,
    }

    struct BorrowEvent has drop, store {
        user: address,
        asset: String,
        amount: u64,
        timestamp: u64,
    }

    public entry fun initialize<CoinType>(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @memepoolbank, ENOT_AUTHORIZED);
        assert!(!exists<LendingPool>(admin_addr), EALREADY_INITIALIZED);

        let (_, signer_cap) = account::create_resource_account(admin, b"lending_pool");

        let pool = LendingPool {
            assets: simple_map::create(),
            positions: simple_map::create(),
            active_assets: vector::empty(),
            signer_cap,
            deposit_events: account::new_event_handle<DepositEvent>(admin),
            borrow_events: account::new_event_handle<BorrowEvent>(admin),
        };

        let doge_config = AssetConfig {
            ltv_ratio: DOGE_LTV_RATIO,
            liquidation_threshold: DOGE_LIQUIDATION_THRESHOLD,
            is_active: true,
            pair_id: DOGE_PAIR_ID,
            last_price: DOGE_INITIAL_PRICE,
            last_update: timestamp::now_seconds(),
        };

        simple_map::add(&mut pool.assets, string::utf8(b"DOGE"), doge_config);
        vector::push_back(&mut pool.active_assets, string::utf8(b"DOGE"));

        move_to(admin, pool);
    }

    public entry fun add_asset(
        admin: &signer,
        asset: String,
        ltv_ratio: u64,
        liquidation_threshold: u64,
        pair_id: u32,
        initial_price: u64
    ) acquires LendingPool {
        assert!(signer::address_of(admin) == @memepoolbank, ENOT_AUTHORIZED);
        let pool = borrow_global_mut<LendingPool>(@memepoolbank);

        let config = AssetConfig {
            ltv_ratio,
            liquidation_threshold,
            is_active: true,
            pair_id,
            last_price: initial_price,
            last_update: timestamp::now_seconds(),
        };
        
        if (!simple_map::contains_key(&pool.assets, &asset)) {
            simple_map::add(&mut pool.assets, asset, config);
            vector::push_back(&mut pool.active_assets, asset);
        };
    }

    public entry fun deposit<CoinType>(
    user: &signer,
    asset: String,
    amount: u64
) acquires LendingPool {
    // Add checks for token registration
    assert!(amount > 0, EINVALID_AMOUNT);
    assert!(coin::is_account_registered<CoinType>(signer::address_of(user)), ETOKEN_NOT_REGISTERED);

    // Get lending pool
    let pool = borrow_global_mut<LendingPool>(@memepoolbank);
    assert!(simple_map::contains_key(&pool.assets, &asset), EASSET_NOT_SUPPORTED);

    // Verify user has enough balance
    let user_addr = signer::address_of(user);
    assert!(coin::balance<CoinType>(user_addr) >= amount, EINSUFFICIENT_BALANCE);

    // Initialize user position if needed
    if (!simple_map::contains_key(&pool.positions, &user_addr)) {
        simple_map::add(&mut pool.positions, user_addr, Position {
            collateral: simple_map::create(),
            debt: simple_map::create(),
            last_update: timestamp::now_seconds(),
        });
    };

    // Update user's collateral position
    let position = simple_map::borrow_mut(&mut pool.positions, &user_addr);
    if (!simple_map::contains_key(&position.collateral, &asset)) {
        simple_map::add(&mut position.collateral, asset, 0);
    };

    // Update balance
    let balance = simple_map::borrow_mut(&mut position.collateral, &asset);
    *balance = *balance + amount;

    // Deposit tokens to vault_V2 first
    vault_V2::deposit<CoinType>(user, asset, amount);

    // Emit deposit event
    event::emit_event(
        &mut pool.deposit_events,
        DepositEvent {
            user: user_addr,
            asset,
            amount,
            timestamp: timestamp::now_seconds(),
        }
    );
}

    fun calculate_position_values(
        assets: &vector<String>,
        position: &Position,
        pool_ref: &LendingPool
    ): (u128, u128) {
        let total_collateral_value = 0u128;
        let total_debt_value = 0u128;

        let i = 0;
        let len = vector::length(assets);

        while (i < len) {
            let asset = vector::borrow(assets, i);
            
            if (simple_map::contains_key(&position.collateral, asset)) {
                let amount = (*simple_map::borrow(&position.collateral, asset) as u128);
                let config = simple_map::borrow(&pool_ref.assets, asset);
                verify_price_freshness(config);
                total_collateral_value = total_collateral_value + (amount * (config.last_price as u128));
            };

            if (simple_map::contains_key(&position.debt, asset)) {
                let amount = (*simple_map::borrow(&position.debt, asset) as u128);
                let config = simple_map::borrow(&pool_ref.assets, asset);
                verify_price_freshness(config);
                total_debt_value = total_debt_value + (amount * (config.last_price as u128));
            };

            i = i + 1;
        };

        (total_collateral_value, total_debt_value)
    }

    public entry fun borrow<CoinType>(
        user: &signer,
        asset: String,
        amount: u64
    ) acquires LendingPool {
        assert!(amount > 0, EINVALID_AMOUNT);
        let user_addr = signer::address_of(user);
        
        let pool = borrow_global<LendingPool>(@memepoolbank);
        assert!(simple_map::contains_key(&pool.assets, &asset), EASSET_NOT_SUPPORTED);
        assert!(simple_map::contains_key(&pool.positions, &user_addr), EUSER_NO_POSITION);
        
        let position = simple_map::borrow(&pool.positions, &user_addr);
        let (total_collateral_value, total_debt_value) = calculate_position_values(&pool.active_assets, position, pool);
        
        let config = simple_map::borrow(&pool.assets, &asset);
        verify_price_freshness(config);
        
        let new_debt_value = total_debt_value + ((amount as u128) * (config.last_price as u128));
        assert!(
            new_debt_value <= ((total_collateral_value * (MAX_LTV as u128)) / (BASIS_POINTS as u128)),
            EBORROW_LIMIT_EXCEEDED
        );

        let pool_mut = borrow_global_mut<LendingPool>(@memepoolbank);
        let position_mut = simple_map::borrow_mut(&mut pool_mut.positions, &user_addr);
        
        if (!simple_map::contains_key(&position_mut.debt, &asset)) {
            simple_map::add(&mut position_mut.debt, asset, 0);
        };

        let debt = simple_map::borrow_mut(&mut position_mut.debt, &asset);
        *debt = *debt + amount;

        vault_V2::withdraw<CoinType>(asset, amount, user_addr);

        event::emit_event(
            &mut pool_mut.borrow_events,
            BorrowEvent {
                user: user_addr,
                asset,
                amount,
                timestamp: timestamp::now_seconds(),
            }
        );
    }

    public entry fun update_asset_price(
        admin: &signer,
        asset: String,
        price: u64
    ) acquires LendingPool {
        assert!(signer::address_of(admin) == @memepoolbank, ENOT_AUTHORIZED);
        let pool = borrow_global_mut<LendingPool>(@memepoolbank);
        
        if (simple_map::contains_key(&pool.assets, &asset)) {
            let config = simple_map::borrow_mut(&mut pool.assets, &asset);
            config.last_price = price;
            config.last_update = timestamp::now_seconds();
        };
    }

    fun verify_price_freshness(config: &AssetConfig) {
        assert!(
            timestamp::now_seconds() - config.last_update <= PRICE_STALE_THRESHOLD,
            ESTALE_PRICE
        );
    }

    #[view]
    public fun get_asset_details(asset: String): (u128, u64, u64) acquires LendingPool {
        let pool = borrow_global<LendingPool>(@memepoolbank);
        assert!(simple_map::contains_key(&pool.assets, &asset), EASSET_NOT_SUPPORTED);

        let config = simple_map::borrow(&pool.assets, &asset);
        verify_price_freshness(config);
        ((config.last_price as u128), config.ltv_ratio, config.liquidation_threshold)
    }

    #[view]
    public fun get_user_position(
        user: address,
        asset: String
    ): (u64, u64) acquires LendingPool {
        let pool = borrow_global<LendingPool>(@memepoolbank);
        assert!(simple_map::contains_key(&pool.positions, &user), EUSER_NO_POSITION);
        
        let position = simple_map::borrow(&pool.positions, &user);
        let collateral = if (simple_map::contains_key(&position.collateral, &asset)) {
            *simple_map::borrow(&position.collateral, &asset)
        } else {
            0
        };
        
        let debt = if (simple_map::contains_key(&position.debt, &asset)) {
            *simple_map::borrow(&position.debt, &asset)
        } else {
            0
        };
        
        (collateral, debt)
    }

    public(friend) fun liquidate_position<CoinType>(
        liquidator: &signer,
        user: address,
        debt_asset: String,
        repay_amount: u64,
        collateral_asset: String,
    ) acquires LendingPool {
        let pool = borrow_global_mut<LendingPool>(@memepoolbank);
        assert!(simple_map::contains_key(&pool.positions, &user), EINSUFFICIENT_COLLATERAL);

        let position = simple_map::borrow_mut(&mut pool.positions, &user);
        assert!(simple_map::contains_key(&position.debt, &debt_asset), EINSUFFICIENT_COLLATERAL);
        assert!(simple_map::contains_key(&position.collateral, &collateral_asset), EINSUFFICIENT_COLLATERAL);

        let debt_config = simple_map::borrow(&pool.assets, &debt_asset);
        let collateral_config = simple_map::borrow(&pool.assets, &collateral_asset);
        verify_price_freshness(debt_config);
        verify_price_freshness(collateral_config);

        let debt = simple_map::borrow_mut(&mut position.debt, &debt_asset);
        *debt = *debt - repay_amount;

        let collateral_amount = (((repay_amount as u128) * 
            (debt_config.last_price as u128) * 
            ((BASIS_POINTS + LIQUIDATION_THRESHOLD) as u128)) / 
            ((collateral_config.last_price as u128) * (BASIS_POINTS as u128))) as u64;

        let collateral = simple_map::borrow_mut(&mut position.collateral, &collateral_asset);
        *collateral = *collateral - collateral_amount;

        vault_V2::deposit<CoinType>(liquidator, debt_asset, repay_amount);
        vault_V2::withdraw<CoinType>(collateral_asset, collateral_amount, signer::address_of(liquidator));
    }
}