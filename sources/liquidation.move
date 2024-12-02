module memepoolbank::liquidation_V2 {
    use std::signer;
    use std::string::String;
    use aptos_framework::event;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use memepoolbank::lending_V2;

    /// Error codes
    const ENOT_AUTHORIZED: u64 = 1;
    const EINVALID_AMOUNT: u64 = 2;
    const ELIQUIDATION_THRESHOLD: u64 = 3;
    const EUSER_NO_POSITION: u64 = 4;
    const EINSUFFICIENT_COLLATERAL: u64 = 5;

    /// Constants
    const LIQUIDATION_BONUS: u64 = 500; // 5% bonus
    const BASIS_POINTS: u64 = 10000;

    struct LiquidationEvent has drop, store {
        liquidator: address,
        user: address,
        debt_asset: String,
        collateral_asset: String,
        repay_amount: u64,
        received_amount: u64,
        timestamp: u64,
    }

    struct LiquidationStore has key {
        liquidation_events: event::EventHandle<LiquidationEvent>,
    }

    public fun initialize(admin: &signer) {
        assert!(signer::address_of(admin) == @memepoolbank, ENOT_AUTHORIZED);
        
        if (!exists<LiquidationStore>(@memepoolbank)) {
            move_to(admin, LiquidationStore {
                liquidation_events: account::new_event_handle<LiquidationEvent>(admin),
            });
        };
    }

    public entry fun liquidate<CoinType>(
    liquidator: &signer,
    user: address,
    debt_asset: String,
    collateral_asset: String,
    repay_amount: u64,
) acquires LiquidationStore {
    assert!(repay_amount > 0, EINVALID_AMOUNT);
    assert!(
        is_liquidatable(user, debt_asset, collateral_asset),
        ELIQUIDATION_THRESHOLD
    );

    // Get user position and verify
    let (_, debt) = lending_V2::get_user_position(user, debt_asset);
    assert!(debt >= repay_amount, EINVALID_AMOUNT);

    // Get current prices and details
    let (collateral_amount, _) = calculate_liquidation_amounts(debt_asset, collateral_asset, repay_amount);

    // Execute liquidation
    lending_V2::liquidate_position<CoinType>(
        liquidator,
        user,
        debt_asset,
        repay_amount,
        collateral_asset,
    );

    // Emit liquidation event
    let store = borrow_global_mut<LiquidationStore>(@memepoolbank);
    event::emit_event(
        &mut store.liquidation_events,
        LiquidationEvent {
            liquidator: signer::address_of(liquidator),
            user,
            debt_asset,
            collateral_asset,
            repay_amount,
            received_amount: collateral_amount,
            timestamp: timestamp::now_seconds(),
        }
    );
}

    #[view]
    public fun calculate_liquidation_amounts(
        debt_asset: String,
        collateral_asset: String,
        repay_amount: u64,
    ): (u64, u64) {
        let (debt_price, _, _) = lending_V2::get_asset_details(debt_asset);
        let (collateral_price, _, _) = lending_V2::get_asset_details(collateral_asset);
    
        let bonus_rate = BASIS_POINTS + LIQUIDATION_BONUS;
        let debt_value = (repay_amount as u128) * debt_price;
        let collateral_value = (debt_value * (bonus_rate as u128)) / (BASIS_POINTS as u128);
        let collateral_amount = ((collateral_value) / collateral_price) as u64;
    
        // Calculate price with bonus included
        let liquidation_price = ((debt_value * (BASIS_POINTS as u128)) / (repay_amount as u128)) as u64;
    
        (collateral_amount, liquidation_price)
    }

    #[view]
    public fun is_liquidatable(
        user: address,
        debt_asset: String,
        collateral_asset: String,
    ): bool {
        // First verify user has a position
        let (_, debt) = lending_V2::get_user_position(user, debt_asset);
        if (debt == 0) {
            return false
        };

        let health_factor = get_health_factor(user, debt_asset, collateral_asset);
        health_factor < BASIS_POINTS
    }

    #[view]
    public fun get_health_factor(
        user: address,
        debt_asset: String,
        collateral_asset: String,
    ): u64 {
        let (debt_price, ltv, threshold) = lending_V2::get_asset_details(debt_asset);
        let (collateral_price, _, _) = lending_V2::get_asset_details(collateral_asset);
        
        calculate_health_factor(
            user,
            debt_asset,
            collateral_asset,
            debt_price,
            collateral_price,
            ltv,
            threshold
        )
    }

    fun calculate_health_factor(
        user: address,
        debt_asset: String,
        collateral_asset: String,
        debt_price: u128,
        collateral_price: u128,
        ltv: u64,
        threshold: u64,
    ): u64 {
        let (collateral_amount, _) = lending_V2::get_user_position(user, collateral_asset);
        let (_, debt_amount) = lending_V2::get_user_position(user, debt_asset);

        if (debt_amount == 0) {
            return BASIS_POINTS
        };

        let debt_value = (debt_amount as u128) * debt_price;
        let collateral_value = (collateral_amount as u128) * collateral_price;
        
        let max_debt = (collateral_value * (ltv as u128)) / (BASIS_POINTS as u128);
        
        if (debt_value > max_debt) {
            let liquidation_value = (collateral_value * (threshold as u128)) / (BASIS_POINTS as u128);
            ((liquidation_value * (BASIS_POINTS as u128)) / debt_value) as u64
        } else {
            BASIS_POINTS
        }
    }

    #[view]
    public fun get_liquidation_info(
        user: address,
        debt_asset: String,
        collateral_asset: String,
    ): (bool, u64, u64, u64) {
        let can_liquidate = is_liquidatable(user, debt_asset, collateral_asset);
        let health_factor = get_health_factor(user, debt_asset, collateral_asset);
        let (collateral, debt) = lending_V2::get_user_position(user, debt_asset);
        (can_liquidate, health_factor, collateral, debt)
    }
}